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
from tkinter import messagebox, ttk  # noqa: E402

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


def _apply_theme(root: tk.Tk) -> None:
    """Switch ttk over to the vendored Azure light theme.

    Same failure policy as _apply_icon, and for a sharper reason: a .desktop
    launcher has no terminal, so an exception raised here would make the icon
    silently do nothing at all — the exact failure launch_gui.sh exists to
    prevent. An unthemed window is always better than no window.

    See deploy/gui/azure/README.md for what's vendored and why the two
    adjustments below are made here rather than in the theme itself.
    """
    tcl = Path(__file__).resolve().parent / "azure" / "azure.tcl"
    try:
        # azure.tcl locates its own assets via [file dirname [info script]],
        # so sourcing it by absolute path works from any cwd — and the
        # launcher deliberately doesn't cd, so cwd is arbitrary.
        root.tk.call("source", str(tcl))
        root.tk.call("set_theme", "light")

        # set_theme calls `ttk::style theme use` directly, which changes the
        # theme but leaves $ttk::currentTheme untouched — and that variable
        # is exactly what tkinter's Style().theme_use() reads back. Without
        # this line the window is themed while Python is told it is still on
        # the platform default, so any future code that branches on the
        # active theme would branch wrongly. ttk::setTheme is the wrapper
        # that keeps the two in step.
        root.tk.call("ttk::setTheme", "azure-light")

        # set_theme hardcodes "Segoe Ui", a Windows font absent on Ubuntu.
        # Left alone, themed widgets fall back to some default family while
        # the labels in ui.py that pin ("TkDefaultFont", ...) keep theirs,
        # putting two typefaces in one window. Both the style and the option
        # database need correcting — set_theme writes to each.
        ttk.Style().configure(".", font="TkDefaultFont")
        root.option_add("*font", "TkDefaultFont")
    except Exception:
        pass


def main() -> int:
    # className sets WM_CLASS, which is what a dock matches against the
    # StartupWMClass line in dashboard-deploy.desktop. Without a matching
    # pair the window can't be associated with its launcher and the dock
    # shows a generic gear regardless of the Icon= setting.
    #
    # Tk does NOT use this string verbatim: it capitalises the first
    # character and lower-cases the rest, so "DashboardDeploy" would arrive
    # as "Dashboarddeploy" and silently fail to match. The all-lowercase
    # form below makes the transformation obvious — it becomes
    # "Dashboard-deploy", which is exactly what the .desktop declares.
    # If you change this, check tk.Tk(...).winfo_class() and update the
    # .desktop to match.
    root = tk.Tk(className="dashboard-deploy")
    _apply_icon(root)
    # Before the Docker check below, so its error dialog is themed too.
    _apply_theme(root)
    root.title("Deploy My Dashboard")
    # Roomier than the pre-theme 820x720 / 720x560. The theme pads more than
    # Tk's default, and tabs 3 and 4 have no scroll region to absorb it: the
    # notebook reports the tallest tab needing ~671x692 at this machine's
    # font size, so the old 560 floor clipped the Manage tab's log box. The
    # minimum is set just above that measurement rather than guessed, and
    # kept small enough to still fit a 1024x768 remote desktop. Re-measure
    # (root.winfo_reqheight() with each tab selected) before changing it.
    root.geometry("900x780")
    root.minsize(720, 700)

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
