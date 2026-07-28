#!/usr/bin/env bash
# Shared, framework-agnostic helpers for build_and_run.sh: the retry-wrapped
# docker build/run, the DATA_DIR prompt, the port/mount-target lookup
# tables, the dry-run summary printer, and the post-start smoke test.
# Sourced by build_and_run.sh — not meant to be run directly. Functions here
# read/write the caller's variables directly (TOOLING_DIR, PROJECT_DIR,
# IMAGE_NAME, BASE_IMAGE, DATA_DIR, etc.) rather than taking everything as
# positional args, matching the rest of this script's style.

# Temp build context created by build_image(), tracked globally so it gets
# cleaned up however the script ends. A RETURN trap (the previous approach)
# doesn't fire on `exit`, so every failure path — a failed docker build, a
# failed cp — leaked a full copy of the project into /tmp. An EXIT trap
# covers returns, exits, and Ctrl-C alike.
BUILD_CTX=""
cleanup_build_ctx() {
  if [[ -n "${BUILD_CTX:-}" && -d "${BUILD_CTX:-}" ]]; then
    rm -rf "$BUILD_CTX"
  fi
  BUILD_CTX=""
  cleanup_preflight_containers
}

# `docker run` is only a client: if this script is interrupted, the
# container it started keeps running on the daemon, and the `--rm` never
# fires because the container never exits. A cancelled R Shiny build would
# otherwise leave an renv install consuming CPU indefinitely. The preflight
# containers are given predictable names precisely so they can be found and
# removed here.
cleanup_preflight_containers() {
  local base="${IMAGE_NAME:-dashboard-app}"
  docker rm -f "${base}-lockgen" "${base}-uvgen" >/dev/null 2>&1 || true
}
# INT/TERM get their own handlers that exit explicitly: a bare signal trap
# runs the handler and then *resumes* the script, which on Ctrl-C during a
# docker build would fall through into the retry loop instead of stopping.
trap cleanup_build_ctx EXIT
trap 'cleanup_build_ctx; exit 130' INT
trap 'cleanup_build_ctx; exit 143' TERM

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
  # When absent, say what to do about it rather than just "none". Moving
  # data out of the project onto a storage volume is the recommended
  # arrangement, and it makes this read "none" — so a bare "none" is most
  # misleading for exactly the projects that are set up correctly.
  echo "data/ directory: $([[ "$has_data_dir" -eq 1 ]] \
    && echo "present (DATA_DIR would be required, prompted for if unset)" \
    || echo "not in the project (set DATA_DIR=/path to mount data from elsewhere)")"
  echo "apt.txt:         $([[ "$has_apt_txt" -eq 1 ]] && echo present || echo "absent/empty")"
  echo "==========================================="
}

# The --dry-run summary again, as stable `key=value` lines for programs
# (the Tkinter GUI in deploy/gui/) instead of prose for people.
#
# key=value rather than JSON on purpose: every value here is a single line
# with no `=` in the key, so parsing is `line.split("=", 1)` and emitting
# needs no escaping — whereas hand-rolling JSON string escaping in bash is
# exactly the kind of thing that looks fine until a project path contains a
# quote or a backslash.
#
# The contract this promises to callers:
#   - keys are stable; new keys may be ADDED, existing ones not renamed
#   - values are single-line and never quoted
#   - this goes to stdout alone; warnings still go to stderr, so a caller
#     capturing stdout gets a clean stream
#
# container_port and data_mount_target are included specifically so a caller
# never hardcodes 3838/8050/8000/8501 or the two mount paths — they come from
# the same lookup functions the deploy itself uses, above.
print_dry_run_porcelain() {
  local deps_state="$1" has_data_dir="$2" has_apt_txt="$3" uses_geospatial="$4"
  echo "project_dir=$PROJECT_DIR"
  echo "framework=$FRAMEWORK"
  echo "entry_file=${ENTRY_FILE:-}"
  echo "entry_point_desc=$ENTRY_POINT_DESC"
  echo "base_image=$BASE_IMAGE"
  echo "deps_state=$deps_state"
  echo "uses_geospatial=$uses_geospatial"
  echo "has_data_dir=$has_data_dir"
  echo "has_apt_txt=$has_apt_txt"
  echo "container_port=$(container_port_for_framework "$FRAMEWORK")"
  echo "data_mount_target=$(container_data_mount_target_for_framework "$FRAMEWORK")"
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

# Posit publishes Shiny Server as an amd64-only .deb, so Dockerfile.r-shiny
# can only build on amd64 — on an arm64 host (an Apple Silicon laptop, most
# commonly) `gdebi` refuses the package and the build dies at the Shiny
# Server step, several minutes in, with an error that doesn't mention
# architecture at all. Jetstream2 instances are x86_64, so this never bites
# in production; it bites when testing a change locally before deploying.
# Building through emulation is slow but it works, and it's strictly better
# than the framework being untestable off-x86_64. Only applies to r-shiny —
# the 3 Python frameworks build natively on either architecture. Set
# BUILD_PLATFORM explicitly to override.
#
# Reads FRAMEWORK from the caller; sets BUILD_PLATFORM.
resolve_build_platform() {
  BUILD_PLATFORM="${BUILD_PLATFORM:-}"
  [[ -n "$BUILD_PLATFORM" ]] && return 0
  [[ "$FRAMEWORK" == "r-shiny" ]] || return 0

  local server_arch
  server_arch="$(docker version --format '{{.Server.Arch}}' 2>/dev/null)" || server_arch=""
  if [[ -n "$server_arch" && "$server_arch" != "amd64" ]]; then
    BUILD_PLATFORM="linux/amd64"
    echo "Note: this Docker host is $server_arch, but Shiny Server is only published as an" >&2
    echo "amd64 .deb — building with --platform linux/amd64 under emulation. Expect a" >&2
    echo "significantly slower build. (Jetstream2 instances are x86_64, so this only" >&2
    echo "affects local testing.) Set BUILD_PLATFORM to override." >&2
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

  # Must match the platform the deps-base image was just built for, or
  # Docker silently runs it under a different arch (or refuses to start it).
  local run_platform_args=()
  [[ -n "${BUILD_PLATFORM:-}" ]] && run_platform_args=(--platform "$BUILD_PLATFORM")

  # Named so it can be found and removed if this build is interrupted.
  # `docker run` is only a client: killing it leaves the container running
  # on the daemon, and --rm never fires because the container never exits.
  # A cancelled R build would otherwise leave an renv install burning CPU
  # on the instance indefinitely.
  local lockgen_name="${real_image_name}-lockgen"
  docker rm -f "$lockgen_name" >/dev/null 2>&1 || true

  if ! docker run --rm --name "$lockgen_name" \
    "${run_platform_args[@]+"${run_platform_args[@]}"}" \
    -v "$(cd "$PROJECT_DIR" && pwd):/app" \
    -v "$TOOLING_DIR/docker/generate_lock.R:/tmp/generate_lock.R:ro" \
    "${real_image_name}-deps-base:latest" \
    Rscript /tmp/generate_lock.R /app; then
    echo "Failed to generate renv.lock. See docs/deployment.md's 'Pinning R package" >&2
    echo "versions' section for how to resolve a compile failure (e.g. a package needing" >&2
    echo "a newer system library than $BASE_IMAGE ships) by pinning an older version by hand." >&2
    echo "(Leaving the ${real_image_name}-deps-base image in place for debugging — remove" >&2
    echo "it with 'docker rmi ${real_image_name}-deps-base:latest' once you're done.)" >&2
    exit 1
  fi
  echo "renv.lock generated at $PROJECT_DIR/renv.lock" >&2

  # This preflight tag is scaffolding, not something to keep — untag it so
  # it doesn't accumulate one stale image per R project deployed. The
  # underlying layers stay in Docker's build cache, so the real build below
  # still reuses them; they just become prunable rather than permanent.
  docker rmi "${real_image_name}-deps-base:latest" >/dev/null 2>&1 || true
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
  # Named for the same reason as the lockfile container above.
  local uvgen_name="${IMAGE_NAME:-dashboard-app}-uvgen"
  docker rm -f "$uvgen_name" >/dev/null 2>&1 || true

  if ! docker run --rm --name "$uvgen_name" \
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
  BUILD_CTX="$(mktemp -d)"
  local build_ctx="$BUILD_CTX"

  cp "$DOCKERFILE_PATH" "$build_ctx/Dockerfile"
  local f
  for f in "${SUPPORT_FILES[@]+"${SUPPORT_FILES[@]}"}"; do
    cp "$TOOLING_DIR/docker/$f" "$build_ctx/"
  done
  mkdir -p "$build_ctx/app"

  # Copy via tar rather than `cp -R` so junk can be excluded *during* the
  # copy instead of deleted afterward. This matters most for data/: these
  # projects routinely carry multi-GB datasets, and copying one into a temp
  # build context only to delete it (and, for the R deps-base preflight,
  # not deleting it at all) both fills the disk and stalls the build while
  # Docker uploads the context to the daemon. The VCS/venv/cache excludes
  # are the same idea for correctness rather than size: `COPY app/ .` would
  # otherwise bake .git history and any stray .env into the image layers.
  local exclude_args=(
    --exclude=./.git
    --exclude=./.venv
    --exclude=./venv
    --exclude=./__pycache__
    --exclude=./.Rproj.user
    --exclude=./node_modules
    --exclude=./.DS_Store
    --exclude=./.env
  )
  # Data is bind-mounted from DATA_DIR at runtime, never baked in.
  [[ -n "$DATA_DIR" ]] && exclude_args+=(--exclude=./data)
  tar -cf - -C "$PROJECT_DIR" "${exclude_args[@]}" . | tar -xf - -C "$build_ctx/app"

  touch "$build_ctx/app/apt.txt"   # harmless no-op if the project already has one

  # Belt-and-braces against the excludes above drifting out of sync with
  # what the Dockerfiles COPY — .dockerignore is enforced by the daemon.
  cat > "$build_ctx/.dockerignore" <<'DOCKERIGNORE'
**/.git
**/.venv
**/venv
**/__pycache__
**/*.pyc
**/.Rproj.user
**/node_modules
**/.DS_Store
**/.env
DOCKERIGNORE

  local target_args=()
  [[ -n "${BUILD_TARGET:-}" ]] && target_args=(--target "$BUILD_TARGET")

  local platform_args=()
  [[ -n "${BUILD_PLATFORM:-}" ]] && platform_args=(--platform "$BUILD_PLATFORM")

  local build_tries=3 attempt build_ok=0
  for attempt in $(seq 1 "$build_tries"); do
    if docker build \
      --build-arg BASE_IMAGE="$BASE_IMAGE" \
      "${EXTRA_BUILD_ARGS[@]+"${EXTRA_BUILD_ARGS[@]}"}" \
      "${target_args[@]+"${target_args[@]}"}" \
      "${platform_args[@]+"${platform_args[@]}"}" \
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
    exit 1   # EXIT trap cleans up $BUILD_CTX
  fi

  cleanup_build_ctx
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

  local port80_containers port80_names
  port80_containers="$(docker ps -aq --filter "publish=80")"
  if [[ -n "$port80_containers" ]]; then
    # Names, not the 64-char IDs used for the removal itself — the point of
    # the message is to tell you which app is being replaced.
    port80_names="$(docker ps -a --filter "publish=80" --format '{{.Names}}' | tr '\n' ' ')"
    echo "Replacing container(s) already bound to host port 80: ${port80_names% }"
    # Deliberately unquoted: docker ps -q returns one ID per line and each
    # must become a separate argument. IDs are hex, so there's nothing for
    # globbing to expand.
    # shellcheck disable=SC2086
    docker rm -f $port80_containers >/dev/null
  fi

  local data_mount_args=()
  if [[ -n "$DATA_DIR" ]]; then
    data_mount_args=(-v "$(cd "$DATA_DIR" && pwd):$MOUNT_TARGET" -e "DATA_DIR=$MOUNT_TARGET")
  fi

  # Match the platform the image was built for, or Docker prints a "requested
  # image's platform does not match the detected host platform" warning on
  # every start of an emulated (r-shiny-on-arm64) image.
  local run_platform_args=()
  [[ -n "${BUILD_PLATFORM:-}" ]] && run_platform_args=(--platform "$BUILD_PLATFORM")

  # >/dev/null: `docker run -d` echoes the 64-char container ID, which is
  # noise for the audience this tool is for — the useful confirmation is the
  # summary run_smoke_test() prints once the app actually responds.
  docker run -d \
    "${run_platform_args[@]+"${run_platform_args[@]}"}" \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p 80:"$INTERNAL_PORT" \
    "${data_mount_args[@]+"${data_mount_args[@]}"}" \
    "$IMAGE_NAME:latest" >/dev/null
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
# (e.g. a missing dependency or a bad entry point can kill it seconds
# later). Poll the app before declaring success, and surface the
# container's own logs immediately if it never responds.
#
# What this does NOT catch: an error *inside* an app that still serves.
# Streamlit and Shiny both catch script-level exceptions and render them in
# the browser, so the HTTP check passes and this reports success — the app
# is genuinely reachable, it just shows a traceback to whoever opens it.
# This is a liveness check, not a correctness check; nothing short of
# loading the page can tell you the dashboard actually works.
#
# Reads CONTAINER_NAME from the caller.
run_smoke_test() {
  echo "Waiting for the app to respond on port 80..."
  if command -v curl >/dev/null 2>&1; then
    local smoke_test_ok=0
    # `_`: the counter is only there to bound the loop at 30 tries (~60s).
    for _ in $(seq 1 30); do
      # 2>/dev/null: -S would otherwise print "curl: (7) Failed to connect"
      # on every poll while the app is still starting — up to 30 alarming
      # error lines during an ordinary, successful startup. A genuine
      # failure is reported by the branch below, with the container's logs.
      if curl -fsS -o /dev/null "http://localhost:80/" 2>/dev/null; then
        smoke_test_ok=1
        break
      fi
      sleep 2
    done
    if [[ "$smoke_test_ok" -eq 1 ]]; then
      # The commands are spelled out rather than left to the docs: this tool
      # is aimed at researchers who may not use Docker day to day, and this
      # is the moment they need them.
      echo
      echo "  Deployed. '$CONTAINER_NAME' is running and responding."
      echo
      echo "    URL       http://$(public_ip)/"
      echo "    Logs      docker logs -f $CONTAINER_NAME"
      echo "    Restart   docker restart $CONTAINER_NAME"
      echo "    Stop      docker stop $CONTAINER_NAME"
      echo
      echo "  Re-run this script to deploy again after a code change; it replaces"
      echo "  the running container for you."
      echo
    else
      echo "Warning: container '$CONTAINER_NAME' started, but never responded on port 80" >&2
      echo "within 60s. The app process died at startup rather than serving — usually a" >&2
      echo "missing dependency, a wrong entry point, or a port mismatch, not a bug in the" >&2
      echo "app's own logic (frameworks render those in the browser instead of exiting)." >&2
      echo "The image built fine; this is a runtime failure. Recent container logs:" >&2
      docker logs --tail 50 "$CONTAINER_NAME" >&2
      echo >&2
      echo "The container is left in place so you can investigate. Note it runs with" >&2
      echo "--restart unless-stopped, so if the app is crashing it's restarting in a loop:" >&2
      echo "  docker logs -f $CONTAINER_NAME   # full log, follow live" >&2
      echo "  docker stop $CONTAINER_NAME      # stop the restart loop" >&2
      exit 1
    fi
  else
    # public_ip() itself needs curl, so there's no point calling it here.
    echo "curl not found — skipping post-start smoke test." >&2
    echo "Container '$CONTAINER_NAME' started; verify manually at http://<instance-fixed-ip>/."
  fi
}
