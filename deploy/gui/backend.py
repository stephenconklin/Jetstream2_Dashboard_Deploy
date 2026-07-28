"""The only module that builds shell commands.

This repo's design principle is that ``build_and_run.sh`` is the single
source of truth for how a deployment works. The GUI is a front end, not a
reimplementation. Keeping every ``subprocess`` invocation in this one file
makes that rule checkable by reading ~200 lines: if deployment logic ever
starts leaking into Python, it shows up here first.

Rules for anything added to this module:

* Never reimplement a decision the shell already makes. Ports, mount
  targets, framework detection and base-image selection all come back from
  ``--dry-run --porcelain``; do not hardcode them.
* Never parse human-readable output to decide control flow. Use exit codes,
  and the porcelain key/value stream.
* On failure, surface the script's own stderr verbatim. Its error messages
  are written for researchers and are better than anything reconstructed
  here, and this way they stay correct as the shell evolves.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

# Ubuntu 22.04 ships Python 3.10; nothing here may require newer syntax.

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
BUILD_AND_RUN = REPO_ROOT / "deploy" / "build_and_run.sh"
RUN_DETACHED = REPO_ROOT / "deploy" / "gui" / "run_detached.sh"
MANAGE = REPO_ROOT / "deploy" / "manage.sh"

LOG_DIR = Path.home() / "dashboard-deploy-logs"
STATE_DIR = Path.home() / ".local" / "state" / "dashboard-deploy"

# One instance = one app, so the container name is fixed rather than exposed
# in the UI. Matches build_and_run.sh's own default.
CONTAINER_NAME = "dashboard-app"


class BackendError(RuntimeError):
    """A shell command failed. ``stderr`` carries its verbatim output."""

    def __init__(self, message: str, stderr: str = "", returncode: int = 1) -> None:
        super().__init__(message)
        self.stderr = stderr.strip()
        self.returncode = returncode

    def full_text(self) -> str:
        """Message plus the script's own words, for display in a dialog."""
        if self.stderr:
            return f"{self}\n\n{self.stderr}"
        return str(self)


@dataclass
class ProjectInfo:
    """Parsed ``--dry-run --porcelain`` output.

    Field names mirror the porcelain keys exactly. Unknown keys are kept in
    ``extra`` so a newer shell adding a key doesn't break an older GUI.
    """

    project_dir: str = ""
    framework: str = ""
    entry_file: str = ""
    entry_point_desc: str = ""
    base_image: str = ""
    deps_state: str = ""
    uses_geospatial: bool = False
    has_data_dir: bool = False
    has_apt_txt: bool = False
    container_port: str = ""
    data_mount_target: str = ""
    extra: dict[str, str] = field(default_factory=dict)

    @property
    def needs_data_dir(self) -> bool:
        """True when a deploy cannot proceed without the user picking a path.

        ``resolve_data_dir()`` in common.sh prompts on a TTY, but the GUI's
        subprocess has none, so it hard-fails instead. That guard is what
        makes this safe to rely on: the failure is clean and catchable
        rather than a hang.
        """
        return self.has_data_dir

    @property
    def deps_ok(self) -> bool:
        return self.deps_state != "missing"

    @property
    def expect_slow_build(self) -> bool:
        """R projects without a lockfile install their deps twice."""
        return self.deps_state == "will-generate-renv"


_TRUTHY = {"1", "true", "yes"}


def _parse_porcelain(text: str) -> ProjectInfo:
    info = ProjectInfo()
    known = {f.name for f in info.__dataclass_fields__.values()} - {"extra"}
    bools = {"uses_geospatial", "has_data_dir", "has_apt_txt"}
    for line in text.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key in known:
            setattr(info, key, value.lower() in _TRUTHY if key in bools else value)
        else:
            info.extra[key] = value
    return info


def _run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess[str]:
    """Run a short, synchronous command with stdout and stderr kept apart.

    Separate streams matter for porcelain: warnings (the geospatial base
    image note, the CRAN drift warning) go to stderr, and merging them would
    corrupt the key/value stream on stdout.
    """
    return subprocess.run(
        cmd,
        cwd=str(REPO_ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        text=True,
        timeout=timeout,
        check=False,
    )


def inspect_project(project_dir: str | os.PathLike[str],
                    framework: str = "",
                    container_port: str = "") -> ProjectInfo:
    """Ask the shell what it would do with this project. No side effects.

    ``--dry-run`` is guaranteed read-only: it never starts a container,
    never writes into the project directory, and reports a missing
    dependency file rather than failing on it.
    """
    env_prefix: list[str] = []
    if framework:
        env_prefix += [f"FRAMEWORK={framework}"]
    if container_port:
        env_prefix += [f"CONTAINER_PORT={container_port}"]

    cmd = ["env", *env_prefix, str(BUILD_AND_RUN),
           "--dry-run", "--porcelain", str(project_dir)]
    proc = _run(cmd)
    if proc.returncode != 0:
        raise BackendError(
            "This doesn't look like a supported dashboard project.",
            proc.stderr, proc.returncode)

    info = _parse_porcelain(proc.stdout)
    if not info.framework:
        raise BackendError(
            "Could not determine the project's framework.", proc.stderr)
    return info


@dataclass
class RunHandle:
    """A detached build: where its log is, and how to tell if it's done."""

    pid: int
    log_path: Path
    exit_path: Path

    def reap(self) -> None:
        """Clear the zombie left behind if this run was our own child.

        A killed process stays in the process table until its parent waits
        for it, and ``os.kill(pid, 0)`` succeeds on a zombie. Without this,
        a cancelled build looks alive forever and anything polling
        ``process_alive()`` never finishes. Raises nothing: a reattached run
        from an earlier GUI session isn't our child at all, which is fine.
        """
        try:
            os.waitpid(self.pid, os.WNOHANG)
        except (ChildProcessError, OSError):
            pass

    def process_alive(self) -> bool:
        """Whether the wrapper process still exists, ignoring the sentinel.

        Kept separate from is_running() because the two can disagree: a
        SIGKILLed wrapper is dead but never got to record an exit code, and
        callers waiting for that file need to notice.
        """
        self.reap()
        try:
            os.kill(self.pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def is_running(self) -> bool:
        if self.exit_path.exists():
            return False
        return self.process_alive()

    def exit_code(self) -> int | None:
        """Exit status, or None while still running."""
        try:
            return int(self.exit_path.read_text().strip())
        except (FileNotFoundError, ValueError):
            return None


def _write_current(handle: RunHandle) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / "current.pid").write_text(str(handle.pid))
    (STATE_DIR / "current.log").write_text(str(handle.log_path))
    (STATE_DIR / "current.exit").write_text(str(handle.exit_path))


def find_running_build() -> RunHandle | None:
    """Reattach to a build still running from a previous GUI session.

    The whole point of the detached model: a dropped remote-desktop session
    must not destroy a long build.
    """
    try:
        pid = int((STATE_DIR / "current.pid").read_text().strip())
        log_path = Path((STATE_DIR / "current.log").read_text().strip())
        exit_path = Path((STATE_DIR / "current.exit").read_text().strip())
    except (FileNotFoundError, ValueError):
        return None
    handle = RunHandle(pid, log_path, exit_path)
    return handle if handle.is_running() else None


def start_deploy(project_dir: str | os.PathLike[str],
                 data_dir: str = "",
                 framework: str = "",
                 container_port: str = "") -> RunHandle:
    """Launch a deploy detached from this process, returning its log handle.

    ``data_dir`` must be supplied whenever the project has a ``data/``
    directory: the GUI has no TTY, so common.sh's interactive prompt cannot
    run and the script exits with an explanatory message instead.
    """
    stamp = time.strftime("%Y%m%d-%H%M%S")
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / f"deploy-{stamp}.log"
    exit_path = STATE_DIR / f"deploy-{stamp}.exit"

    env = os.environ.copy()
    # Plain progress keeps the log free of ANSI cursor movement, so it stays
    # readable in a Tk text widget and greppable when a researcher sends it
    # to us for help.
    env["BUILDKIT_PROGRESS"] = "plain"
    if data_dir:
        env["DATA_DIR"] = str(data_dir)
    if framework:
        env["FRAMEWORK"] = framework
    if container_port:
        env["CONTAINER_PORT"] = container_port

    cmd = [str(RUN_DETACHED), str(log_path), str(exit_path),
           str(BUILD_AND_RUN), str(project_dir)]

    # start_new_session puts the build in its own process group, so a cancel
    # can signal the whole tree (build_and_run.sh *and* the docker client)
    # rather than orphaning children.
    proc = subprocess.Popen(
        cmd,
        cwd=str(REPO_ROOT),
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    handle = RunHandle(proc.pid, log_path, exit_path)
    _write_current(handle)
    return handle


def cancel(handle: RunHandle, grace_seconds: float = 5.0) -> None:
    """Stop a running build, giving it a chance to clean up first.

    SIGTERM reaches common.sh's EXIT/INT/TERM trap, which removes the temp
    build context — potentially several GB. SIGKILL would leave it behind.
    """
    try:
        pgid = os.getpgid(handle.pid)
    except ProcessLookupError:
        return

    os.killpg(pgid, 15)  # SIGTERM
    deadline = time.time() + grace_seconds
    while time.time() < deadline:
        if not handle.is_running():
            handle.reap()
            return
        time.sleep(0.2)

    # Still going. `docker build` can outlive a SIGTERM, and bash defers a
    # trap until the foreground command it's waiting on returns, so the
    # wrapper may not have had the chance to record anything yet.
    try:
        os.killpg(pgid, 9)  # SIGKILL
    except ProcessLookupError:
        pass
    handle.reap()


def container_status() -> dict[str, str]:
    """Current app state, via manage.sh. Empty dict if it isn't available."""
    if not MANAGE.exists():
        return {}
    proc = _run([str(MANAGE), "status", "--porcelain"], timeout=30)
    if proc.returncode != 0:
        return {}
    out: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        key, _, value = line.strip().partition("=")
        if key:
            out[key] = value
    return out


def manage(action: str) -> str:
    """Run a manage.sh verb (restart/stop/logs). Returns its stdout."""
    proc = _run([str(MANAGE), action], timeout=120)
    if proc.returncode != 0:
        raise BackendError(f"Could not {action} the app.",
                           proc.stderr or proc.stdout, proc.returncode)
    return proc.stdout


PROJECTS_DIR = Path.home() / "dashboard-projects"


def clone_repo(url: str, name: str = "") -> Path:
    """Clone a Git repository into ~/dashboard-projects/ and return its path.

    Refuses to overwrite an existing checkout rather than silently pulling
    or deleting — a researcher who clones twice usually means the second
    one to be a fresh copy, and quietly discarding local edits to the first
    would be the worst possible interpretation.
    """
    url = url.strip()
    if not url:
        raise BackendError("Enter the address of your repository first.")

    folder = name.strip() or url.rstrip("/").split("/")[-1]
    if folder.endswith(".git"):
        folder = folder[: -len(".git")]
    if not folder:
        raise BackendError("Could not work out a folder name from that address.")

    PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
    dest = PROJECTS_DIR / folder
    if dest.exists():
        raise BackendError(
            f"There's already a folder at {dest}.\n\n"
            "Rename or remove it first, or use 'Browse' to deploy what's "
            "already there.")

    proc = _run(["git", "clone", "--depth", "1", url, str(dest)], timeout=900)
    if proc.returncode != 0:
        raise BackendError(
            "Could not download that repository.", proc.stderr, proc.returncode)
    return dest


def extract_zip(zip_path: str | os.PathLike[str], name: str = "") -> Path:
    """Unpack a .zip into ~/dashboard-projects/ and return the project root.

    If the archive contains a single top-level folder — which is what
    GitHub's "Download ZIP" and most hand-made archives produce — that
    folder becomes the project root, so the researcher doesn't end up
    pointing the deploy at a wrapper directory containing nothing but
    another directory.
    """
    import zipfile

    src = Path(zip_path)
    if not src.is_file():
        raise BackendError(f"{src} is not a file.")

    folder = name.strip() or src.stem
    PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
    dest = PROJECTS_DIR / folder
    if dest.exists():
        raise BackendError(
            f"There's already a folder at {dest}.\n\n"
            "Rename or remove it first, or use 'Browse' to deploy it as-is.")

    try:
        with zipfile.ZipFile(src) as zf:
            # Reject entries that would escape the destination. Zip files
            # can contain ../ paths, and this one comes from wherever the
            # researcher got it.
            for member in zf.namelist():
                target = (dest / member).resolve()
                if not str(target).startswith(str(dest.resolve())):
                    raise BackendError(
                        f"That archive contains an unsafe path ({member}) "
                        "and was not extracted.")
            zf.extractall(dest)
    except zipfile.BadZipFile:
        raise BackendError(f"{src.name} is not a valid .zip file.") from None

    entries = [p for p in dest.iterdir() if not p.name.startswith("__MACOSX")]
    if len(entries) == 1 and entries[0].is_dir():
        return entries[0]
    return dest


def read_block_devices() -> tuple[str, str]:
    """Raw ``lsblk`` and ``findmnt`` JSON, for volumes.py to parse.

    Returns empty strings when the commands don't exist — which is the case
    on macOS, where the GUI is developed. Callers degrade to offering the
    home directory rather than failing.
    """
    lsblk_text = findmnt_text = ""
    if shutil.which("lsblk"):
        proc = _run(["lsblk", "-J", "-b", "-o",
                     "NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT"], timeout=20)
        if proc.returncode == 0:
            lsblk_text = proc.stdout
    if shutil.which("findmnt"):
        proc = _run(["findmnt", "-J", "-b", "-o",
                     "TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL"], timeout=20)
        if proc.returncode == 0:
            findmnt_text = proc.stdout
    return lsblk_text, findmnt_text


def public_ip() -> str:
    """This instance's public address, via common.sh's own lookup.

    Shelling out rather than reimplementing: a floating IP is NAT'd onto
    the instance, so the answer has to come from an external service, and
    common.sh already handles the fallbacks. Returns a placeholder string
    if it can't be determined.
    """
    common = REPO_ROOT / "deploy" / "lib" / "common.sh"
    proc = _run(["bash", "-c", f'source "{common}"; public_ip'], timeout=20)
    return proc.stdout.strip() if proc.returncode == 0 else "<instance-fixed-ip>"


def username() -> str:
    return os.environ.get("USER") or os.environ.get("LOGNAME") or "exouser"


def open_folder(path: str) -> None:
    """Show a folder in the desktop's file manager."""
    open_in_browser(path)


def docker_available() -> tuple[bool, str]:
    """Whether Docker is usable by this user, and why not if it isn't."""
    if shutil.which("docker") is None:
        return False, "Docker is not installed on this machine."
    proc = _run(["docker", "info"], timeout=30)
    if proc.returncode != 0:
        return False, (proc.stderr.strip() or
                       "Docker is installed but not responding.")
    return True, ""


def open_in_browser(url: str) -> None:
    """Open a URL in the desktop's browser.

    xdg-open rather than Python's webbrowser module: on a bare remote
    desktop the module's heuristics can pick a browser that isn't installed,
    while xdg-open honours the desktop environment's own association.
    """
    if shutil.which("xdg-open"):
        subprocess.Popen(["xdg-open", url],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:  # macOS, for development
        subprocess.Popen(["open", url],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
