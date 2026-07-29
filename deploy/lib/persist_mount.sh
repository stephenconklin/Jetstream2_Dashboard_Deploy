#!/usr/bin/env bash
# Make a mounted storage volume come back automatically after a reboot, by
# adding it to /etc/fstab.
#
#   sudo persist_mount.sh <uuid> <mountpoint> <fstype>
#   persist_mount.sh --check <uuid> <mountpoint>    (no root needed)
#
# Run as root, normally via pkexec from the GUI.
#
# This is a script rather than a few calls from the GUI for one reason:
# a bad /etc/fstab can leave an instance unbootable, dropped to an emergency
# console that a remote-desktop-only researcher has no way to reach. That
# makes atomic rollback mandatory, and rollback is trivial to express here
# and easy to get wrong spread across GUI callbacks.
#
# Two safety properties are non-negotiable:
#   * `nofail` — so a detached or renamed volume never blocks boot.
#   * validate then roll back — the new fstab is verified with
#     `findmnt --verify` and `mount -a`, and restored from backup if either
#     complains, so a bad entry never survives this script.
set -euo pipefail

usage() {
  echo "usage: persist_mount.sh <uuid> <mountpoint> <fstype>" >&2
  echo "       persist_mount.sh --check <uuid> <mountpoint>" >&2
  exit 2
}

# Overridable only so the idempotency and validation logic can be exercised
# against a fixture file during development. Nothing sets it in normal use,
# and overriding it doesn't grant anything: the write path already requires
# root, and anyone who is root can edit /etc/fstab directly anyway.
FSTAB="${PERSIST_MOUNT_FSTAB:-/etc/fstab}"

# Mount options, in full:
#   defaults                     - rw, suid, dev, exec, auto, nouser, async
#   nofail                       - boot even if the volume is missing
#   x-systemd.device-timeout=10s - and don't spend 90s waiting for it first;
#                                  nofail alone still lets systemd block on
#                                  the default device timeout at boot
MOUNT_OPTS="defaults,nofail,x-systemd.device-timeout=10s"

# Is this UUID or mountpoint already in fstab? Printing what's there and
# succeeding matters: a researcher who isn't sure whether it worked will
# press the button again, and appending a second entry for the same volume
# must not be the result.
existing_entry() {
  local uuid="$1" mountpoint="$2"
  [[ -r "$FSTAB" ]] || return 1
  awk -v uuid="UUID=$uuid" -v mp="$mountpoint" '
    /^[[:space:]]*#/ { next }
    NF >= 2 && ($1 == uuid || $2 == mp) { print; found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$FSTAB"
}

# --check runs unprivileged so the GUI can report the current state without
# provoking a password prompt for a question.
if [[ "${1:-}" == "--check" ]]; then
  [[ $# -eq 3 ]] || usage
  if existing_entry "$2" "$3"; then
    echo "status=persisted"
  else
    echo "status=not-persisted"
  fi
  exit 0
fi

[[ $# -eq 3 ]] || usage
UUID="$1"
MOUNTPOINT="$2"
FSTYPE="$3"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This must run as root. The GUI normally does that for you; to do it" >&2
  echo "by hand:  sudo $0 $UUID $MOUNTPOINT $FSTYPE" >&2
  exit 1
fi

# Validate before touching anything. A mountpoint containing whitespace
# cannot be expressed in fstab's field format, and a UUID that doesn't
# resolve would produce an entry for a device that never appears.
[[ "$MOUNTPOINT" == /* ]] || { echo "Mount point must be an absolute path." >&2; exit 1; }
if [[ "$MOUNTPOINT" =~ [[:space:]] ]]; then
  echo "Mount point contains whitespace, which /etc/fstab cannot represent." >&2
  exit 1
fi
if [[ ! "$UUID" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "'$UUID' doesn't look like a filesystem UUID." >&2
  exit 1
fi
if ! blkid -U "$UUID" >/dev/null 2>&1; then
  echo "No filesystem with UUID $UUID is attached to this machine." >&2
  echo "Attach the volume in Exosphere first, then try again." >&2
  exit 1
fi
[[ -n "$FSTYPE" ]] || { echo "Filesystem type is required." >&2; exit 1; }

if existing_entry "$UUID" "$MOUNTPOINT" >/dev/null; then
  echo "Already set up to mount automatically — nothing to change:"
  existing_entry "$UUID" "$MOUNTPOINT"
  exit 0
fi

BACKUP="${FSTAB}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$FSTAB" "$BACKUP"
echo "Backed up $FSTAB to $BACKUP"

mkdir -p "$MOUNTPOINT"

{
  echo ""
  echo "# Added by Jetstream2_Dashboard_Deploy on $(date -Is)"
  printf '%s\t%s\t%s\t%s\t0\t2\n' "UUID=$UUID" "$MOUNTPOINT" "$FSTYPE" "$MOUNT_OPTS"
} >>"$FSTAB"
echo "Added:"
printf '  UUID=%s\t%s\t%s\t%s\t0\t2\n' "$UUID" "$MOUNTPOINT" "$FSTYPE" "$MOUNT_OPTS"

# Restore the previous file and undo systemd's view of it. Called on any
# validation failure below.
rollback() {
  echo "Reverting $FSTAB from $BACKUP" >&2
  cp -a "$BACKUP" "$FSTAB"
  systemctl daemon-reload 2>/dev/null || true
}

if ! findmnt --verify --verbose; then
  rollback
  echo "The new line didn't pass validation, so nothing was changed." >&2
  exit 1
fi

# systemd generates mount units from fstab at boot and caches them. Without
# a reload, `mount -a` can succeed here while the entry still does nothing
# at the next boot — the classic "it worked when I tested it" failure.
systemctl daemon-reload 2>/dev/null || true

if ! mount -a; then
  rollback
  echo "Mounting with the new entry failed, so it was removed." >&2
  exit 1
fi

echo
echo "Done. $MOUNTPOINT will be mounted automatically after a reboot."
echo "Because 'nofail' is set, the instance will still boot normally even if"
echo "this volume is ever detached."
