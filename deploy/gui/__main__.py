#!/usr/bin/env python3
"""Deploy My Dashboard — a front end for deploy/build_and_run.sh.

Run via deploy/gui/launch_gui.sh, which checks tkinter and Docker first and
reports failures in a dialog (a .desktop launcher has no terminal, so an
uncaught traceback would be invisible).

Everything that touches the shell lives in backend.py. This module is
widgets and wiring only.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Allow flat imports (backend, runner) whether launched by path or module.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import tkinter as tk  # noqa: E402
from tkinter import filedialog, messagebox, ttk  # noqa: E402

import backend  # noqa: E402
import runner  # noqa: E402

PAD = 10


class DeployApp(ttk.Frame):
    def __init__(self, root: tk.Tk) -> None:
        super().__init__(root, padding=PAD)
        self.root = root
        self.grid(row=0, column=0, sticky="nsew")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(3, weight=1)

        self.info: backend.ProjectInfo | None = None
        self.tailer: runner.LogTailer | None = None
        self.handle: backend.RunHandle | None = None
        self._tick_id: str | None = None

        self.project_var = tk.StringVar()
        self.data_var = tk.StringVar()
        self.status_var = tk.StringVar(value="Choose your project folder to begin.")

        self._build_project_row()
        self._build_result_card()
        self._build_actions()
        self._build_log()

        self._reattach_if_building()

    # -- layout -----------------------------------------------------------

    def _build_project_row(self) -> None:
        box = ttk.LabelFrame(self, text="1. Your dashboard project", padding=PAD)
        box.grid(row=0, column=0, sticky="ew")
        box.columnconfigure(0, weight=1)

        ttk.Entry(box, textvariable=self.project_var).grid(
            row=0, column=0, sticky="ew", padx=(0, PAD))
        ttk.Button(box, text="Browse…", command=self._browse_project).grid(
            row=0, column=1)
        ttk.Button(box, text="Check", command=self._check).grid(
            row=0, column=2, padx=(PAD, 0))

    def _build_result_card(self) -> None:
        self.card = ttk.LabelFrame(self, text="2. What we found", padding=PAD)
        self.card.grid(row=1, column=0, sticky="ew", pady=(PAD, 0))
        self.card.columnconfigure(0, weight=1)
        self.card_label = ttk.Label(self.card, textvariable=self.status_var,
                                    wraplength=640, justify="left")
        self.card_label.grid(row=0, column=0, sticky="w")

        self.data_row = ttk.Frame(self.card)
        self.data_row.columnconfigure(1, weight=1)
        ttk.Label(self.data_row, text="Data folder:").grid(row=0, column=0)
        ttk.Entry(self.data_row, textvariable=self.data_var).grid(
            row=0, column=1, sticky="ew", padx=PAD)
        ttk.Button(self.data_row, text="Browse…",
                   command=self._browse_data).grid(row=0, column=2)

    def _build_actions(self) -> None:
        row = ttk.Frame(self)
        row.grid(row=2, column=0, sticky="ew", pady=(PAD, 0))
        self.deploy_btn = ttk.Button(row, text="Deploy dashboard",
                                     command=self._deploy, state="disabled")
        self.deploy_btn.grid(row=0, column=0)
        self.cancel_btn = ttk.Button(row, text="Cancel build",
                                     command=self._cancel, state="disabled")
        self.cancel_btn.grid(row=0, column=1, padx=PAD)
        self.elapsed_lbl = ttk.Label(row, text="")
        self.elapsed_lbl.grid(row=0, column=2, padx=PAD)

    def _build_log(self) -> None:
        box = ttk.LabelFrame(self, text="Build log", padding=PAD)
        box.grid(row=3, column=0, sticky="nsew", pady=(PAD, 0))
        box.columnconfigure(0, weight=1)
        box.rowconfigure(0, weight=1)

        self.log = tk.Text(box, height=16, wrap="none", state="disabled",
                           font=("TkFixedFont", 10))
        self.log.grid(row=0, column=0, sticky="nsew")
        bar = ttk.Scrollbar(box, orient="vertical", command=self.log.yview)
        bar.grid(row=0, column=1, sticky="ns")
        self.log.configure(yscrollcommand=bar.set)

    # -- actions ----------------------------------------------------------

    def _browse_project(self) -> None:
        chosen = filedialog.askdirectory(title="Select your dashboard project folder")
        if chosen:
            self.project_var.set(chosen)
            self._check()

    def _browse_data(self) -> None:
        chosen = filedialog.askdirectory(title="Select the folder holding your data")
        if chosen:
            self.data_var.set(chosen)

    def _check(self) -> None:
        path = self.project_var.get().strip()
        if not path:
            messagebox.showinfo("Choose a folder",
                                "Pick the folder containing your dashboard first.")
            return
        try:
            self.info = backend.inspect_project(path)
        except backend.BackendError as exc:
            self.info = None
            self.data_row.grid_forget()
            self.status_var.set("Not a project we can deploy yet.")
            # The shell's own message, verbatim — it is written for
            # researchers and stays correct as the shell changes.
            messagebox.showerror("Can't deploy this folder", exc.full_text())
            self._refresh_deploy_state()
            return

        info = self.info
        lines = [
            f"Framework:   {info.framework}",
            f"Entry point: {info.entry_point_desc}",
            f"Base image:  {info.base_image}",
        ]
        if info.deps_state == "missing":
            lines.append("\nDependencies: MISSING — this project needs a "
                         "requirements.txt listing its Python packages "
                         "before it can be deployed.")
        elif info.expect_slow_build:
            lines.append("\nDependencies: no renv.lock yet — one will be "
                         "generated first, so this build will take "
                         "noticeably longer than usual.")
        else:
            lines.append("\nDependencies: ready.")

        if info.has_data_dir:
            lines.append(f"\nThis project reads from a data/ folder, so it needs "
                         f"one on this machine. It will appear inside the app at "
                         f"{info.data_mount_target}.")
            self.data_row.grid(row=1, column=0, sticky="ew", pady=(PAD, 0))
        else:
            self.data_row.grid_forget()

        self.status_var.set("\n".join(lines))
        self._refresh_deploy_state()

    def _refresh_deploy_state(self) -> None:
        ready = (self.info is not None
                 and self.info.deps_ok
                 and (not self.info.needs_data_dir or bool(self.data_var.get().strip()))
                 and self.handle is None)
        self.deploy_btn.configure(state="normal" if ready else "disabled")

    def _deploy(self) -> None:
        if self.info is None:
            return
        if self.info.needs_data_dir and not self.data_var.get().strip():
            messagebox.showinfo(
                "Data folder needed",
                "This project reads from a data/ folder, so please choose "
                "where that data lives on this machine.")
            return

        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")

        self.handle = backend.start_deploy(
            self.project_var.get().strip(),
            data_dir=self.data_var.get().strip())
        self._attach(self.handle)

    def _attach(self, handle: backend.RunHandle) -> None:
        self.handle = handle
        self.deploy_btn.configure(state="disabled")
        self.cancel_btn.configure(state="normal")
        self.tailer = runner.LogTailer(
            handle,
            on_line=lambda chunk: runner.append_to_text(self.log, chunk),
            on_finish=self._finished)
        self.tailer.start(self.after)
        self._tick()

    def _tick(self) -> None:
        if self.tailer is not None and self.handle is not None:
            self.elapsed_lbl.configure(
                text=f"Working… {self.tailer.elapsed()} elapsed")
            self._tick_id = self.after(1000, self._tick)

    def _finished(self, code: int) -> None:
        if self._tick_id is not None:
            self.after_cancel(self._tick_id)
            self._tick_id = None
        self.handle = None
        self.tailer = None
        self.cancel_btn.configure(state="disabled")
        self.elapsed_lbl.configure(text="")
        self._refresh_deploy_state()

        if code == 0:
            status = backend.container_status()
            url = status.get("url", "")
            # Deliberately not "success" — run_smoke_test only proves the
            # app is serving. Shiny and Streamlit render script errors in
            # the browser and still return 200, so the only way to know the
            # dashboard is right is to look at it.
            msg = "Your dashboard is live" + (f" at {url}" if url else "") + \
                  ".\n\nOpen it now and check it looks the way you expect."
            if url and messagebox.askyesno("Dashboard deployed",
                                           msg + "\n\nOpen it in a browser?"):
                backend.open_in_browser(url)
            elif not url:
                messagebox.showinfo("Dashboard deployed", msg)
        else:
            messagebox.showerror(
                "Deployment failed",
                "The build did not finish successfully.\n\n"
                "The reason is at the end of the build log above. The full "
                f"log is saved at:\n{backend.LOG_DIR}")

    def _cancel(self) -> None:
        if self.handle is None:
            return
        if not messagebox.askyesno("Stop the build?",
                                   "Stop this build? Any progress will be lost."):
            return
        backend.cancel(self.handle)

    def _reattach_if_building(self) -> None:
        """Pick up a build left running by a previous session."""
        existing = backend.find_running_build()
        if existing is None:
            return
        self.status_var.set(
            "A deployment started earlier is still running — reattaching to it.")
        self._attach(existing)


def main() -> int:
    root = tk.Tk()
    root.title("Deploy My Dashboard")
    root.geometry("760x640")
    root.minsize(640, 480)
    DeployApp(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
