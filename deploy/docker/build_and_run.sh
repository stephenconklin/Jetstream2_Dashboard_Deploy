#!/usr/bin/env bash
# Build and run a Dockerized Shiny app on a Jetstream2 instance. Generic:
# works for any R Shiny project — app.R, a ui.R/server.R pair, or an R
# Markdown Shiny document (runtime: shiny). See examples/hello-world for a
# self-test.
#
# Usage:
#   ./build_and_run.sh                        # deploys ./app (drop your project there)
#   ./build_and_run.sh /path/to/other/project [image-name]
#   ./build_and_run.sh --dry-run /path/to/project [image-name]
#
# --dry-run: report what the script would do (entry point found, base image
# that would be selected, renv.lock/data-dir/apt.txt presence) without
# building or running anything. Useful for triaging many candidate projects
# before committing to a full build.
#
# Optional files the project directory may include:
#   renv.lock  - exact package versions to restore (skips dependency scanning)
#   apt.txt    - extra system packages (one per line) BASE_IMAGE doesn't provide
#
# Env vars:
#   BASE_IMAGE - override the R base image. If unset, it's auto-detected:
#                rocker/geospatial:4.4.1 if the project's .R/.Rmd files use
#                sf/terra/raster/stars/rgdal/rgeos, otherwise rocker/r-ver:4.4.1
#                (bare R). Set this explicitly to skip detection, e.g. for
#                rocker/shiny-verse on tidyverse-heavy projects.
#   DATA_DIR   - host path (e.g. a mounted Jetstream2 storage volume, typically
#                under /media/volume/<volume-name>/...) to bind-mount over the
#                project's data/ directory at runtime. Data is never baked
#                into the image: if the project has a data/ directory and
#                DATA_DIR isn't set, you'll be prompted for the path
#                interactively. The app must read data from a "data/"
#                relative path for this to line up. Updating files under
#                DATA_DIR takes effect on the next `docker restart` — no
#                rebuild needed.
set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

PROJECT_DIR="${POSITIONAL[0]:-$TOOLING_DIR/app}"
IMAGE_NAME="${POSITIONAL[1]:-shiny-app}"
CONTAINER_NAME="$IMAGE_NAME"
DATA_DIR="${DATA_DIR:-}"

# Entry point detection. Beyond the standard app.R / ui.R+server.R
# convention, also recognize an R Markdown Shiny document (a flexdashboard
# or interactive .Rmd with `runtime: shiny` in its YAML front matter) —
# Shiny Server can serve either directly. A golem-packaged app that only
# ships inst/app.R (no root-level app.R shim) gets a specific, actionable
# error instead of a generic "nothing found" message.
ENTRY_POINT_DESC=""

detect_entry_point() {
  if [[ -f "$PROJECT_DIR/app.R" ]]; then
    ENTRY_POINT_DESC="app.R"
    return 0
  fi
  if [[ -f "$PROJECT_DIR/server.R" ]]; then
    ENTRY_POINT_DESC="ui.R/server.R"
    return 0
  fi
  local rmd
  for rmd in "$PROJECT_DIR"/*.Rmd "$PROJECT_DIR"/*.rmd; do
    [[ -f "$rmd" ]] || continue
    if grep -qE '^runtime:[[:space:]]*shiny' "$rmd"; then
      ENTRY_POINT_DESC="R Markdown Shiny document ($(basename "$rmd"))"
      return 0
    fi
  done
  return 1
}

if ! detect_entry_point; then
  if [[ -f "$PROJECT_DIR/DESCRIPTION" && -f "$PROJECT_DIR/inst/app.R" ]]; then
    echo "This looks like a golem-packaged app (DESCRIPTION + inst/app.R found), but" >&2
    echo "Shiny Server needs an entry point at the project root, not under inst/." >&2
    echo "Add a root-level app.R that loads and runs the package, e.g.:" >&2
    echo "  pkgload::load_all()" >&2
    echo "  <pkgname>::run_app()" >&2
    exit 1
  fi
  echo "No app.R, ui.R/server.R, or R Markdown Shiny document (runtime: shiny) found" >&2
  echo "in $PROJECT_DIR — nothing to deploy." >&2
  exit 1
fi

# Auto-detect a geospatial base image from the project's code, unless the
# caller already set BASE_IMAGE explicitly. This is a best-effort heuristic
# (regex over library()/require()/:: usage), not a guarantee — set BASE_IMAGE
# yourself if a project needs something this doesn't catch.
GEOSPATIAL_PACKAGES=(sf terra raster stars rgdal rgeos)

uses_geospatial_packages() {
  local pkg
  for pkg in "${GEOSPATIAL_PACKAGES[@]}"; do
    if grep -rlE "(library|require)\\(['\"]?${pkg}['\"]?\\)|\\b${pkg}::" \
         --include='*.R' --include='*.Rmd' "$PROJECT_DIR" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

if [[ -z "${BASE_IMAGE+set}" ]]; then
  if uses_geospatial_packages; then
    BASE_IMAGE="rocker/geospatial:4.4.1"
    echo "Detected geospatial packages (sf/terra/raster/...) — using BASE_IMAGE=$BASE_IMAGE" >&2
  else
    BASE_IMAGE="rocker/r-ver:4.4.1"
  fi
fi

# Without a renv.lock, install_deps.R installs whatever's currently newest on
# CRAN for each required package — geospatial packages in particular
# (sf/terra/...) compile against the base image's fixed GDAL/GEOS/PROJ, so a
# newer CRAN release can break a build that worked yesterday. This can't be
# reliably predicted ahead of time (that's what the build step itself is
# for) — just flag the risk so it's not a surprise.
HAS_RENV_LOCK=0
[[ -f "$PROJECT_DIR/renv.lock" ]] && HAS_RENV_LOCK=1

if uses_geospatial_packages && [[ "$HAS_RENV_LOCK" -eq 0 ]]; then
  echo "Warning: this project uses geospatial packages (sf/terra/raster/...) but has" >&2
  echo "no renv.lock, so install_deps.R will install whatever's newest on CRAN. A" >&2
  echo "future CRAN release of one of these packages could require a newer GDAL/GEOS/PROJ" >&2
  echo "than $BASE_IMAGE ships and break this build. Consider pinning versions with" >&2
  echo "renv::snapshot() once you have a working install. See docs/deployment.md." >&2
fi

HAS_DATA_DIR_IN_PROJECT=0
[[ -d "$PROJECT_DIR/data" ]] && HAS_DATA_DIR_IN_PROJECT=1

HAS_APT_TXT=0
[[ -s "$PROJECT_DIR/apt.txt" ]] && HAS_APT_TXT=1

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "=== Dry run: $PROJECT_DIR ==="
  echo "Entry point:     $ENTRY_POINT_DESC"
  echo "Base image:      $BASE_IMAGE"
  echo "renv.lock:       $([[ "$HAS_RENV_LOCK" -eq 1 ]] && echo present || echo absent)"
  echo "data/ directory: $([[ "$HAS_DATA_DIR_IN_PROJECT" -eq 1 ]] && echo "present (DATA_DIR would be required, prompted for if unset)" || echo none)"
  echo "apt.txt:         $([[ "$HAS_APT_TXT" -eq 1 ]] && echo present || echo "absent/empty")"
  echo "==========================================="
  exit 0
fi

# Data is never baked into the image. If the project ships a data/ directory
# and the caller hasn't already pointed DATA_DIR at a real location, prompt
# for one interactively — the app's data must come from a bind-mounted host
# path (typically a Jetstream2 storage volume) instead.
if [[ "$HAS_DATA_DIR_IN_PROJECT" -eq 1 && -z "$DATA_DIR" ]]; then
  if [[ ! -t 0 ]]; then
    echo "This project has a data/ directory, but DATA_DIR isn't set and no terminal" >&2
    echo "is attached to prompt for one. Set DATA_DIR=/media/volume/<volume-name>/... and re-run." >&2
    exit 1
  fi
  echo
  echo "This project ships a data/ directory. To keep data out of the Docker image"
  echo "(so it survives rebuilds and isn't duplicated), point this at the actual"
  echo "location of your data instead — usually a Jetstream2 storage volume mounted"
  echo "under /media/volume/<volume-name>/... (run 'df -h' if you're not sure of the"
  echo "exact path)."
  while [[ -z "$DATA_DIR" ]]; do
    read -rp "Enter the full path to your data directory: " DATA_DIR
    if [[ -z "$DATA_DIR" ]]; then
      echo "A data directory path is required — this project's app.R reads from data/." >&2
    elif [[ ! -d "$DATA_DIR" ]]; then
      echo "'$DATA_DIR' is not a directory. Try again." >&2
      DATA_DIR=""
    fi
  done
elif [[ -n "$DATA_DIR" && ! -d "$DATA_DIR" ]]; then
  echo "DATA_DIR '$DATA_DIR' is not a directory." >&2
  exit 1
fi

BUILD_CTX="$(mktemp -d)"
trap 'rm -rf "$BUILD_CTX"' EXIT

cp "$TOOLING_DIR/Dockerfile" "$BUILD_CTX/"
cp "$TOOLING_DIR/install_deps.R" "$BUILD_CTX/"
cp "$TOOLING_DIR/shiny-server.conf" "$BUILD_CTX/"
cp "$TOOLING_DIR/apt_retry.sh" "$BUILD_CTX/"
mkdir -p "$BUILD_CTX/app"
cp -R "$PROJECT_DIR"/. "$BUILD_CTX/app/"
if [[ -n "$DATA_DIR" ]]; then
  rm -rf "$BUILD_CTX/app/data"   # served from DATA_DIR at runtime instead
fi
touch "$BUILD_CTX/app/apt.txt"   # harmless no-op if the project already has one

# docker build itself has no built-in retry; a transient network blip while
# fetching apt/CRAN packages inside the build (see Dockerfile and
# install_deps.R, which retry their own internal steps) can still surface as
# a failed `docker build` if it happens outside those retry windows (e.g.
# pulling BASE_IMAGE itself). Retry the whole build a couple of times before
# giving up, since across many projects this kind of hiccup is common.
BUILD_TRIES=3
build_ok=0
for attempt in $(seq 1 "$BUILD_TRIES"); do
  if docker build \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    -t "$IMAGE_NAME:latest" \
    "$BUILD_CTX"; then
    build_ok=1
    break
  fi
  if [[ "$attempt" -lt "$BUILD_TRIES" ]]; then
    echo "docker build failed (attempt $attempt/$BUILD_TRIES) — retrying in 10s..." >&2
    sleep 10
  fi
done
if [[ "$build_ok" -ne 1 ]]; then
  echo "docker build failed after $BUILD_TRIES attempts." >&2
  exit 1
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

DATA_MOUNT_ARGS=()
if [[ -n "$DATA_DIR" ]]; then
  DATA_MOUNT_ARGS=(-v "$(cd "$DATA_DIR" && pwd):/srv/shiny-server/data")
fi

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p 80:3838 \
  "${DATA_MOUNT_ARGS[@]}" \
  "$IMAGE_NAME:latest"

# A successful `docker build` + `docker run -d` only means the image is
# valid and the container started — it says nothing about whether the Shiny
# process inside actually stayed up (e.g. a missing data file or an error in
# app.R can crash it seconds later). Poll the app before declaring success,
# and surface the container's own logs immediately if it never responds.
echo "Waiting for the app to respond on port 80..."
if command -v curl >/dev/null 2>&1; then
  SMOKE_TEST_OK=0
  for i in $(seq 1 30); do
    if curl -fsS -o /dev/null "http://localhost:80/"; then
      SMOKE_TEST_OK=1
      break
    fi
    sleep 2
  done
  if [[ "$SMOKE_TEST_OK" -eq 1 ]]; then
    echo "Container '$CONTAINER_NAME' running and responding. App should be reachable at http://<instance-fixed-ip>/"
  else
    echo "Warning: container '$CONTAINER_NAME' started, but never responded on port 80" >&2
    echo "within 60s. This usually means the Shiny process crashed at runtime (e.g. a" >&2
    echo "missing data file, or an error in app.R) even though the image built" >&2
    echo "successfully. Recent container logs:" >&2
    docker logs --tail 50 "$CONTAINER_NAME" >&2
    exit 1
  fi
else
  echo "curl not found — skipping post-start smoke test." >&2
  echo "Container '$CONTAINER_NAME' started; verify manually at http://<instance-fixed-ip>/."
fi
