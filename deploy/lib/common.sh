#!/usr/bin/env bash
# Shared, framework-agnostic helpers for build_and_run.sh: the retry-wrapped
# docker build/run, the DATA_DIR prompt, the port/mount-target lookup
# tables, the dry-run summary printer, and the post-start smoke test.
# Sourced by build_and_run.sh — not meant to be run directly. Functions here
# read/write the caller's variables directly (TOOLING_DIR, PROJECT_DIR,
# IMAGE_NAME, BASE_IMAGE, DATA_DIR, etc.) rather than taking everything as
# positional args, matching the rest of this script's style.

# Internal container port each framework's server listens on by default.
# `docker run -p 80:$PORT` and each Dockerfile's `--build-arg PORT=$PORT`
# both draw from this single source of truth. A `case` (not a bash-4
# associative array) so this stays compatible with macOS's ancient default
# bash 3.2 as well as Jetstream2's modern Ubuntu bash.
container_port_for_framework() {
  case "$1" in
    r-shiny)      echo 3838 ;;
    dash)         echo 8050 ;;
    python-shiny) echo 8000 ;;
    streamlit)    echo 8501 ;;
    *) echo "container_port_for_framework: unknown framework '$1'" >&2; return 1 ;;
  esac
}

# Where a project's data/ directory gets bind-mounted (and where the
# DATA_DIR env var, set alongside it, points) inside the container.
container_data_mount_target_for_framework() {
  case "$1" in
    r-shiny)                      echo /srv/shiny-server/data ;;
    dash|python-shiny|streamlit)  echo /app/data ;;
    *) echo "container_data_mount_target_for_framework: unknown framework '$1'" >&2; return 1 ;;
  esac
}

# Fail with an actionable message if a required project file is missing.
# Used for requirements.txt on the 3 Python frameworks, which — unlike R's
# renv::dependencies() static-scan fallback — have no reliable way to infer
# package names from import statements (e.g. `import cv2` comes from the
# PyPI package `opencv-python`), so the file can't be optional.
require_file_or_fail() {
  local path="$1" framework_label="$2" explanation="$3"
  if [[ ! -f "$path" ]]; then
    echo "This looks like a $framework_label project, but no $(basename "$path") was found" >&2
    echo "in $(dirname "$path")." >&2
    echo "$explanation" >&2
    exit 1
  fi
}

# Prints a "what would happen" summary for --dry-run.
print_dry_run_summary() {
  local deps_status="$1" has_data_dir="$2" has_apt_txt="$3"
  echo
  echo "=== Dry run: $PROJECT_DIR ==="
  echo "Framework:       $FRAMEWORK"
  echo "Entry point:     $ENTRY_POINT_DESC"
  echo "Base image:      $BASE_IMAGE"
  echo "Dependencies:    $deps_status"
  echo "data/ directory: $([[ "$has_data_dir" -eq 1 ]] && echo "present (DATA_DIR would be required, prompted for if unset)" || echo none)"
  echo "apt.txt:         $([[ "$has_apt_txt" -eq 1 ]] && echo present || echo "absent/empty")"
  echo "==========================================="
}

# Data is never baked into the image. If the project ships a data/ directory
# and the caller hasn't already pointed DATA_DIR at a real location, prompt
# for one interactively — the app's data must come from a bind-mounted host
# path (typically a Jetstream2 storage volume) instead. Framework-agnostic:
# every framework gets the same data/ convention and the same prompt; only
# the eventual mount target and env var differ (see
# container_data_mount_target_for_framework above). Reads/writes the
# caller's PROJECT_DIR / DATA_DIR globals.
resolve_data_dir() {
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
        echo "A data directory path is required — this project reads from data/." >&2
      elif [[ ! -d "$DATA_DIR" ]]; then
        echo "'$DATA_DIR' is not a directory. Try again." >&2
        DATA_DIR=""
      fi
    done
  elif [[ -n "$DATA_DIR" && ! -d "$DATA_DIR" ]]; then
    echo "DATA_DIR '$DATA_DIR' is not a directory." >&2
    exit 1
  fi
}

# R Shiny only: if the project has no renv.lock, generate one before the
# real `docker build`, by building Dockerfile.r-shiny's `deps-base` stage
# (the same apt/compile-header environment the real build uses) and running
# generate_lock.R inside it — a plain `docker run`, not `docker build`, so a
# compile failure (e.g. a CRAN-latest package needing a newer system library
# than BASE_IMAGE ships) surfaces here with clean output, before the real
# build starts. Doesn't resolve that failure itself — see
# docs/deployment.md's "Pinning R package versions" section for the manual
# fallback — but locks in whatever version does work once you've fixed it
# and re-run.
#
# Reads from the caller: TOOLING_DIR, PROJECT_DIR, IMAGE_NAME, BASE_IMAGE,
# DOCKERFILE_PATH, SUPPORT_FILES (same as build_image()). Temporarily
# overrides IMAGE_NAME/BUILD_TARGET to reuse build_image() for the
# deps-base stage, then restores them.
generate_renv_lock() {
  echo "No renv.lock found — generating one against $BASE_IMAGE before the build..." >&2

  local real_image_name="$IMAGE_NAME"
  IMAGE_NAME="${real_image_name}-deps-base"
  BUILD_TARGET="deps-base"
  build_image
  IMAGE_NAME="$real_image_name"
  BUILD_TARGET=""

  if ! docker run --rm \
    -v "$(cd "$PROJECT_DIR" && pwd):/app" \
    -v "$TOOLING_DIR/docker/generate_lock.R:/tmp/generate_lock.R:ro" \
    "${real_image_name}-deps-base:latest" \
    Rscript /tmp/generate_lock.R /app; then
    echo "Failed to generate renv.lock. See docs/deployment.md's 'Pinning R package" >&2
    echo "versions' section for how to resolve a compile failure (e.g. a package needing" >&2
    echo "a newer system library than $BASE_IMAGE ships) by pinning an older version by hand." >&2
    exit 1
  fi
  echo "renv.lock generated at $PROJECT_DIR/renv.lock" >&2
}

# Dash/Python Shiny/Streamlit: if a project has no requirements.txt but
# manages its dependencies with uv (a pyproject.toml + uv.lock), generate
# requirements.txt from the lockfile before the build, rather than failing
# outright. Unlike generate_renv_lock() this doesn't need BASE_IMAGE's
# system libraries — uv.lock is already a fully-resolved, pinned dependency
# set, so `uv export` just reformats it, with no package installation or
# network resolution involved (--frozen skips checking the lock against
# pyproject.toml). Uses astral's official uv image rather than BASE_IMAGE
# for that reason.
#
# Reads from the caller: PROJECT_DIR.
generate_requirements_from_uv() {
  echo "No requirements.txt found, but this project has a uv.lock — generating" >&2
  echo "requirements.txt from it..." >&2

  # ghcr.io/astral-sh/uv's ENTRYPOINT is already `uv`, so the command here
  # is just its arguments (no leading `uv` — that would be parsed as an
  # unrecognized `uv uv export` subcommand).
  if ! docker run --rm \
    -v "$(cd "$PROJECT_DIR" && pwd):/app" -w /app \
    ghcr.io/astral-sh/uv:latest \
    export --no-hashes --frozen -o requirements.txt; then
    echo "Failed to generate requirements.txt from uv.lock. Run 'uv export --no-hashes -o" >&2
    echo "requirements.txt' yourself in the project directory (installing uv locally if" >&2
    echo "needed: https://docs.astral.sh/uv/getting-started/installation/), or write" >&2
    echo "requirements.txt by hand." >&2
    exit 1
  fi
  echo "requirements.txt generated at $PROJECT_DIR/requirements.txt" >&2
}

# Assembles a temp build context and runs `docker build`, retrying the whole
# build a couple of times (transient network hiccups fetching BASE_IMAGE or
# apt/pip/CRAN packages are common enough across many different projects to
# be worth retrying before giving up).
#
# Reads from the caller: TOOLING_DIR, DOCKERFILE_PATH, PROJECT_DIR,
# IMAGE_NAME, BASE_IMAGE, DATA_DIR. Also reads two arrays the caller sets up
# beforehand (may be empty):
#   SUPPORT_FILES - extra deploy/docker/ files to copy alongside the
#                   Dockerfile (e.g. apt_retry.sh, install_deps.R)
#   EXTRA_BUILD_ARGS - additional `--build-arg NAME=value` strings
# Optionally reads BUILD_TARGET (unset/empty builds the Dockerfile's default
# last stage) to build a named stage instead — used by generate_renv_lock()
# below to build just Dockerfile.r-shiny's `deps-base` stage.
build_image() {
  local build_ctx
  build_ctx="$(mktemp -d)"
  # A RETURN trap isn't scoped to the function that set it — it persists in
  # the shell and fires on every subsequent function return until cleared.
  # build_image() can be called more than once per script run (once for
  # generate_renv_lock()'s deps-base stage, once for the real build), so the
  # trap clears itself right after firing, or a later, unrelated function
  # return would try to rm -rf this now out-of-scope $build_ctx again.
  trap 'rm -rf "$build_ctx"; trap - RETURN' RETURN

  cp "$DOCKERFILE_PATH" "$build_ctx/Dockerfile"
  local f
  for f in "${SUPPORT_FILES[@]+"${SUPPORT_FILES[@]}"}"; do
    cp "$TOOLING_DIR/docker/$f" "$build_ctx/"
  done
  mkdir -p "$build_ctx/app"
  cp -R "$PROJECT_DIR"/. "$build_ctx/app/"
  if [[ -n "$DATA_DIR" ]]; then
    rm -rf "$build_ctx/app/data"   # served from DATA_DIR at runtime instead
  fi
  touch "$build_ctx/app/apt.txt"   # harmless no-op if the project already has one

  local target_args=()
  [[ -n "${BUILD_TARGET:-}" ]] && target_args=(--target "$BUILD_TARGET")

  local build_tries=3 attempt build_ok=0
  for attempt in $(seq 1 "$build_tries"); do
    if docker build \
      --build-arg BASE_IMAGE="$BASE_IMAGE" \
      "${EXTRA_BUILD_ARGS[@]+"${EXTRA_BUILD_ARGS[@]}"}" \
      "${target_args[@]+"${target_args[@]}"}" \
      -t "$IMAGE_NAME:latest" \
      "$build_ctx"; then
      build_ok=1
      break
    fi
    if [[ "$attempt" -lt "$build_tries" ]]; then
      echo "docker build failed (attempt $attempt/$build_tries) — retrying in 10s..." >&2
      sleep 10
    fi
  done
  if [[ "$build_ok" -ne 1 ]]; then
    echo "docker build failed after $build_tries attempts." >&2
    exit 1
  fi
}

# `docker rm -f` + `docker run -d`, parameterized by internal port and data
# mount target instead of hardcoding R Shiny's 3838/srv-shiny-server path.
# Reads from the caller: CONTAINER_NAME, IMAGE_NAME, INTERNAL_PORT,
# DATA_DIR, MOUNT_TARGET.
#
# Removes by name (in case a stale container with this name exists but isn't
# running) AND by whatever currently holds host port 80 — since every
# container binds port 80 unconditionally (one instance = one app), a prior
# deploy under a *different* name would otherwise be left running and cause
# "port is already allocated" instead of being cleanly replaced.
run_container() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

  local port80_containers
  port80_containers="$(docker ps -aq --filter "publish=80")"
  if [[ -n "$port80_containers" ]]; then
    echo "Removing existing container(s) bound to host port 80: $(echo "$port80_containers" | tr '\n' ' ')"
    docker rm -f $port80_containers >/dev/null
  fi

  local data_mount_args=()
  if [[ -n "$DATA_DIR" ]]; then
    data_mount_args=(-v "$(cd "$DATA_DIR" && pwd):$MOUNT_TARGET" -e "DATA_DIR=$MOUNT_TARGET")
  fi

  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p 80:"$INTERNAL_PORT" \
    "${data_mount_args[@]+"${data_mount_args[@]}"}" \
    "$IMAGE_NAME:latest"
}

# Best-effort public IP lookup for the final "reachable at" message. Not a
# Jetstream2/OpenStack metadata call — a floating/public IP is NAT'd onto
# the instance, so the instance's own metadata service (unlike e.g. AWS's
# public-ipv4 key) has no way to know it. Asking an external "what's my IP"
# service is the reliable, provider-agnostic way to get it instead. Tries
# two such services with a short timeout each, in case one is down; falls
# back to the old placeholder rather than failing the whole script over a
# cosmetic message if both are unreachable (e.g. no outbound internet).
public_ip() {
  local ip
  ip="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null)" || \
    ip="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null)" || true
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$ip"
  else
    echo "<instance-fixed-ip>"
  fi
}

# A clean `docker build` + `docker run -d` only proves the image is valid
# and the container started — not that the app process inside stayed up
# (e.g. a missing data file or an app error can crash it seconds later).
# Poll the app before declaring success, and surface the container's own
# logs immediately if it never responds. Reads CONTAINER_NAME from the caller.
run_smoke_test() {
  echo "Waiting for the app to respond on port 80..."
  if command -v curl >/dev/null 2>&1; then
    local smoke_test_ok=0 i
    for i in $(seq 1 30); do
      if curl -fsS -o /dev/null "http://localhost:80/"; then
        smoke_test_ok=1
        break
      fi
      sleep 2
    done
    if [[ "$smoke_test_ok" -eq 1 ]]; then
      echo "Container '$CONTAINER_NAME' running and responding. App should be reachable at http://$(public_ip)/"
    else
      echo "Warning: container '$CONTAINER_NAME' started, but never responded on port 80" >&2
      echo "within 60s. This usually means the app process crashed at runtime (e.g. a" >&2
      echo "missing data file, or an error in the app itself) even though the image built" >&2
      echo "successfully. Recent container logs:" >&2
      docker logs --tail 50 "$CONTAINER_NAME" >&2
      exit 1
    fi
  else
    # public_ip() itself needs curl, so there's no point calling it here.
    echo "curl not found — skipping post-start smoke test." >&2
    echo "Container '$CONTAINER_NAME' started; verify manually at http://<instance-fixed-ip>/."
  fi
}
