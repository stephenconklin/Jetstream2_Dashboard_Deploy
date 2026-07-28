#!/usr/bin/env bash
# Lint every shell script in this repo with shellcheck.
#
#   ./deploy/lint.sh
#
# This repo has no CI and no test suite — the "product" is shell scripts and
# Dockerfiles — so this is the closest thing to an automated check. Run it
# before committing, or install the pre-commit hook to have it run for you:
#
#   git config core.hooksPath .githooks
#
# -x follows `source` directives, so issues inside lib/*.sh are reported in
# the context of the caller that sets their variables. The libs are also
# listed explicitly so they're checked on their own terms too.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found. Install it with:" >&2
  echo "  macOS:  brew install shellcheck" >&2
  echo "  Ubuntu: sudo apt-get install shellcheck" >&2
  exit 1
fi

# Every tracked shell script. apt_retry.sh is POSIX sh (it runs inside the
# images, where bash isn't guaranteed); its own shebang tells shellcheck
# which dialect to check it against.
FILES=(
  deploy/build_and_run.sh
  deploy/manage.sh
  deploy/lib/common.sh
  deploy/lib/detect_framework.sh
  deploy/lib/persist_mount.sh
  deploy/docker/apt_retry.sh
  deploy/lint.sh
  deploy/gui/launch_gui.sh
  deploy/gui/run_detached.sh
)

echo "shellcheck: ${#FILES[@]} files"
shellcheck -x "${FILES[@]}"
echo "shellcheck: clean"

# The Python GUI has no test suite either; a syntax check is the closest
# equivalent to what shellcheck gives the shell, and catches the typo class
# of error before it reaches an instance where there's no terminal to show
# a traceback.
if command -v python3 >/dev/null 2>&1; then
  echo "python: compiling deploy/gui"
  python3 -m compileall -q deploy/gui
  echo "python: clean"
fi
