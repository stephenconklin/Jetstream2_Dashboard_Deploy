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
build_image() {
  local build_ctx
  build_ctx="$(mktemp -d)"
  trap 'rm -rf "$build_ctx"' RETURN

  cp "$DOCKERFILE_PATH" "$build_ctx/Dockerfile"
  local f
  for f in "${SUPPORT_FILES[@]}"; do
    cp "$TOOLING_DIR/docker/$f" "$build_ctx/"
  done
  mkdir -p "$build_ctx/app"
  cp -R "$PROJECT_DIR"/. "$build_ctx/app/"
  if [[ -n "$DATA_DIR" ]]; then
    rm -rf "$build_ctx/app/data"   # served from DATA_DIR at runtime instead
  fi
  touch "$build_ctx/app/apt.txt"   # harmless no-op if the project already has one

  local build_tries=3 attempt build_ok=0
  for attempt in $(seq 1 "$build_tries"); do
    if docker build \
      --build-arg BASE_IMAGE="$BASE_IMAGE" \
      "${EXTRA_BUILD_ARGS[@]}" \
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
run_container() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

  local data_mount_args=()
  if [[ -n "$DATA_DIR" ]]; then
    data_mount_args=(-v "$(cd "$DATA_DIR" && pwd):$MOUNT_TARGET" -e "DATA_DIR=$MOUNT_TARGET")
  fi

  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p 80:"$INTERNAL_PORT" \
    "${data_mount_args[@]}" \
    "$IMAGE_NAME:latest"
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
      echo "Container '$CONTAINER_NAME' running and responding. App should be reachable at http://<instance-fixed-ip>/"
    else
      echo "Warning: container '$CONTAINER_NAME' started, but never responded on port 80" >&2
      echo "within 60s. This usually means the app process crashed at runtime (e.g. a" >&2
      echo "missing data file, or an error in the app itself) even though the image built" >&2
      echo "successfully. Recent container logs:" >&2
      docker logs --tail 50 "$CONTAINER_NAME" >&2
      exit 1
    fi
  else
    echo "curl not found — skipping post-start smoke test." >&2
    echo "Container '$CONTAINER_NAME' started; verify manually at http://<instance-fixed-ip>/."
  fi
}
