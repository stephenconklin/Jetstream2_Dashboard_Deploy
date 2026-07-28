"""How researchers get files from wherever they are onto this instance.

The GUI implements none of these transfers. It explains each one, opens the
right tool, and — the part that actually matters — verifies afterwards that
the files arrived where the deployment will look for them.

Four routes are offered because researchers arrive with very different
setups: some live in GitHub, some have 200 GB on an institutional store,
some have a folder on a laptop and have never opened a terminal. Picking
one route for everyone would exclude a lot of people.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

GLOBUS_URL = "https://app.globus.org/file-manager"

CLOUD_SERVICES = [
    ("Google Drive", "https://drive.google.com"),
    ("Box", "https://app.box.com"),
    ("Dropbox", "https://www.dropbox.com/home"),
]


@dataclass
class Route:
    key: str
    title: str
    blurb: str
    best_for: str
    # Buttons to render: (label, url) opened with xdg-open.
    links: list[tuple[str, str]] = field(default_factory=list)
    # A command for the researcher to run on their OWN machine, if any.
    command: str = ""
    # A folder on this instance to offer to open in the file manager.
    folder: str = ""


def drag_and_drop_landing() -> str:
    """Where the remote desktop drops transferred files.

    Confirmed on the Jetstream2 image: files sent through the desktop
    session land in the user's home directory.
    """
    return str(Path.home())


def rsync_command(public_ip: str, username: str, destination: str) -> str:
    """The command to run on the researcher's own laptop.

    -a preserves structure, -v shows progress, -P makes an interrupted
    transfer resumable, which matters for anything large enough that a
    dropped wifi connection is likely.

    The trailing slash on the source is load-bearing: with it, the
    *contents* of mydata are copied into the destination; without it, a
    mydata folder is created inside it. Getting this wrong is the single
    most common rsync mistake, so the example includes it deliberately.
    """
    host = public_ip if public_ip and not public_ip.startswith("<") else "YOUR-INSTANCE-IP"
    return f"rsync -avP ~/mydata/ {username}@{host}:{destination}/"


def scp_command(public_ip: str, username: str, destination: str) -> str:
    host = public_ip if public_ip and not public_ip.startswith("<") else "YOUR-INSTANCE-IP"
    return f"scp -r ~/mydata/* {username}@{host}:{destination}/"


def build_routes(public_ip: str, username: str, destination: str) -> list[Route]:
    """The four routes, with real values filled in where possible."""
    dest = destination or "/media/volume/YOUR-VOLUME"
    return [
        Route(
            key="globus",
            title="Globus  (best for large datasets)",
            blurb=(
                "Globus transfers in the background, resumes automatically if "
                "the connection drops, and is built for research data. Log in "
                "with your institution, then move files to this instance's "
                "endpoint. Nothing to install on your laptop."),
            best_for="Tens of GB and up, or anything you'd hate to restart.",
            links=[("Open Globus", GLOBUS_URL)],
            folder=dest,
        ),
        Route(
            key="cloud",
            title="Download from cloud storage",
            blurb=(
                "If your data is already in Google Drive, Box or Dropbox, open "
                "it in this desktop's browser and download it straight to the "
                "instance. Nothing passes through your laptop."),
            best_for="Small to medium files you already keep in the cloud.",
            links=list(CLOUD_SERVICES),
            folder=dest,
        ),
        Route(
            key="rsync",
            title="Copy from my own computer  (scp / rsync)",
            blurb=(
                "Run this on YOUR computer — not here — replacing ~/mydata "
                "with the folder you want to send. It will ask for your "
                "instance password or use your SSH key."),
            best_for="A folder on your laptop, when you're comfortable with a terminal.",
            command=rsync_command(public_ip, username, dest),
            folder=dest,
        ),
        Route(
            key="dragdrop",
            title="Drag and drop into this desktop",
            blurb=(
                "Drag files onto this remote desktop session and they arrive "
                "in your home folder here. Simplest option, but it is slow and "
                "unreliable for anything large — prefer one of the routes "
                "above beyond about a gigabyte. Move them onto your data "
                "volume afterwards."),
            best_for="A few small files.",
            folder=drag_and_drop_landing(),
        ),
    ]


def summarise_folder(path: str, max_entries: int = 8) -> str:
    """What's actually in a folder, so arrival can be confirmed.

    This is the real deliverable of the data step: every route above is
    just instructions, but this answers "did it work?".
    """
    p = Path(path)
    if not p.is_dir():
        return f"{path} doesn't exist yet."

    total = 0
    count = 0
    names: list[str] = []
    try:
        for entry in p.rglob("*"):
            if entry.is_file():
                count += 1
                try:
                    total += entry.stat().st_size
                except OSError:
                    pass
                if len(names) < max_entries:
                    names.append(str(entry.relative_to(p)))
    except OSError as exc:
        return f"Could not read {path}: {exc}"

    if count == 0:
        return f"{path} is empty — nothing has arrived yet."

    from volumes import _human  # local import keeps this module dependency-light
    listing = "\n".join(f"    {n}" for n in names)
    more = f"\n    …and {count - len(names)} more" if count > len(names) else ""
    return f"{count} files, {_human(total)} in {path}:\n{listing}{more}"
