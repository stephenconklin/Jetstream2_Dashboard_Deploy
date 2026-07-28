#!/usr/bin/env bash
# Prepare a Jetstream2 instance to be saved as the researcher-facing image.
#
#   sudo ./deploy/desktop/setup_image.sh
#
# Run once on a fresh instance, then create the image from it in Exosphere.
# Everything here is idempotent, so re-running to refresh an existing image
# is safe.
#
# What this buys, in rough order of importance:
#   * python3-tk — tkinter is NOT part of python3 on Ubuntu, and without it
#     the desktop icon does nothing visible at all.
#   * Pre-pulled base images — rocker/geospatial is several GB. Pulling it
#     during a researcher's first publish adds ten minutes of what looks
#     like a hang, for no reason.
#   * A desktop icon that actually launches, which on GNOME needs both the
#     executable bit and a "trusted" flag.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this with sudo: sudo $0" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-exouser}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
REPO_DIR="${REPO_DIR:-$TARGET_HOME/Jetstream2_Dashboard_Deploy}"
REPO_URL="${REPO_URL:-https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy.git}"
# Set REPO_BRANCH to test a branch before it reaches main — e.g.
#   sudo REPO_BRANCH=feature/researcher-gui ./deploy/desktop/setup_image.sh
REPO_BRANCH="${REPO_BRANCH:-main}"

echo "Preparing image for user '$TARGET_USER' (home: $TARGET_HOME)"
echo "  repo:   $REPO_URL"
echo "  branch: $REPO_BRANCH"
echo "  into:   $REPO_DIR"

# ---------------------------------------------------------------- packages
echo
echo "== Installing packages =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  python3 \
  python3-tk \
  policykit-1 \
  zenity \
  xdg-utils \
  git \
  rsync \
  openssh-client \
  unzip \
  curl \
  wget \
  less \
  nano \
  shellcheck

# ------------------------------------------------------------------- repo
echo
echo "== Deployment tooling =="
if [[ -d "$REPO_DIR/.git" ]]; then
  echo "Already present at $REPO_DIR — updating to $REPO_BRANCH."
  sudo -u "$TARGET_USER" git -C "$REPO_DIR" fetch origin "$REPO_BRANCH" || true
  # --ff-only on purpose: never silently merge or discard work in an
  # existing clone. If this fails, say so and carry on with what's there
  # rather than guessing what the user wanted.
  if ! sudo -u "$TARGET_USER" git -C "$REPO_DIR" checkout "$REPO_BRANCH" 2>/dev/null ||
     ! sudo -u "$TARGET_USER" git -C "$REPO_DIR" merge --ff-only "origin/$REPO_BRANCH" 2>/dev/null; then
    echo "  Could not fast-forward this clone to $REPO_BRANCH."
    echo "  Leaving it untouched. To reset it to exactly match GitHub:"
    echo "     cd $REPO_DIR && git fetch origin && git reset --hard origin/$REPO_BRANCH"
    echo "  (that discards local commits — check 'git log' first)"
  fi
else
  sudo -u "$TARGET_USER" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
fi
chown -R "$TARGET_USER":"$TARGET_USER" "$REPO_DIR"

# pkexec running a file inside a user-writable clone is not a privilege
# boundary here (the user already has sudo), but a root-owned copy is
# tidier and is what backend.py prefers.
# -D creates the parent directory. /usr/local/libexec does not exist by
# default on Ubuntu (24.04 included), and plain `install` fails rather than
# creating it — which, under `set -e`, aborts the whole setup here and
# leaves the desktop launcher and pre-pulled images undone.
install -D -m 0755 -o root -g root \
  "$REPO_DIR/deploy/lib/persist_mount.sh" \
  /usr/local/libexec/persist_mount.sh
echo "Installed /usr/local/libexec/persist_mount.sh"

# --------------------------------------------------------------- launcher
echo
echo "== Desktop launcher =="
DESKTOP_SRC="$REPO_DIR/deploy/desktop/dashboard-deploy.desktop"
# Point the launcher at wherever the repo actually landed.
TMP_DESKTOP="$(mktemp)"
sed -e "s#/home/exouser/Jetstream2_Dashboard_Deploy#$REPO_DIR#g" \
    "$DESKTOP_SRC" >"$TMP_DESKTOP"

# -D again: these directories normally exist, but a minimal image may not
# have them, and failing here would abort the rest of the setup.
install -D -m 0644 "$TMP_DESKTOP" /usr/share/applications/dashboard-deploy.desktop
USER_DESKTOP="$TARGET_HOME/Desktop"
mkdir -p "$USER_DESKTOP"
install -D -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" \
  "$TMP_DESKTOP" "$USER_DESKTOP/dashboard-deploy.desktop"
rm -f "$TMP_DESKTOP"

# GNOME renders a .desktop file on the Desktop as inert text unless it is
# both executable and explicitly trusted. MATE and XFCE need only the
# executable bit, so this is harmless there.
if command -v gio >/dev/null 2>&1; then
  sudo -u "$TARGET_USER" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$TARGET_USER")/bus" \
    gio set "$USER_DESKTOP/dashboard-deploy.desktop" \
    metadata::trusted true 2>/dev/null || \
    echo "  (could not mark trusted — harmless outside GNOME)"
fi
update-desktop-database /usr/share/applications 2>/dev/null || true

# ------------------------------------------------------------ base images
echo
echo "== Pre-pulling base images (several GB; this is the slow part) =="
for image in python:3.11-slim rocker/r-ver:4.4.1 rocker/geospatial:4.4.1; do
  echo "  $image"
  sudo -u "$TARGET_USER" docker pull -q "$image" || \
    echo "  (failed — a researcher's first publish will pull it instead)"
done

# ------------------------------------------------------------------- motd
echo
echo "== Login message for SSH users =="
mkdir -p /etc/update-motd.d
cat >/etc/update-motd.d/99-dashboard-deploy <<MOTD
#!/bin/sh
cat <<'BANNER'

  Dashboard deployment
  --------------------
  Graphical: open "Deploy My Dashboard" on the desktop.
  Terminal:  cd ~/Jetstream2_Dashboard_Deploy
             ./deploy/build_and_run.sh /path/to/your/project

  Docs: ~/Jetstream2_Dashboard_Deploy/docs/deployment.md

BANNER
MOTD
chmod +x /etc/update-motd.d/99-dashboard-deploy

echo
echo "Done. Before creating the image from this instance:"
echo "  1. Open the desktop icon once and confirm the window appears."
echo "  2. Publish a bundled example to warm Docker's cache:"
echo "       cd $REPO_DIR && ./deploy/build_and_run.sh examples/streamlit-hello-world"
echo "  3. Remove that test container:  docker rm -f dashboard-app"
echo "  4. Clear shell history if you'd rather it not ship with the image."
