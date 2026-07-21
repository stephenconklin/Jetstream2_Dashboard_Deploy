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
#   BASE_IMAGE - override the R base image (default: rocker/r-ver:4.4.1, bare
#                R). Use rocker/geospatial for sf/terra/raster projects, or
#                rocker/shiny-verse for tidyverse-heavy ones.
#   DATA_DIR   - host path (e.g. a mounted Jetstream2 storage volume) to
#                bind-mount over the project's data/ directory at runtime
#                instead of baking data/ into the image. The app must read
#                data from a "data/" relative path for this to line up.
#                Updating files under DATA_DIR takes effect on the next
#                `docker restart` — no rebuild needed.
set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-$TOOLING_DIR/app}"
IMAGE_NAME="${2:-shiny-app}"
CONTAINER_NAME="$IMAGE_NAME"
BASE_IMAGE="${BASE_IMAGE:-rocker/r-ver:4.4.1}"
DATA_DIR="${DATA_DIR:-}"

if [[ ! -f "$PROJECT_DIR/app.R" && ! -f "$PROJECT_DIR/server.R" ]]; then
  echo "No app.R or server.R found in $PROJECT_DIR — nothing to deploy." >&2
  exit 1
fi

if [[ -n "$DATA_DIR" && ! -d "$DATA_DIR" ]]; then
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
