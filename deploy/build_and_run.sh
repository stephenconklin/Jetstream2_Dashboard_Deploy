#!/usr/bin/env bash
# Build and run a dashboard/app in Docker, bound to host port 80, on a
# Jetstream2 instance. Generic across R Shiny, Plotly Dash, Python Shiny,
# and Streamlit — auto-detects which one a dropped-in project is. See
# examples/ for a self-test fixture per framework.
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
#   DATA_DIR   - host path (e.g. a mounted Jetstream2 storage volume, typically
#                under /media/volume/<volume-name>/...) bind-mounted into the
#                container AND passed as a DATA_DIR container env var. Data is
#                never baked into the image: if the project has a data/
#                directory and DATA_DIR isn't set, you'll be prompted for the
#                path interactively. Updating files under DATA_DIR takes
#                effect on the next `docker restart` — no rebuild needed.
set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$TOOLING_DIR/lib/common.sh"
# shellcheck source=lib/detect_framework.sh
source "$TOOLING_DIR/lib/detect_framework.sh"

DRY_RUN=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

PROJECT_DIR="${POSITIONAL[0]:-$TOOLING_DIR/app}"
IMAGE_NAME="${POSITIONAL[1]:-dashboard-app}"
CONTAINER_NAME="$IMAGE_NAME"
DATA_DIR="${DATA_DIR:-}"
FRAMEWORK="${FRAMEWORK:-}"
ENTRY_FILE=""
ENTRY_POINT_DESC=""

detect_framework   # sets FRAMEWORK, ENTRY_POINT_DESC, ENTRY_FILE (Python only)

# Everything from here to the --dry-run gate below must stay side-effect
# free: --dry-run's whole purpose is triaging candidate projects, so it must
# not run containers, write into the project directory, or fail on a
# condition it's supposed to be *reporting*. Anything with a side effect
# belongs after the gate.
DEPS_STATUS=""
NEEDS_REQS_FROM_UV=0
if [[ "$FRAMEWORK" == "r-shiny" ]]; then
  # R-specific: geospatial base image auto-detection + CRAN-drift warning.
  # No equivalent exists for the Python frameworks (see below).
  # Cached: the scan is a recursive grep over the whole project, and this
  # would otherwise run it twice (once here, once for the warning below).
  USES_GEOSPATIAL=0
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
  elif [[ -f "$PROJECT_DIR/uv.lock" ]]; then
    NEEDS_REQS_FROM_UV=1
    DEPS_STATUS="requirements.txt absent (will be generated from uv.lock pre-build)"
  else
    DEPS_STATUS="requirements.txt MISSING — required for $FRAMEWORK; the build would fail"
  fi
fi

HAS_DATA_DIR_IN_PROJECT=0
[[ -d "$PROJECT_DIR/data" ]] && HAS_DATA_DIR_IN_PROJECT=1

HAS_APT_TXT=0
[[ -s "$PROJECT_DIR/apt.txt" ]] && HAS_APT_TXT=1

if [[ "$DRY_RUN" -eq 1 ]]; then
  print_dry_run_summary "$DEPS_STATUS" "$HAS_DATA_DIR_IN_PROJECT" "$HAS_APT_TXT"
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
