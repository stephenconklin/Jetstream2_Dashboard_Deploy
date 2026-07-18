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
set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-$TOOLING_DIR/app}"
IMAGE_NAME="${2:-shiny-app}"
CONTAINER_NAME="$IMAGE_NAME"
BASE_IMAGE="${BASE_IMAGE:-rocker/r-ver:4.4.1}"

if [[ ! -f "$PROJECT_DIR/app.R" && ! -f "$PROJECT_DIR/server.R" ]]; then
  echo "No app.R or server.R found in $PROJECT_DIR — nothing to deploy." >&2
  exit 1
fi

BUILD_CTX="$(mktemp -d)"
trap 'rm -rf "$BUILD_CTX"' EXIT

cp "$TOOLING_DIR/Dockerfile" "$BUILD_CTX/"
cp "$TOOLING_DIR/install_deps.R" "$BUILD_CTX/"
cp "$TOOLING_DIR/shiny-server.conf" "$BUILD_CTX/"
mkdir -p "$BUILD_CTX/app"
cp -R "$PROJECT_DIR"/. "$BUILD_CTX/app/"
touch "$BUILD_CTX/app/apt.txt"   # harmless no-op if the project already has one

docker build \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  -t "$IMAGE_NAME:latest" \
  "$BUILD_CTX"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p 80:3838 \
  "$IMAGE_NAME:latest"

echo "Container '$CONTAINER_NAME' running. App should be reachable at http://<instance-fixed-ip>/"
