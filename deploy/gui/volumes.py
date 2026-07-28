"""Working out where a researcher's data can live on this instance.

Deliberately pure: every function here takes the *text* that ``lsblk`` and
``findmnt`` produced and returns structures. Running those commands is
backend.py's job (it owns all subprocess use), and keeping the parsing
separate means it can be tested on a development machine that has neither
command — which macOS does not.

The JSON here is the one place structured data is handed to us rather than
hand-rolled, so it's parsed properly rather than scraped.
"""

from __future__ import annotations

import json
import shutil
from dataclasses import dataclass
from pathlib import Path

# Exosphere mounts attached volumes under here, so anything below this path
# is almost certainly the researcher's data volume rather than system disk.
VOLUME_ROOT = "/media/volume"


@dataclass
class Location:
    """Somewhere data could be kept, with enough context to choose well."""

    path: str
    kind: str          # volume | unmounted | unformatted | home | other
    size_bytes: int = 0
    avail_bytes: int = 0
    uuid: str = ""
    device: str = ""
    fstype: str = ""

    @property
    def is_usable(self) -> bool:
        """Whether it can be selected right now without further setup."""
        return self.kind in ("volume", "home", "other")

    @property
    def on_root_disk(self) -> bool:
        return self.kind == "home"

    def describe(self) -> str:
        """One line for a list widget."""
        if self.kind == "unformatted":
            return (f"{self.device} — attached but not formatted "
                    f"({_human(self.size_bytes)}) — set it up in Exosphere first")
        if self.kind == "unmounted":
            return (f"{self.device} — attached but not mounted "
                    f"({_human(self.size_bytes)}, {self.fstype})")
        if self.kind == "home":
            return (f"{self.path} — home folder on the system disk "
                    f"({_human(self.avail_bytes)} free) — limited space, "
                    f"lost if the instance is deleted")
        return (f"{self.path} — storage volume "
                f"({_human(self.avail_bytes)} free of {_human(self.size_bytes)})")


def _human(n: int) -> str:
    if n <= 0:
        return "unknown size"
    step = 1024.0
    value = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < step or unit == "TB":
            return f"{value:.0f} {unit}" if unit in ("B", "KB") else f"{value:.1f} {unit}"
        value /= step
    return f"{value:.1f} TB"


def _flatten(nodes: list[dict]) -> list[dict]:
    """lsblk nests partitions under disks; we want every node."""
    out: list[dict] = []
    for node in nodes:
        out.append(node)
        out.extend(_flatten(node.get("children", []) or []))
    return out


def parse_findmnt(text: str) -> dict[str, dict]:
    """Map mount point -> usage info, from ``findmnt -J -b``."""
    try:
        data = json.loads(text) if text.strip() else {}
    except json.JSONDecodeError:
        return {}
    result: dict[str, dict] = {}
    for row in data.get("filesystems", []) or []:
        for node in _flatten([row]):
            target = node.get("target")
            if target:
                result[target] = node
    return result


def parse_lsblk(text: str) -> list[dict]:
    """Flat list of block devices, from ``lsblk -J -b``."""
    try:
        data = json.loads(text) if text.strip() else {}
    except json.JSONDecodeError:
        return []
    return _flatten(data.get("blockdevices", []) or [])


def _as_int(value) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def discover_locations(lsblk_text: str,
                       findmnt_text: str,
                       home: str | None = None) -> list[Location]:
    """Rank the places data could live, best first.

    Ordering is deliberate: mounted storage volumes come first because that
    is nearly always the right answer, and the home directory last because
    it's on the instance's root disk — fine for a quick test, wrong for a
    real dataset.
    """
    home_path = home or str(Path.home())
    devices = parse_lsblk(lsblk_text)
    mounts = parse_findmnt(findmnt_text)

    volumes: list[Location] = []
    unmounted: list[Location] = []
    unformatted: list[Location] = []

    for dev in devices:
        dev_type = dev.get("type", "")
        if dev_type not in ("disk", "part", "lvm"):
            continue
        name = dev.get("name", "")
        device = f"/dev/{name}" if name and not name.startswith("/") else name
        mountpoint = dev.get("mountpoint") or dev.get("mountpoints", [None])[0]
        fstype = dev.get("fstype") or ""
        size = _as_int(dev.get("size"))
        uuid = dev.get("uuid") or ""

        if mountpoint:
            # Only offer mounts that look like attached storage. The root
            # filesystem and system mounts are not places to put data.
            if not mountpoint.startswith(VOLUME_ROOT):
                continue
            usage = mounts.get(mountpoint, {})
            volumes.append(Location(
                path=mountpoint, kind="volume",
                size_bytes=_as_int(usage.get("size")) or size,
                avail_bytes=_as_int(usage.get("avail")),
                uuid=uuid, device=device, fstype=fstype))
        elif fstype:
            # Has a filesystem but isn't mounted. Skip partitions of the
            # root disk, which are usually swap/EFI rather than data.
            if dev_type == "part" and name.startswith(("sda", "vda", "nvme0")):
                continue
            unmounted.append(Location(
                path="", kind="unmounted", size_bytes=size,
                uuid=uuid, device=device, fstype=fstype))
        elif dev_type == "disk" and size > 0 and not dev.get("children"):
            if name.startswith(("sda", "vda", "nvme0")):
                continue
            unformatted.append(Location(
                path="", kind="unformatted", size_bytes=size, device=device))

    home_loc = Location(path=home_path, kind="home")
    try:
        usage = shutil.disk_usage(home_path)
        home_loc.size_bytes = usage.total
        home_loc.avail_bytes = usage.free
    except OSError:
        pass

    return volumes + unmounted + unformatted + [home_loc]


def mount_mapping(host_path: str, container_target: str) -> str:
    """The sentence researchers most often need and least often see.

    Getting the relationship between a host path and where it appears
    inside the container wrong is the single most common data mistake with
    this tool, so the GUI shows it explicitly.
    """
    return f"{host_path}  →  {container_target}   (inside your app)"
