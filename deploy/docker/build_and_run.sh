#!/usr/bin/env bash
# Build and run a Dockerized Shiny app on a Jetstream2 instance. Generic:
# works for any R Shiny project, as long as it's a directory containing
# app.R (or a ui.R/server.R pair). See examples/hello-world for a self-test.
#
# Usage:
#   ./build_and_run.sh                        # deploys ./app (drop your project there)
#   ./build_and_run.sh /path/to/other/project [image-name]
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
PROJECT_DIR="${1:-$TOOLING_DIR/app}"
IMAGE_NAME="${2:-shiny-app}"
CONTAINER_NAME="$IMAGE_NAME"
DATA_DIR="${DATA_DIR:-}"

if [[ ! -f "$PROJECT_DIR/app.R" && ! -f "$PROJECT_DIR/server.R" ]]; then
  echo "No app.R or server.R found in $PROJECT_DIR — nothing to deploy." >&2
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
if uses_geospatial_packages && [[ ! -f "$PROJECT_DIR/renv.lock" ]]; then
  echo "Warning: this project uses geospatial packages (sf/terra/raster/...) but has" >&2
  echo "no renv.lock, so install_deps.R will install whatever's newest on CRAN. A" >&2
  echo "future CRAN release of one of these packages could require a newer GDAL/GEOS/PROJ" >&2
  echo "than $BASE_IMAGE ships and break this build. Consider pinning versions with" >&2
  echo "renv::snapshot() once you have a working install. See docs/deployment.md." >&2
fi

# Data is never baked into the image. If the project ships a data/ directory
# and the caller hasn't already pointed DATA_DIR at a real location, prompt
# for one interactively — the app's data must come from a bind-mounted host
# path (typically a Jetstream2 storage volume) instead.
if [[ -d "$PROJECT_DIR/data" && -z "$DATA_DIR" ]]; then
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
mkdir -p "$BUILD_CTX/app"
cp -R "$PROJECT_DIR"/. "$BUILD_CTX/app/"
if [[ -n "$DATA_DIR" ]]; then
  rm -rf "$BUILD_CTX/app/data"   # served from DATA_DIR at runtime instead
fi
touch "$BUILD_CTX/app/apt.txt"   # harmless no-op if the project already has one

docker build \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  -t "$IMAGE_NAME:latest" \
  "$BUILD_CTX"

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

echo "Container '$CONTAINER_NAME' running. App should be reachable at http://<instance-fixed-ip>/"
