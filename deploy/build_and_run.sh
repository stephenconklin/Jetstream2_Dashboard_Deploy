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
#   requirements.txt   - (Dash/Python Shiny/Streamlit) REQUIRED — pip dependencies
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

DEPS_STATUS=""
if [[ "$FRAMEWORK" == "r-shiny" ]]; then
  # R-specific: geospatial base image auto-detection + CRAN-drift warning.
  # No equivalent exists for the Python frameworks (see below).
  if [[ -z "${BASE_IMAGE+set}" ]]; then
    if uses_geospatial_packages; then
      BASE_IMAGE="rocker/geospatial:4.4.1"
      echo "Detected geospatial packages (sf/terra/raster/...) — using BASE_IMAGE=$BASE_IMAGE" >&2
    else
      BASE_IMAGE="rocker/r-ver:4.4.1"
    fi
  fi

  HAS_RENV_LOCK=0
  [[ -f "$PROJECT_DIR/renv.lock" ]] && HAS_RENV_LOCK=1
  DEPS_STATUS="renv.lock $([[ "$HAS_RENV_LOCK" -eq 1 ]] && echo present || echo "absent (will be generated pre-build)")"

  if uses_geospatial_packages && [[ "$HAS_RENV_LOCK" -eq 0 ]]; then
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
  # no safe fallback if it's missing.
  BASE_IMAGE="${BASE_IMAGE:-python:3.11-slim}"
  require_file_or_fail "$PROJECT_DIR/requirements.txt" "$FRAMEWORK" \
    "Unlike R (which can fall back to scanning your code), Python has no reliable way to auto-detect package names from import statements (e.g. \`import cv2\` comes from the PyPI package \`opencv-python\`, not \`cv2\`). Run \`pip freeze > requirements.txt\` in your project's working environment, or write one by hand."
  DEPS_STATUS="requirements.txt present"
fi

HAS_DATA_DIR_IN_PROJECT=0
[[ -d "$PROJECT_DIR/data" ]] && HAS_DATA_DIR_IN_PROJECT=1

HAS_APT_TXT=0
[[ -s "$PROJECT_DIR/apt.txt" ]] && HAS_APT_TXT=1

if [[ "$DRY_RUN" -eq 1 ]]; then
  print_dry_run_summary "$DEPS_STATUS" "$HAS_DATA_DIR_IN_PROJECT" "$HAS_APT_TXT"
  exit 0
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
esac

if [[ "$FRAMEWORK" == "r-shiny" && "$HAS_RENV_LOCK" -eq 0 ]]; then
  generate_renv_lock
fi

resolve_data_dir

build_image

INTERNAL_PORT="${CONTAINER_PORT:-$(container_port_for_framework "$FRAMEWORK")}"
MOUNT_TARGET="$(container_data_mount_target_for_framework "$FRAMEWORK")"

run_container
run_smoke_test
