#!/usr/bin/env bash
# How much room is left on the instance, and how to get some of it back.
#
# Sourced by bootstrap.sh (which warns about free space before provisioning)
# and manage.sh (which reports it, and can reclaim it on request). Not meant
# to be run directly.
#
# It lives in its own file for one reason: the "is this enough disk?" answer
# has to be the SAME answer in both places. bootstrap warns at provision time
# and the GUI's Manage tab shows the same figure days later, and a researcher
# who is told "9GB free is tight" by one and nothing by the other has been
# told nothing useful by either.
#
# Everything here is best-effort and never fails the caller. Disk reporting is
# diagnostic: a `df` that doesn't support these flags, or a Docker daemon
# that isn't answering, must not take down a provision or a health check.

# Below this, an R geospatial build is at real risk of running out partway.
# A rule of thumb, not a measurement: rocker/geospatial is ~4.5GB before the
# project's own layers (another ~6-8GB), and Docker's build cache grows with
# every rebuild on top of that. The Python frameworks need far less, which is
# why every use of this is a warning and never a refusal.
LOW_DISK_GB=15

# Every helper below ends with `|| true` on purpose. Callers run under
# `set -euo pipefail`, where an unguarded pipeline that fails inside a command
# substitution takes the whole script down — so `docker` not answering, or a
# BSD `df` rejecting a GNU flag, would abort a health check instead of
# reporting "unknown". Found by running these on a machine with the Docker
# daemon stopped, which is also exactly the state a researcher is in when
# something has gone wrong and they press Refresh.

# Free space on / in whole GB, or "" if df didn't support the flags (BSD df,
# i.e. macOS, where this repo is developed). An unparseable answer must read
# as "unknown", never as 0 — warning that a healthy instance has "0GB free"
# is alarming and wrong.
disk_free_gb() {
  df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9' || true
}

# "77% used, 9.1G free" — the one-line human form, used by bootstrap --check,
# manage.sh health, and the GUI alike.
disk_root_summary() {
  df -h / 2>/dev/null | awk 'NR==2{print $5" used, "$4" free"}' || true
}

# 1 when free space is under the threshold, 0 when it's above, and 0 when it
# could not be determined — same reasoning as disk_free_gb(): unknown is not
# a problem to report.
disk_is_low() {
  local free
  free="$(disk_free_gb)"
  [[ -n "$free" && "$free" -lt "$LOW_DISK_GB" ]] && echo 1 || echo 0
}

# One row of `docker system df`, by type ("Images", "Containers",
# "Local Volumes", "Build Cache"), as "<size>|<reclaimable>".
#
# Matched on the type column rather than by line number: the row order is not
# contractual, and `docker system df` gained rows over time.
_docker_df_row() {
  local want="$1"
  docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null \
    | awk -F'|' -v w="$want" '$1 == w {print $2"|"$3; exit}' || true
}

_df_size()        { local r; r="$(_docker_df_row "$1")"; echo "${r%%|*}"; }
_df_reclaimable() { local r; r="$(_docker_df_row "$1")"; echo "${r##*|}"; }

# Size of the dashboard's own image. Usually the single largest item on the
# instance, and the one a researcher is most likely to be surprised by.
disk_app_image_size() {
  docker images --format '{{.Size}}' "${1:-dashboard-app}:latest" 2>/dev/null | head -1 || true
}

# `key=value` lines for the GUI. Same contract as the other porcelain output
# in this repo: keys are stable, may be added to, never renamed; values are
# single-line and unquoted.
print_disk_porcelain() {
  local image_name="${1:-dashboard-app}"
  echo "root_free_gb=$(disk_free_gb)"
  echo "root_summary=$(disk_root_summary)"
  echo "low_disk=$(disk_is_low)"
  echo "low_disk_threshold_gb=$LOW_DISK_GB"
  echo "images_size=$(_df_size Images)"
  echo "images_reclaimable=$(_df_reclaimable Images)"
  echo "containers_size=$(_df_size Containers)"
  echo "cache_size=$(_df_size 'Build Cache')"
  echo "cache_reclaimable=$(_df_reclaimable 'Build Cache')"
  echo "app_image=$image_name"
  echo "app_image_size=$(disk_app_image_size "$image_name")"
}

# A blank figure means the Docker daemon didn't answer, which is a different
# thing from "0B" and must not be displayed as one.
_or_unknown() { echo "${1:-unknown}"; }

# The human report.
print_disk_human() {
  local image_name="${1:-dashboard-app}"
  echo "Disk space"
  echo "=========="
  echo "Root filesystem:  $(_or_unknown "$(disk_root_summary)")"
  echo
  echo "Docker is using:"
  printf '  %-14s %-10s %s\n' "Images" "$(_or_unknown "$(_df_size Images)")" \
    "($(_or_unknown "$(_df_reclaimable Images)") reclaimable)"
  printf '  %-14s %-10s %s\n' "Build cache" "$(_or_unknown "$(_df_size 'Build Cache')")" \
    "($(_or_unknown "$(_df_reclaimable 'Build Cache')") reclaimable)"
  printf '  %-14s %-10s\n' "Containers" "$(_or_unknown "$(_df_size Containers)")"
  local app_size
  app_size="$(disk_app_image_size "$image_name")"
  # An `[[ -n … ]] && printf` list here would be the last command in an
  # `set -e` script's call chain when the image doesn't exist, and would exit
  # the whole script with status 1 rather than skipping one line.
  if [[ -n "$app_size" ]]; then
    printf '  %-14s %-10s\n' "Your dashboard" "$app_size"
  fi
  echo
  if [[ "$(disk_is_low)" -eq 1 ]]; then
    echo "This is tight. An R geospatial build can want more than ${LOW_DISK_GB}GB,"
    echo "and running out partway through surfaces as a confusing compile error"
    echo "rather than as 'the disk is full'. Reclaim space with:"
    echo
    echo "  ./deploy/manage.sh cleanup"
  else
    echo "Free up the reclaimable space above at any time with:"
    echo
    echo "  ./deploy/manage.sh cleanup"
  fi
}

# Reclaim the space that is safe to reclaim, and report what that got back.
#
# Deliberately the SAFE subset, not `docker system prune -a`:
#
#   * `docker image prune -f` removes dangling (untagged) layers only — the
#     leftovers of previous builds. The current dashboard image is tagged and
#     is not touched, so the next publish still gets its layer cache.
#   * `docker builder prune -f` clears the build cache, which is the item that
#     grows without bound across rebuilds. The cost is a slower next build,
#     never a broken one.
#
# What it does NOT do, and why:
#
#   * `-a` variants would remove the dashboard image itself and the autoheal
#     sidecar's image, turning "free up space" into "the next publish is a
#     full rebuild, and autoheal has to be re-pulled". A researcher pressing a
#     button labelled "Free up space" is not asking for that.
#   * `docker container prune` would remove a *stopped* dashboard container —
#     which is exactly the state a researcher is in after pressing Stop, and
#     they reasonably expect to be able to start it again.
reclaim_disk_space() {
  local before after freed
  before="$(disk_free_gb)"

  docker image prune -f 2>/dev/null || true
  docker builder prune -f 2>/dev/null || true

  after="$(disk_free_gb)"
  freed=""
  if [[ -n "$before" && -n "$after" ]]; then
    freed="$((after - before))"
    # Never report a negative: something else on the instance can write during
    # the prune, and "freed -1GB" reads as a bug in this tool.
    [[ "$freed" -lt 0 ]] && freed=0
  fi
  echo "$before|$after|$freed"
}
