#!/usr/bin/env python3
"""Deploy My Dashboard — a front end for deploy/build_and_run.sh.

Launch via deploy/gui/launch_gui.sh, which verifies tkinter and Docker
first and reports problems in a dialog. A .desktop launcher runs with no
terminal attached, so an uncaught traceback would otherwise be invisible
and the icon would appear to do nothing.

Layout lives in ui.py; every shell command lives in backend.py.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Support being run by path (the launcher) as well as `python3 -m gui`.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import tkinter as tk  # noqa: E402
from tkinter import messagebox  # noqa: E402

import backend  # noqa: E402
import ui  # noqa: E402


def _apply_icon(root: tk.Tk) -> None:
    """Give the window its own icon.

    Tk's PhotoImage reads PNG but not SVG, hence the bitmap alongside the
    scalable one. Purely cosmetic, so any failure is ignored — an icon is
    never worth refusing to start over.
    """
    png = Path(__file__).resolve().parent.parent / "desktop" / "dashboard-deploy.png"
    try:
        root._icon = tk.PhotoImage(file=str(png))   # keep a reference alive
        root.iconphoto(True, root._icon)
    except Exception:
        pass


def main() -> int:
    # className sets WM_CLASS, which is what a dock matches against the
    # StartupWMClass line in dashboard-deploy.desktop. Without a stable
    # value the window can't be associated with its launcher and the dock
    # shows a generic icon. Change this and the .desktop together.
    root = tk.Tk(className="DashboardDeploy")
    _apply_icon(root)
    root.title("Deploy My Dashboard")
    root.geometry("820x720")
    root.minsize(720, 560)

    ok, why = backend.docker_available()
    if not ok:
        # launch_gui.sh checks this too, but the GUI can also be started
        # directly, and a clear dialog beats a confusing failure four
        # clicks later.
        messagebox.showerror(
            "Docker isn't available",
            "Dashboards are built and run with Docker, which isn't working "
            f"on this machine right now.\n\n{why}")
        return 1

    ui.MainWindow(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
