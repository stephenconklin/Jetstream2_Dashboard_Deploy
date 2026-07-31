#!/usr/bin/env bash
# Build and run a dashboard/app in Docker on a Jetstream2 instance. Generic
# across R Shiny, Plotly Dash, Python Shiny, and Streamlit — auto-detects
# which one a dropped-in project is. See examples/ for a self-test fixture
# per framework.
#
# Where it publishes depends on whether deploy/bootstrap.sh has provisioned
# an nginx reverse proxy on this host:
#   * proxy present — the container binds 127.0.0.1 only, and nginx serves
#     port 80 in front of it (TLS, rate limiting, gzip, a maintenance page).
#   * no proxy      — the container binds 0.0.0.0:80 directly, as it always
#     did. Nothing here requires bootstrap.sh to have been run.
# See deploy/lib/proxy.sh for how that is decided.
#
# Usage:
#   ./build_and_run.sh                        # deploys ./app (drop your project there)
#   ./build_and_run.sh /path/to/other/project [image-name]
#   ./build_and_run.sh --dry-run /path/to/project [image-name]
#
# --dry-run: report what the script would do (framework detected, entry
# point, base image, dependency-file/data-dir/apt.txt presence) without
# building or running anything. Useful for triaging many candidate projects
# before committing to a full build.
#
# --porcelain: only with --dry-run. Print the same findings as stable
# `key=value` lines on stdout for programs rather than prose for people —
# this is what deploy/gui/ consumes so it never has to grep human-readable
# messages. Keys may be added over time but not renamed; warnings stay on
# stderr, so capturing stdout alone yields a clean stream.
#
# Optional files the project directory may include:
#   renv.lock         - (R Shiny) exact package versions to restore (skips dependency scanning).
#                       If absent, one is generated automatically before the build by installing
#                       the project's scanned dependencies against BASE_IMAGE and snapshotting.
#   requirements.txt   - (Dash/Python Shiny/Streamlit) REQUIRED — pip dependencies.
#                       If absent but the project has a uv.lock, requirements.txt
#                       is generated automatically from it before the build.
#   uv.lock             - (Dash/Python Shiny/Streamlit) fallback for requirements.txt,
#                       for projects managed with uv instead of pip directly.
#   apt.txt            - extra system packages (one per line), any framework
#
# Env vars:
#   FRAMEWORK  - force framework selection (r-shiny|dash|python-shiny|streamlit),
#                bypassing auto-detection entirely. Use this if detection
#                guesses wrong or a project is genuinely ambiguous.
#   BASE_IMAGE - override the base image. If unset:
#                - R Shiny: auto-detected — rocker/geospatial:4.4.1 if the
#                  project's .R/.Rmd files use sf/terra/raster/stars/rgdal/rgeos,
#                  otherwise rocker/r-ver:4.4.1 (bare R).
#                - Dash/Python Shiny/Streamlit: python:3.11-slim.
#   BUILD_PLATFORM - override the `docker build --platform` target. Normally
#                unset: the 3 Python frameworks build natively on any
#                architecture, and R Shiny auto-selects linux/amd64 when the
#                Docker host isn't amd64, since Shiny Server is published as
#                an amd64-only .deb (relevant when testing on an Apple
#                Silicon Mac; Jetstream2 instances are x86_64).
#   CONTAINER_PORT - override the port the app listens on *inside* the
#                container, when a project's server is configured for
#                something other than its framework's default (3838 R Shiny,
#                8050 Dash, 8000 Python Shiny, 8501 Streamlit). The host
#                side is unaffected — it stays whatever the proxy state says
#                (port 80 directly, or a loopback port behind nginx).
#   DATA_DIR   - host path (e.g. a mounted Jetstream2 storage volume, typically
#                under /media/volume/<volume-name>/...) bind-mounted into the
#                container AND passed as a DATA_DIR container env var. Data is
#                never baked into the image: if the project has a data/
#                directory and DATA_DIR isn't set, you'll be prompted for the
#                path interactively. Updating files under DATA_DIR takes
#                effect on the next `docker restart` — no rebuild needed.
# The directive below lets `shellcheck -x` resolve the two `source` lines
# relative to this script rather than the caller's cwd. Without it the
# linter can't follow them, and then reports every variable the sourced
# functions consume (see common.sh's header) as an unused assignment. It
# has to sit before the first command in the file to apply file-wide.
# NB: any comment line starting with the linter's own name is parsed as a
# directive, so prose here must avoid that word at the start of a line.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TOOLING_DIR/lib/common.sh"
source "$TOOLING_DIR/lib/detect_framework.sh"

DRY_RUN=0
PORCELAIN=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --porcelain) PORCELAIN=1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

# --porcelain only modifies the dry-run summary. Rejecting it on the deploy
# path keeps it from being mistaken for "machine-readable deploy output" —
# a deploy's output is a live build log that callers stream verbatim, and
# there's no stable structure to promise there.
if [[ "$PORCELAIN" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
  echo "--porcelain is only valid together with --dry-run." >&2
  exit 1
fi

PROJECT_DIR="${POSITIONAL[0]:-$TOOLING_DIR/app}"
IMAGE_NAME="${POSITIONAL[1]:-dashboard-app}"
CONTAINER_NAME="$IMAGE_NAME"

# Validated up front because `docker build` rejects a non-conforming tag
# *deterministically* — and build_image() would otherwise treat that like a
# flaky network error and retry it 3 times with 10s backoffs before failing,
# turning an instant typo into a 20-second wait with a repeated error.
# Docker's rule: lowercase alphanumerics separated by . _ __ or -, starting
# and ending with an alphanumeric.
if [[ ! "$IMAGE_NAME" =~ ^[a-z0-9]+([._-]+[a-z0-9]+)*$ ]]; then
  echo "Invalid image name '$IMAGE_NAME'." >&2
  echo "Docker requires lowercase letters, digits, and . _ - separators," >&2
  echo "starting and ending with a letter or digit." >&2
  lowered="$(printf '%s' "$IMAGE_NAME" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lowered" =~ ^[a-z0-9]+([._-]+[a-z0-9]+)*$ ]]; then
    echo "Did you mean '$lowered'?" >&2
  fi
  exit 1
fi
DATA_DIR="${DATA_DIR:-}"
FRAMEWORK="${FRAMEWORK:-}"
ENTRY_FILE=""
ENTRY_POINT_DESC=""

detect_framework   # sets FRAMEWORK, ENTRY_POINT_DESC, ENTRY_FILE (Python only)

# Reading the proxy state file is a read, so this belongs above the dry-run
# gate — and it has to be, since --dry-run reports where the app would be
# published. Sets PROXY_ENABLED, APP_BIND_ADDR, APP_HOST_PORT,
# PROXY_SERVER_NAME; absent state file means the pre-nginx 0.0.0.0:80.
resolve_app_bind

# Everything from here to the --dry-run gate below must stay side-effect
# free: --dry-run's whole purpose is triaging candidate projects, so it must
# not run containers, write into the project directory, or fail on a
# condition it's supposed to be *reporting*. Anything with a side effect
# belongs after the gate.
# DEPS_STATUS is the human sentence; DEPS_STATE is the same fact as a stable
# enum for --porcelain consumers, so a GUI never has to grep prose for the
# word "MISSING". Keep the two in sync whenever either is set.
DEPS_STATUS=""
DEPS_STATE=""
NEEDS_REQS_FROM_UV=0
# Only meaningful for R Shiny (the geospatial scan has no Python equivalent),
# but initialized for every framework so --porcelain can print it
# unconditionally without tripping `set -u`.
USES_GEOSPATIAL=0
if [[ "$FRAMEWORK" == "r-shiny" ]]; then
  # R-specific: geospatial base image auto-detection + CRAN-drift warning.
  # No equivalent exists for the Python frameworks (see below).
  # Cached: the scan is a recursive grep over the whole project, and this
  # would otherwise run it twice (once here, once for the warning below).
  uses_geospatial_packages && USES_GEOSPATIAL=1

  if [[ -z "${BASE_IMAGE:-}" ]]; then
    if [[ "$USES_GEOSPATIAL" -eq 1 ]]; then
      BASE_IMAGE="rocker/geospatial:4.4.1"
      echo "Detected geospatial packages (sf/terra/raster/...) — using BASE_IMAGE=$BASE_IMAGE" >&2
    else
      BASE_IMAGE="rocker/r-ver:4.4.1"
    fi
  fi

  HAS_RENV_LOCK=0
  [[ -f "$PROJECT_DIR/renv.lock" ]] && HAS_RENV_LOCK=1
  DEPS_STATUS="renv.lock $([[ "$HAS_RENV_LOCK" -eq 1 ]] && echo present || echo "absent (will be generated pre-build)")"
  DEPS_STATE="$([[ "$HAS_RENV_LOCK" -eq 1 ]] && echo present || echo will-generate-renv)"

  if [[ "$USES_GEOSPATIAL" -eq 1 && "$HAS_RENV_LOCK" -eq 0 ]]; then
    echo "Warning: this project uses geospatial packages (sf/terra/raster/...) but has" >&2
    echo "no renv.lock. A renv.lock will be generated automatically below, installing" >&2
    echo "whatever's newest on CRAN — but a newer release of one of these packages can" >&2
    echo "need a newer GDAL/GEOS/PROJ than $BASE_IMAGE ships, which would fail that step." >&2
    echo "See docs/deployment.md's 'Pinning R package versions' section for how to pin an" >&2
    echo "older, compatible version by hand if that happens." >&2
  fi
else
  # Dash / Python Shiny / Streamlit: requirements.txt is REQUIRED, not
  # optional — unlike R's renv::dependencies() static-scan fallback, Python
  # has no reliable way to infer PyPI package names from import statements
  # (e.g. `import cv2` comes from the package `opencv-python`), so there's
  # no safe fallback if it's missing. The one exception: a project managed
  # with uv (pyproject.toml + uv.lock) already has a fully-resolved,
  # pinned dependency set under a different name — generate requirements.txt
  # from it rather than failing (done after the dry-run gate, since it
  # writes into the project directory).
  BASE_IMAGE="${BASE_IMAGE:-python:3.11-slim}"
  if [[ -f "$PROJECT_DIR/requirements.txt" ]]; then
    DEPS_STATUS="requirements.txt present"
    DEPS_STATE="present"
  elif [[ -f "$PROJECT_DIR/uv.lock" ]]; then
    NEEDS_REQS_FROM_UV=1
    DEPS_STATUS="requirements.txt absent (will be generated from uv.lock pre-build)"
    DEPS_STATE="will-generate-from-uv"
  else
    DEPS_STATUS="requirements.txt MISSING — required for $FRAMEWORK; the build would fail"
    DEPS_STATE="missing"
  fi
fi

HAS_DATA_DIR_IN_PROJECT=0
[[ -d "$PROJECT_DIR/data" ]] && HAS_DATA_DIR_IN_PROJECT=1

HAS_APT_TXT=0
[[ -s "$PROJECT_DIR/apt.txt" ]] && HAS_APT_TXT=1

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$PORCELAIN" -eq 1 ]]; then
    print_dry_run_porcelain "$DEPS_STATE" "$HAS_DATA_DIR_IN_PROJECT" "$HAS_APT_TXT" "$USES_GEOSPATIAL"
  else
    print_dry_run_summary "$DEPS_STATUS" "$HAS_DATA_DIR_IN_PROJECT" "$HAS_APT_TXT"
  fi
  exit 0
fi

# --- Past this point, side effects are allowed. ---------------------------

if [[ "$FRAMEWORK" != "r-shiny" ]]; then
  [[ "$NEEDS_REQS_FROM_UV" -eq 1 ]] && generate_requirements_from_uv
  require_file_or_fail "$PROJECT_DIR/requirements.txt" "$FRAMEWORK" \
    "Unlike R (which can fall back to scanning your code), Python has no reliable way to auto-detect package names from import statements (e.g. \`import cv2\` comes from the PyPI package \`opencv-python\`, not \`cv2\`). Run \`pip freeze > requirements.txt\` in your project's working environment (or \`uv export --no-hashes -o requirements.txt\` for a uv project), or write one by hand."
fi

DOCKERFILE_PATH="$TOOLING_DIR/docker/Dockerfile.$FRAMEWORK"
EXTRA_BUILD_ARGS=()
case "$FRAMEWORK" in
  r-shiny)
    SUPPORT_FILES=(apt_retry.sh install_deps.R shiny-server.conf)
    ;;
  dash|python-shiny)
    SUPPORT_FILES=(apt_retry.sh)
    if [[ -n "$ENTRY_FILE" ]]; then
      EXTRA_BUILD_ARGS+=(--build-arg "ENTRY_MODULE=${ENTRY_FILE%.py}")
    fi
    ;;
  streamlit)
    SUPPORT_FILES=(apt_retry.sh)
    if [[ -n "$ENTRY_FILE" ]]; then
      EXTRA_BUILD_ARGS+=(--build-arg "ENTRY_MODULE=$ENTRY_FILE")
    fi
    ;;
  *)
    # detect_framework() validates FRAMEWORK against the supported set, so
    # reaching here means a new framework was added there without a matching
    # arm being added here.
    echo "Internal error: no build configuration for framework '$FRAMEWORK'." >&2
    exit 1
    ;;
esac

# Before generate_renv_lock(), not after: that step runs a full `docker
# build` of the deps-base stage, and build_image() only prunes the project's
# data/ from the build context once DATA_DIR is known. Resolving it first
# keeps a multi-GB data/ out of *both* build contexts, and surfaces the
# interactive prompt before a long build rather than after it.
resolve_data_dir

resolve_build_platform

if [[ "$FRAMEWORK" == "r-shiny" && "$HAS_RENV_LOCK" -eq 0 ]]; then
  generate_renv_lock
fi

build_image

INTERNAL_PORT="${CONTAINER_PORT:-$(container_port_for_framework "$FRAMEWORK")}"
MOUNT_TARGET="$(container_data_mount_target_for_framework "$FRAMEWORK")"

run_container
run_smoke_test
