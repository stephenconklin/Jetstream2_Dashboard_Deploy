#!/usr/bin/env bash
# Launcher for the deployment GUI, and the place where "nothing happened
# when I double-clicked the icon" gets turned into an explanation.
#
# A .desktop launcher runs with no terminal attached, so a Python traceback
# goes nowhere. The two most likely failures on a fresh image — tkinter not
# installed (python3-tk is a separate apt package on Ubuntu, NOT part of
# python3) and Docker not usable — are checked here and reported in a
# graphical dialog before Python is ever started.
set -uo pipefail

GUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Show a message graphically if we can, and always echo it for anyone who
# did launch from a terminal.
fail() {
  local title="$1" body="$2"
  echo "$title: $body" >&2
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --no-wrap --title="$title" --text="$body" 2>/dev/null
  elif command -v xmessage >/dev/null 2>&1; then
    xmessage -center "$title

$body" 2>/dev/null
  fi
  exit 1
}

if ! command -v python3 >/dev/null 2>&1; then
  fail "Cannot start" "Python 3 is not installed on this machine.

Install it with:  sudo apt-get install -y python3 python3-tk"
fi

if ! python3 -c "import tkinter" >/dev/null 2>&1; then
  fail "Cannot start" "The graphical toolkit (tkinter) is missing.

Install it with:  sudo apt-get install -y python3-tk

then open this again."
fi

if ! command -v docker >/dev/null 2>&1; then
  fail "Docker not found" "Docker is required to build and run dashboards, but isn't installed.

On a Jetstream2 image it should already be present — you may be on the wrong instance."
fi

if ! docker info >/dev/null 2>&1; then
  fail "Docker is not available" "Docker is installed but not responding.

Usually this means either the service isn't running:
    sudo systemctl start docker

or your user isn't in the 'docker' group:
    sudo usermod -aG docker \$USER
    (then log out and back in)"
fi

# Make snap-packaged apps visible to xdg-open. Ubuntu 24.04 ships Firefox as
# a snap, whose desktop entry lives in /var/lib/snapd/desktop; a login shell
# adds that to XDG_DATA_DIRS (/etc/profile.d/apps-bin-path.sh), but the
# Jetstream2 remote desktop session doesn't run one. Without it the desktop
# has no handler for web links, and "Open dashboard" opened the page's
# address in a text editor instead of a browser.
SNAP_APPS=/var/lib/snapd/desktop
if [[ -d "$SNAP_APPS" && ":${XDG_DATA_DIRS:-}:" != *":$SNAP_APPS:"* ]]; then
  export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:$SNAP_APPS"
fi

# PYTHONPATH so `python3 -m gui` resolves the package regardless of cwd.
export PYTHONPATH="$GUI_DIR/..:${PYTHONPATH:-}"
exec python3 "$GUI_DIR/__main__.py" "$@"
