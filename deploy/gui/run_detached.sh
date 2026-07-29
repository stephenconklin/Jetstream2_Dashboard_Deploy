#!/usr/bin/env bash
# Run a command detached from the GUI, logging to a file and recording its
# exit code where the GUI can find it afterward.
#
#   run_detached.sh <logfile> <exitfile> <command> [args...]
#
# Why this exists: researchers reach this tool through a remote desktop
# session. If the GUI owned the build as a child process, a dropped
# Guacamole connection — or the researcher closing the window — would kill
# a build that can run 25+ minutes for an R Shiny project. Here the GUI only
# *tails* the log, so it can disappear and reattach later without disturbing
# the build.
#
# The exit code goes to a sentinel file rather than being reported through a
# pipe, for the same reason: the GUI may not be running when the build ends.
# Absence of <exitfile> means "still running", which is also how the GUI
# decides whether to reattach at startup.
set -uo pipefail   # deliberately NOT -e: we must record the exit code below

if [[ $# -lt 3 ]]; then
  echo "usage: run_detached.sh <logfile> <exitfile> <command> [args...]" >&2
  exit 2
fi

logfile="$1"; shift
exitfile="$1"; shift

mkdir -p "$(dirname "$logfile")" "$(dirname "$exitfile")"
# Clear any sentinel from a previous run before starting, so a stale exit
# code can never be read as this run's result.
rm -f "$exitfile"

# Record a status even when cancelled. Without this, a SIGTERM'd wrapper
# exits without writing the sentinel and anything waiting on that file waits
# forever. The GUI has its own fallback for a hard SIGKILL, but this covers
# the ordinary cancel path and reports the conventional 128+signal value.
# Invoked only from the trap handlers below, which the linter can't see
# through since they're strings evaluated at signal time.
# shellcheck disable=SC2329
on_signal() {
  local sig="$1"
  printf '%s\n' "$((128 + sig))" >"$exitfile"
  exit "$((128 + sig))"
}
trap 'on_signal 15' TERM
trap 'on_signal 2' INT

"$@" >"$logfile" 2>&1
rc=$?

# Written last, and only ever written once — the GUI treats this file
# appearing as "the build is finished", so it must not exist early.
printf '%s\n' "$rc" >"$exitfile"
exit "$rc"
