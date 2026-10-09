#!/usr/bin/env bash
# Shared, framework-agnostic helpers for build_and_run.sh: the retry-wrapped
# docker build/run, the DATA_DIR prompt, the port/mount-target lookup
# tables, the dry-run summary printer, and the post-start smoke test.
# Sourced by build_and_run.sh — not meant to be run directly. Functions here
# read/write the caller's variables directly (TOOLING_DIR, PROJECT_DIR,
# IMAGE_NAME, BASE_IMAGE, DATA_DIR, etc.) rather than taking everything as
# positional args, matching the rest of this script's style.

# Where the container binds (0.0.0.0:80 directly, or loopback behind nginx)
# and how to health-check it. Sourced here rather than by each caller so
# build_and_run.sh and manage.sh cannot drift on the answer.
# shellcheck source-path=SCRIPTDIR
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proxy.sh"

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
#
# Only the ones THIS process started. manage.sh sources this file too, and so
# does every `build_and_run.sh --dry-run`, so this trap fires every time the
# GUI checks status or inspects a project. Removing the names unconditionally
# killed a lockfile generation running in a *different* process — mid-build,
# with no error — whenever anything checked on the dashboard during an R
# build, which the GUI's live bar does every 30 seconds.
PREFLIGHT_STARTED=""
cleanup_preflight_containers() {
  local name
  for name in $PREFLIGHT_STARTED; do
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
  PREFLIGHT_STARTED=""
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

# Where the project's data folder gets bind-mounted (and where the DATA_DIR
# env var, set alongside it, points) inside the container: the app's own
# folder plus DATA_SUBDIR, the name the app's code reads from (default data).
container_data_mount_target_for_framework() {
  local subdir="${2:-data}"
  case "$1" in
    r-shiny)                      echo "/srv/shiny-server/$subdir" ;;
    dash|python-shiny|streamlit)  echo "/app/$subdir" ;;
    *) echo "container_data_mount_target_for_framework: unknown framework '$1'" >&2; return 1 ;;
  esac
}

# Above this, data inside the app folder is too big to publish with the
# code: every re-publish re-copies it and the image grows with it. Big data
# belongs on a storage volume, mounted with DATA_DIR. A warning, not a
# refusal — the GUI says so before publishing.
BUNDLE_WARN_KB=$((1024 * 1024))

# What would be copied into the image, in KB: the project minus the things
# build_image() leaves out (sets APP_FOLDER_KB), and the DATA_SUBDIR folder
# on its own (sets DATA_SUBDIR_KB). `du -sk` and subtraction rather than one
# filtered walk, because BSD and GNU du disagree on how to exclude. Never
# fails the caller: an unreadable folder reports 0.
measure_project_size() {
  local kb sub
  APP_FOLDER_KB="$( (du -sk "$PROJECT_DIR" 2>/dev/null || true) | awk 'NR==1 {print $1+0}')"
  APP_FOLDER_KB="${APP_FOLDER_KB:-0}"
  for sub in .git .venv venv node_modules __pycache__ .Rproj.user rsconnect \
             renv/library renv/staging .RData; do
    [[ -e "$PROJECT_DIR/$sub" ]] || continue
    kb="$( (du -sk "$PROJECT_DIR/$sub" 2>/dev/null || true) | awk 'NR==1 {print $1+0}')"
    APP_FOLDER_KB=$(( APP_FOLDER_KB - ${kb:-0} ))
  done
  [[ "$APP_FOLDER_KB" -lt 0 ]] && APP_FOLDER_KB=0
  DATA_SUBDIR_KB=0
  if [[ -d "$PROJECT_DIR/$DATA_SUBDIR" ]]; then
    DATA_SUBDIR_KB="$( (du -sk "$PROJECT_DIR/$DATA_SUBDIR" 2>/dev/null || true) | awk 'NR==1 {print $1+0}')"
    DATA_SUBDIR_KB="${DATA_SUBDIR_KB:-0}"
  fi
  return 0
}

# KB as a short human size, for messages.
human_kb() {
  awk -v kb="$1" 'BEGIN {
    if (kb >= 1048576) printf "%.1f GB", kb / 1048576
    else if (kb >= 1024) printf "%.0f MB", kb / 1024
    else printf "%d KB", kb }'
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
  if [[ "$ENTRY_STATE" == "ambiguous" ]]; then
    echo "                 (a deploy will stop until ENTRY_FILE names one of these)"
  elif [[ "$FRAMEWORK" == "r-shiny" && -n "$ENTRY_FILE" && "$ENTRY_FILE" != "app.R" ]]; then
    echo "                 (not named app.R — the build adds an app.R that runs it)"
  fi
  echo "Base image:      $BASE_IMAGE"
  echo "Dependencies:    $deps_status"
  # When absent, say what to do about it rather than just "none". Moving
  # data out of the project onto a storage volume is the recommended
  # arrangement, and it makes this read "none" — so a bare "none" is most
  # misleading for exactly the projects that are set up correctly.
  echo "App folder:      $(human_kb "$APP_FOLDER_KB") would be published with the app"
  local data_line
  if [[ "$has_data_dir" -eq 1 ]]; then
    data_line="present, $(human_kb "$DATA_SUBDIR_KB") (mount it with DATA_DIR, or BUNDLE_DATA=1 to publish it with the app)"
  elif [[ "${DATA_DIR_REFS:-0}" -gt 0 ]]; then
    data_line="not in the project, but the code reads $DATA_DIR_REFS file(s) from it — set DATA_DIR=/path"
  else
    data_line="not in the project (set DATA_DIR=/path to mount data from elsewhere)"
  fi
  printf '%-17s%s\n' "$DATA_SUBDIR/ folder:" "$data_line"
  echo "apt.txt:         $([[ "$has_apt_txt" -eq 1 ]] && echo present || echo "absent/empty")"
  if [[ "$CODE_NOTE_COUNT" -gt 0 ]]; then
    echo "Code check:      $CODE_NOTE_COUNT thing(s) worth a look (advisory, won't stop a deploy):"
    printf '%s' "$CODE_NOTES" | sed 's/^/                   /'
  else
    echo "Code check:      nothing found"
  fi
  echo "Serving:         $([[ "$PROXY_ENABLED" -eq 1 ]] \
    && echo "nginx on port 80 -> app on $APP_BIND_ADDR:$APP_HOST_PORT" \
    || echo "app published directly on port 80 (no proxy; run bootstrap.sh to add one)")"
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
  echo "entry_state=$ENTRY_STATE"
  # "/"-separated: the one character that can never appear in a file name.
  echo "entry_candidates=$ENTRY_CANDIDATES"
  echo "base_image=$BASE_IMAGE"
  echo "deps_state=$deps_state"
  echo "uses_geospatial=$uses_geospatial"
  echo "has_data_dir=$has_data_dir"
  echo "has_apt_txt=$has_apt_txt"
  echo "container_port=$(container_port_for_framework "$FRAMEWORK")"
  echo "data_mount_target=$(container_data_mount_target_for_framework "$FRAMEWORK" "$DATA_SUBDIR")"
  echo "data_subdir=$DATA_SUBDIR"
  echo "app_folder_kb=$APP_FOLDER_KB"
  echo "data_subdir_kb=$DATA_SUBDIR_KB"
  echo "bundle_warn_kb=$BUNDLE_WARN_KB"
  echo "data_dir_refs=${DATA_DIR_REFS:-0}"
  # Numbered keys rather than one multi-line value, keeping the one-line
  # promise above. code_notes is the count; code_note_1..N are "file:line:
  # message", in a stable order.
  echo "code_notes=$CODE_NOTE_COUNT"
  local n=0 note
  while IFS= read -r note; do
    [[ -n "$note" ]] || continue
    n=$((n + 1))
    echo "code_note_$n=$note"
  done <<< "$CODE_NOTES"
  echo "proxy_enabled=$PROXY_ENABLED"
  echo "app_bind_addr=$APP_BIND_ADDR"
  echo "app_host_port=$APP_HOST_PORT"
  echo "server_name=$PROXY_SERVER_NAME"
}

# Decides where the app's data folder (DATA_SUBDIR, default data/) comes from
# when the project ships one: mounted from DATA_DIR (typically a Jetstream2
# storage volume — survives rebuilds, can be updated without one, and keeps
# big data out of the image), or published inside the image with the code
# (BUNDLE_DATA=1 — simplest, fine for small data). Without either, ask on a
# terminal and fail with instructions off one. Framework-agnostic: only the
# eventual mount target differs (see container_data_mount_target_for_framework
# above). Reads/writes the caller's PROJECT_DIR / DATA_DIR / DATA_SUBDIR /
# BUNDLE_DATA globals.
resolve_data_dir() {
  if [[ -n "$DATA_DIR" && ! -d "$DATA_DIR" ]]; then
    echo "DATA_DIR '$DATA_DIR' is not a directory." >&2
    exit 1
  fi
  [[ -d "$PROJECT_DIR/$DATA_SUBDIR" && -z "$DATA_DIR" ]] || return 0

  if [[ "$BUNDLE_DATA" != "1" ]]; then
    if [[ ! -t 0 ]]; then
      echo "This project has a $DATA_SUBDIR/ folder. Say where its data should come from:" >&2
      echo "  DATA_DIR=/media/volume/<volume-name>/...  to mount it from a storage volume, or" >&2
      echo "  BUNDLE_DATA=1                             to publish the folder with the app." >&2
      exit 1
    fi
    echo
    echo "This project has a $DATA_SUBDIR/ folder ($(human_kb "$DATA_SUBDIR_KB")). Either:"
    echo "  - enter the full path where that data lives on this server — usually a"
    echo "    storage volume under /media/volume/<volume-name>/... ('df -h' lists them) —"
    echo "    so it can be updated without re-publishing, or"
    echo "  - press Enter to publish the folder with the app (fine for small data)."
    while true; do
      read -rp "Path to your data (or Enter to publish it with the app): " DATA_DIR
      if [[ -z "$DATA_DIR" ]]; then
        BUNDLE_DATA=1
        break
      elif [[ -d "$DATA_DIR" ]]; then
        break
      fi
      echo "'$DATA_DIR' is not a directory. Try again." >&2
    done
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
# docs/user-guide/reference/deployment.md's "Pinning R package versions" section for the manual
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
  PREFLIGHT_STARTED+=" $lockgen_name"

  if ! docker run --rm --name "$lockgen_name" \
    "${run_platform_args[@]+"${run_platform_args[@]}"}" \
    -v "$(cd "$PROJECT_DIR" && pwd):/app" \
    -v "$TOOLING_DIR/docker/generate_lock.R:/tmp/generate_lock.R:ro" \
    "${real_image_name}-deps-base:latest" \
    Rscript /tmp/generate_lock.R /app; then
    echo "Failed to generate renv.lock. See docs/user-guide/reference/deployment.md's 'Pinning R package" >&2
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
  PREFLIGHT_STARTED+=" $uvgen_name"

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

# Adjusts the build's *copy* of an R Shiny project so Shiny Server can run
# it as the researcher wrote it. Never touches the project folder itself.
#
# 1. A main file not named app.R gets an app.R that runs it. Shiny Server
#    only looks for app.R (or ui.R/server.R), and renaming the researcher's
#    file instead would break anything in their code that refers to it.
#    shinyAppFile() when the file ends in its own shinyApp() call; otherwise
#    the file builds `ui` and `server` for RStudio's "Run App" button, so
#    source it and finish the job ourselves.
#
# 2. An .Rprofile that activates renv is disabled. Shiny Server starts R in
#    the app folder, so R runs the project's .Rprofile — and a
#    `source("renv/activate.R")` either points at an renv/ folder that never
#    made it to the server (in non-interactive R that's "Execution halted",
#    so every session dies at startup) or activates a project library that
#    install_deps.R never filled. Packages live in the image's site library;
#    nothing here needs renv at run time. Only the activation line is
#    commented out, so anything else the profile sets still applies.
#
# Reads FRAMEWORK, ENTRY_FILE from the caller.
prepare_r_build_copy() {
  local app_dir="$1"

  if [[ -n "${ENTRY_FILE:-}" && "$ENTRY_FILE" != "app.R" ]]; then
    # Escaped for an R double-quoted string literal.
    local r_name
    r_name="$(printf '%s' "$ENTRY_FILE" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    {
      echo "# Added by Jetstream2 Dashboard Deploy: Shiny Server runs app.R, and"
      echo "# this project's main file is $ENTRY_FILE. Not part of your project."
      if file_calls_shiny_app "$app_dir/$ENTRY_FILE"; then
        echo "shiny::shinyAppFile(\"$r_name\")"
      else
        echo "source(\"$r_name\", local = TRUE)"
        echo "shiny::shinyApp(ui = ui, server = server)"
      fi
    } > "$app_dir/app.R"
    echo "Main file is $ENTRY_FILE — added an app.R to the build that runs it." >&2
  fi

  if [[ -f "$app_dir/.Rprofile" ]] \
     && grep -qE '^[^#]*renv/activate\.R' "$app_dir/.Rprofile"; then
    sed -i.orig -E 's|^([^#]*renv/activate\.R.*)$|# Disabled by Jetstream2 Dashboard Deploy: \1|' \
      "$app_dir/.Rprofile"
    rm -f "$app_dir/.Rprofile.orig"
    echo "Your .Rprofile activates renv — disabled that line in the build (packages are" >&2
    echo "installed into the image instead). Your own copy is unchanged." >&2
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
    # RStudio session leftovers. .RData in particular can be large and is a
    # snapshot of someone's workspace, not part of the app.
    --exclude=./.RData
    --exclude=./.Rhistory
    --exclude=./rsconnect
    # A project renv library holds packages compiled for the researcher's own
    # machine (often macOS or Windows binaries). install_deps.R installs the
    # Linux equivalents into the image instead.
    --exclude=./renv/library
    --exclude=./renv/staging
  )
  # Mounted from DATA_DIR at run time, so the project's own copy (if any)
  # stays out of the image.
  [[ -n "$DATA_DIR" ]] && exclude_args+=("--exclude=./$DATA_SUBDIR")
  tar -cf - -C "$PROJECT_DIR" "${exclude_args[@]}" . | tar -xf - -C "$build_ctx/app"

  touch "$build_ctx/app/apt.txt"   # harmless no-op if the project already has one

  # Not for the deps-base preflight, which only reads apt.txt from the copy.
  if [[ "$FRAMEWORK" == "r-shiny" && -z "${BUILD_TARGET:-}" ]]; then
    prepare_r_build_copy "$build_ctx/app"
  fi

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
app/.RData
app/.Rhistory
app/rsconnect
app/renv/library
app/renv/staging
DOCKERIGNORE

  local target_args=()
  [[ -n "${BUILD_TARGET:-}" ]] && target_args=(--target "$BUILD_TARGET")

  local platform_args=()
  [[ -n "${BUILD_PLATFORM:-}" ]] && platform_args=(--platform "$BUILD_PLATFORM")

  local build_log
  build_log="$(mktemp)"

  local build_tries=3 attempt build_ok=0
  for attempt in $(seq 1 "$build_tries"); do
    if docker build \
      --build-arg BASE_IMAGE="$BASE_IMAGE" \
      "${EXTRA_BUILD_ARGS[@]+"${EXTRA_BUILD_ARGS[@]}"}" \
      "${target_args[@]+"${target_args[@]}"}" \
      "${platform_args[@]+"${platform_args[@]}"}" \
      -t "$IMAGE_NAME:latest" \
      "$build_ctx" 2>&1 | tee "$build_log"; then
      build_ok=1
      break
    fi

    # The retries exist for transient mirror/network hiccups. A dependency
    # that cannot be built will fail identically every time, so retrying it
    # just burns 20 seconds and prints the same error three times, pushing
    # the real cause further up the log — which is where a researcher then
    # has to go looking for it.
    if build_failure_is_permanent "$build_log"; then
      echo >&2
      echo "This is a problem with the project's dependencies, not a network" >&2
      echo "hiccup — retrying wouldn't help, so stopping here." >&2
      break
    fi

    if [[ "$attempt" -lt "$build_tries" ]]; then
      echo "docker build failed (attempt $attempt/$build_tries) — retrying in 10s..." >&2
      sleep 10
    fi
  done

  if [[ "$build_ok" -ne 1 ]]; then
    summarize_build_failure "$build_log"
    rm -f "$build_log"
    exit 1   # EXIT trap cleans up $BUILD_CTX
  fi

  rm -f "$build_log"
  cleanup_build_ctx
}

# Distinguish "this will never work" from "the network wobbled".
# Deliberately conservative: anything not listed here is still retried, so a
# misclassification costs a slower failure rather than a missed recovery.
build_failure_is_permanent() {
  grep -qE \
    'metadata-generation-failed|Could not build wheels|legacy-install-failure|fatal error:|Could not find a version that satisfies|No matching distribution found|invalid tag|pull access denied|manifest unknown|manifest for .* not found|Unable to locate package|has no installation candidate|undefined reference to|configure: error:' \
    "$1"
}

# Pull the actual reason out of a long build log.
#
# Without this the last line a researcher sees is "docker build failed",
# with the cause hundreds of lines up — and after a --no-cache rebuild of an
# R geospatial image, "up" can mean tens of thousands of lines.
summarize_build_failure() {
  local log="$1"
  echo >&2
  echo "=== The build failed. The relevant part of the log: ===" >&2

  # Two tiers. First look for the specific complaint from pip, apt, gcc or R;
  # only fall back to docker's own "did not complete successfully" wrapper,
  # which names the failing RUN line but not the reason.
  #
  # Note the deliberate absence of a `^` anchor: BuildKit prefixes every line
  # of build output with a step/timestamp ("6.622 error: ..."), so anchored
  # patterns match nothing at all.
  local specific generic
  specific="$(grep -iE \
      'error in .+ setup command|metadata-generation-failed|Could not build wheels|Failed building wheel|No matching distribution|Could not find a version that satisfies|fatal error:|Unable to locate package|has no installation candidate|undefined reference to|there is no package called|installation of package .+ had non-zero exit status|configure: error:' \
      "$log" \
    | grep -viE 'this error originates from a subprocess|hint: See above|note: This' \
    | tail -6)"

  generic="$(grep -iE 'did not complete successfully|returned a non-zero code' "$log" | tail -2)"

  if [[ -n "$specific" ]]; then
    printf '%s\n' "$specific" >&2
    [[ -n "$generic" ]] && printf '\n%s\n' "$generic" >&2
  elif [[ -n "$generic" ]]; then
    printf '%s\n' "$generic" >&2
  else
    tail -15 "$log" >&2
  fi

  echo >&2
  echo "A pinned package that won't build is the most common cause. If the" >&2
  echo "version is old, it may predate the Python or R in the base image —" >&2
  echo "either relax the pin, or set BASE_IMAGE to an older one." >&2
  echo "See docs/user-guide/reference/deployment.md's 'Pinning' sections." >&2
}

# `docker rm -f` + `docker run -d`, parameterized by internal port and data
# mount target instead of hardcoding R Shiny's 3838/srv-shiny-server path.
# Reads from the caller: CONTAINER_NAME, IMAGE_NAME, INTERNAL_PORT, FRAMEWORK,
# DATA_DIR, MOUNT_TARGET, and (via resolve_app_bind) APP_BIND_ADDR /
# APP_HOST_PORT.
#
# Removes by name (in case a stale container with this name exists but isn't
# running) AND by whatever currently holds the host port — since every
# container binds one unconditionally (one instance = one app), a prior
# deploy under a *different* name would otherwise be left running and cause
# "port is already allocated" instead of being cleanly replaced.
run_container() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

  # Both ports, not just the configured one. Adopting nginx moves the app
  # from 80 to a loopback port, and the container from the previous, direct
  # deploy is still sitting on 80 — where it would block nginx from binding
  # and leave the instance serving the old app forever.
  # `sort -u` because 80 and APP_HOST_PORT can name the same container (a
  # legacy deploy made before any proxy was configured), and `docker rm` on a
  # repeated ID reports an error for the second one.
  local claimed_ids claimed_names port
  claimed_ids=""
  for port in 80 "$APP_HOST_PORT"; do
    claimed_ids+="$(containers_publishing_host_port "$port")"$'\n'
  done
  # `grep -v '^$'` first: the appends above leave a blank line per port with
  # nothing on it, and sort would otherwise pass those through as empty
  # arguments to `docker rm`.
  claimed_ids="$(printf '%s' "$claimed_ids" | grep -v '^[[:space:]]*$' | sort -u | tr '\n' ' ')" || true
  if [[ -n "${claimed_ids// /}" ]]; then
    # shellcheck disable=SC2086
    claimed_names="$(container_names_for_ids $claimed_ids)"
    echo "Replacing container(s) already bound to the host port: $claimed_names"
    # Deliberately unquoted: this is a space-separated list and each ID must
    # become a separate argument. IDs are hex, so there's nothing for
    # globbing to expand.
    # shellcheck disable=SC2086
    docker rm -f $claimed_ids >/dev/null
  fi

  local data_mount_args=()
  local data_host_path=""
  if [[ -n "$DATA_DIR" ]]; then
    data_host_path="$(cd "$DATA_DIR" && pwd)"
    data_mount_args=(-v "$data_host_path:$MOUNT_TARGET" -e "DATA_DIR=$MOUNT_TARGET")
  fi

  # Where this deployment came from, recorded on the container itself.
  #
  # The container is the right place for it because it is the only thing that
  # can't disagree with reality: it describes what is *actually running*, it
  # survives a reboot and a closed GUI, it is replaced atomically by the next
  # deploy, and a deploy made from a terminal records itself exactly as one
  # made from the GUI does. A state file written by whichever tool happened to
  # perform the deploy would drift from the running container the first time
  # the other one was used.
  #
  # Read back by `manage.sh status`, which is how the GUI restores its first
  # three tabs after being reopened. Labels are metadata only — nothing about
  # how the app runs depends on them, so a container deployed before these
  # existed keeps working and simply reports nothing.
  local provenance_args=(
    --label "dashboard.project_dir=$(cd "$PROJECT_DIR" && pwd)"
    --label "dashboard.data_dir=$data_host_path"
    --label "dashboard.data_subdir=$DATA_SUBDIR"
    --label "dashboard.framework=$FRAMEWORK"
    --label "dashboard.entry_file=${ENTRY_FILE:-}"
    --label "dashboard.deployed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  )

  # Match the platform the image was built for, or Docker prints a "requested
  # image's platform does not match the detected host platform" warning on
  # every start of an emulated (r-shiny-on-arm64) image.
  local run_platform_args=()
  [[ -n "${BUILD_PLATFORM:-}" ]] && run_platform_args=(--platform "$BUILD_PLATFORM")

  # A container health check, supplied at run time rather than baked into
  # each Dockerfile — see app_health_cmd() in proxy.sh for why. It buys two
  # things: `manage.sh health` can distinguish "running" from "actually
  # serving", and the autoheal sidecar (started by bootstrap.sh) can restart
  # a container that is alive but wedged. `--restart unless-stopped` cannot
  # do that on its own: it only reacts to the process *exiting*, and the
  # failure mode worth catching here is the one where it doesn't.
  #
  # start-period is charged against the slowest case, not the typical one, and
  # it must not be shorter than the app's own startup allowance — otherwise a
  # legitimately slow app is marked unhealthy while it is still starting, and
  # autoheal restarts it into a loop it can never escape.
  #
  # HEALTH_START_PERIOD is therefore pinned to shiny-server.conf's
  # `app_init_timeout`, which is the longest such allowance any framework here
  # has: a geospatial Shiny worker attaching sf/terra/GDAL/PROJ genuinely takes
  # minutes before it reports "Listening on". Keep the two in sync — raising
  # app_init_timeout without raising this reintroduces the restart loop.
  local health_args=()
  local health_cmd
  if health_cmd="$(app_health_cmd "$FRAMEWORK" "$INTERNAL_PORT")"; then
    health_args=(
      --health-cmd "$health_cmd"
      --health-interval 30s
      # Comfortably above the probe's own --max-time, so a slow-but-alive
      # response is recorded as slow rather than killed and counted a failure.
      --health-timeout 30s
      --health-retries 3
      --health-start-period "$HEALTH_START_PERIOD"
      # What autoheal matches on. Harmless when no sidecar is running.
      --label autoheal=true
    )
  fi

  # >/dev/null: `docker run -d` echoes the 64-char container ID, which is
  # noise for the audience this tool is for — the useful confirmation is the
  # summary run_smoke_test() prints once the app actually responds.
  docker run -d \
    "${run_platform_args[@]+"${run_platform_args[@]}"}" \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "$APP_BIND_ADDR:$APP_HOST_PORT:$INTERNAL_PORT" \
    "${health_args[@]+"${health_args[@]}"}" \
    "${provenance_args[@]+"${provenance_args[@]}"}" \
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

# The address to hand someone. Prefers the configured DNS name over the IP:
# with nginx in front, SERVER_NAME is what any TLS certificate was issued for,
# so the https:// URL only works under that name. Falls back to the public IP
# when no name is configured, which is the ordinary Jetstream2 case.
#
# Reads PROXY_ENABLED / PROXY_SERVER_NAME from resolve_app_bind(). Callers
# that haven't run it still get a sensible answer via the ${x:-} defaults —
# manage.sh and build_and_run.sh both do run it.
public_url() {
  if [[ "${PROXY_ENABLED:-0}" -eq 1 && -n "${PROXY_SERVER_NAME:-}" ]]; then
    # https only if a certificate is actually installed for that name;
    # bootstrap.sh records the scheme it ended up with.
    local scheme
    scheme="$(_proxy_env_get PUBLIC_SCHEME)"
    echo "${scheme:-http}://${PROXY_SERVER_NAME}/"
  else
    echo "http://$(public_ip)/"
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
# R Shiny only: how many Shiny Server workers have died with an R error so
# far. Shiny Server stays up and keeps retrying an app that errors while
# loading, so the container never exits and its restart count never moves —
# the only evidence of a crash loop is in the per-worker logs inside it
# (kept by `preserve_logs` in shiny-server.conf).
r_worker_failures() {
  docker exec "$CONTAINER_NAME" sh -c \
    'grep -l "Execution halted" /var/log/shiny-server/*.log 2>/dev/null | wc -l' \
    2>/dev/null | tr -d '[:space:]' || true
}

# The R error from the most recent failed worker, without the blank lines R
# pads tracebacks with or the `su:` notice Shiny Server writes at the top of
# every worker log. This, not `docker logs`, is what says why an R Shiny
# app won't start: the container's own output is only Shiny Server's.
r_worker_error() {
  docker exec "$CONTAINER_NAME" sh -c \
    'f=$(grep -l "Execution halted" /var/log/shiny-server/*.log 2>/dev/null | tail -n 1);
     [ -n "$f" ] && grep -v -e "^[[:space:]]*$" -e "^su: " "$f" | tail -n 30' 2>/dev/null || true
}

run_smoke_test() {
  local app_url
  app_url="$(app_direct_url)"
  echo "Waiting for the app to respond on ${app_url}..."
  if command -v curl >/dev/null 2>&1; then
    local smoke_test_ok=0 crashed=0 r_failed=0 waited=0
    # The window matches the app's own startup allowance rather than a flat
    # 60s. A geospatial R Shiny worker is given 300s to attach sf/terra/GDAL
    # (shiny-server.conf's app_init_timeout), and a shorter wait here reports
    # a perfectly healthy app as a failed deploy — which, when bootstrap.sh
    # is driving, aborts the whole provision.
    local deadline="${HEALTH_START_PERIOD%s}"
    while [[ "$waited" -lt "$deadline" ]]; do
      # 2>/dev/null: -S would otherwise print "curl: (7) Failed to connect"
      # on every poll while the app is still starting — dozens of alarming
      # error lines during an ordinary, successful startup. A genuine
      # failure is reported by the branch below, with the container's logs.
      if curl -fsS -o /dev/null "$app_url" 2>/dev/null; then
        smoke_test_ok=1
        break
      fi

      # Waiting out a five-minute window for a container that has already
      # died is the wrong trade — a long window must not make a real failure
      # slower to report. The container runs with `--restart unless-stopped`,
      # so a crashing app doesn't stay dead long enough to observe reliably
      # by status alone; a restart count above zero is the durable evidence
      # that it started, fell over, and was picked back up.
      if [[ "$(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 0)" -gt 0 ]]; then
        crashed=1
        break
      fi
      # Two failed workers, not one: Shiny Server retries on every request,
      # so a second identical failure is what separates "this app errors
      # while loading" from a one-off. Checked every 6s to keep the docker
      # exec overhead negligible next to a multi-minute geospatial startup.
      if [[ "$FRAMEWORK" == "r-shiny" && $((waited % 6)) -eq 0 \
            && "$(r_worker_failures)" -ge 2 ]] 2>/dev/null; then
        r_failed=1
        break
      fi

      sleep 2
      waited=$((waited + 2))
      # Say something periodically: several silent minutes is indistinguishable
      # from a hang, and this tool's audience has no reason to assume otherwise.
      if [[ $((waited % 30)) -eq 0 ]]; then
        echo "  still starting (${waited}s of up to ${deadline}s)..."
      fi
    done
    if [[ "$smoke_test_ok" -eq 1 ]]; then
      # The app is up. When nginx is in front, that is not yet the whole
      # story — the public URL goes through the proxy, and a proxy that is
      # stopped or misconfigured means visitors still see nothing. Check it
      # separately so the two failures can be told apart, and warn rather
      # than fail: the deployment itself did succeed.
      if [[ "$PROXY_ENABLED" -eq 1 ]]; then
        if ! curl -fsS -o /dev/null --max-time 10 "$(public_local_url)" 2>/dev/null; then
          echo >&2
          echo "Warning: the app is answering on $app_url, but the nginx proxy in front" >&2
          echo "of it is not serving it on port 80 — so it isn't reachable from a browser." >&2
          echo "Check the proxy with:" >&2
          echo "  sudo nginx -t && sudo systemctl status nginx" >&2
          echo "  sudo tail -20 /var/log/nginx/dashboard.error.log" >&2
          echo "  sudo ./deploy/bootstrap.sh --check" >&2
          echo >&2
        fi
      fi
      # The commands are spelled out rather than left to the docs: this tool
      # is aimed at researchers who may not use Docker day to day, and this
      # is the moment they need them.
      echo
      echo "  Deployed. '$CONTAINER_NAME' is running and responding."
      echo
      echo "    URL       $(public_url)"
      if [[ "$PROXY_ENABLED" -eq 1 ]]; then
        echo "    Serving   nginx on port 80  ->  app on $APP_BIND_ADDR:$APP_HOST_PORT"
      fi
      echo "    Health    ./deploy/manage.sh health"
      echo "    Logs      docker logs -f $CONTAINER_NAME"
      echo "    Restart   docker restart $CONTAINER_NAME"
      echo "    Stop      docker stop $CONTAINER_NAME"
      echo
      echo "  Re-run this script to deploy again after a code change; it replaces"
      echo "  the running container for you."
      echo
    elif [[ "$r_failed" -eq 1 ]]; then
      echo "Your app started, but R stopped with an error while loading it — every" >&2
      echo "attempt fails the same way, so there's no point waiting longer. The image" >&2
      echo "built fine; this is about what the app finds when it runs. R's error:" >&2
      echo >&2
      r_worker_error | sed 's/^/    /' >&2
      echo >&2
      echo "A missing file (\"cannot open file\", \"does not exist\") usually means the" >&2
      echo "data isn't where the code looks: see the data step, and the code check's" >&2
      echo "notes. The container is left running; stop it with:" >&2
      echo "  docker stop $CONTAINER_NAME" >&2
      exit 1
    else
      if [[ "$crashed" -eq 1 ]]; then
        echo "Warning: container '$CONTAINER_NAME' started, then crashed and was restarted" >&2
        echo "before it ever answered on $app_url." >&2
      else
        echo "Warning: container '$CONTAINER_NAME' started, but never responded on" >&2
        echo "$app_url within ${deadline}s." >&2
      fi
      echo "The app process died at startup rather than serving. The image" >&2
      echo "built fine, so this is a runtime failure — most often one of:" >&2
      echo "  * the data folder doesn't hold the files the app expects (check the logs" >&2
      echo "    below for a missing file; the folder you chose is mounted OVER the app's" >&2
      echo "    own, so an empty one hides whatever the project shipped)" >&2
      echo "  * a missing dependency, a wrong entry point, or a port mismatch" >&2
      echo "It is unlikely to be a bug in the app's own logic — frameworks render those" >&2
      echo "in the browser rather than exiting. Recent container logs:" >&2
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
    echo "Container '$CONTAINER_NAME' started; verify manually at http://<instance-fixed-ip>/"
    echo "(the app itself is published on $APP_BIND_ADDR:$APP_HOST_PORT)."
  fi
}
