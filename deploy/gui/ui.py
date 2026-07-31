"""The window: four tabs that read as a linear workflow.

    1. Your app  →  2. Your data  →  3. Publish  →  4. Manage

No shell commands are constructed here; everything goes through backend.py.
Wording throughout assumes a researcher who has never used Docker and may
never have opened a terminal, so error text explains consequences rather
than naming mechanisms.
"""

from __future__ import annotations

import queue
import threading
import tkinter as tk
from dataclasses import dataclass, field
from tkinter import filedialog, messagebox, ttk

import backend
import runner
import transfer
import volumes

PAD = 10


@dataclass
class Shared:
    """State the tabs pass between each other."""

    project_dir: str = ""
    data_dir: str = ""
    info: backend.ProjectInfo | None = None
    listeners: list = field(default_factory=list)

    def changed(self) -> None:
        for fn in self.listeners:
            fn()


def _folder_is_empty(path: str) -> bool:
    """Whether a directory holds no files at any depth.

    Cheap on purpose — stops at the first file rather than walking a
    dataset that may be very large.
    """
    from pathlib import Path
    try:
        for entry in Path(path).rglob("*"):
            if entry.is_file():
                return False
    except OSError:
        return False
    return True


def _selectable_text(parent, content: str, height: int = 2) -> tk.Text:
    """A read-only Text the user can still select and copy from.

    Not a Label: researchers need to copy the rsync command out, and Tk
    loses clipboard ownership when the app exits, so a copy button alone
    isn't dependable. Selectable text always works.
    """
    widget = tk.Text(parent, height=height, wrap="word", font=("TkFixedFont", 10),
                     relief="solid", borderwidth=1)
    widget.insert("1.0", content)
    widget.configure(state="disabled")
    return widget


class ScrollableFrame(ttk.Frame):
    """A frame whose contents may be taller than the window.

    Needed because widget heights depend on the desktop's font size, which
    varies a lot between a developer's laptop and a remote desktop session.
    A tab that fits comfortably at one font size silently clips its bottom
    widgets at another — and a clipped widget looks like a broken feature,
    not a layout problem, because the button is visible and the output it
    writes is not.

    Put children into ``.body``.
    """

    def __init__(self, parent) -> None:
        super().__init__(parent)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)

        self._canvas = tk.Canvas(self, highlightthickness=0, borderwidth=0)
        self._canvas.grid(row=0, column=0, sticky="nsew")
        self._bar = ttk.Scrollbar(self, orient="vertical",
                                  command=self._canvas.yview)
        self._canvas.configure(yscrollcommand=self._on_scroll_set)

        self.body = ttk.Frame(self._canvas, padding=PAD)
        self._window = self._canvas.create_window((0, 0), window=self.body,
                                                  anchor="nw")

        self.body.bind("<Configure>", self._on_body_resize)
        self._canvas.bind("<Configure>", self._on_canvas_resize)
        # Wheel bindings are per-widget in Tk, and differ by platform:
        # X11 sends Button-4/5, macOS and Windows send MouseWheel.
        for seq, delta in (("<Button-4>", -1), ("<Button-5>", 1)):
            self._canvas.bind_all(seq, self._make_wheel(delta), add="+")
        self._canvas.bind_all("<MouseWheel>", self._on_mousewheel, add="+")

    def _on_body_resize(self, _event=None) -> None:
        self._canvas.configure(scrollregion=self._canvas.bbox("all"))

    def _on_canvas_resize(self, event) -> None:
        # Keep the inner frame as wide as the viewport so wraplength and
        # sticky="ew" behave as they would without the canvas.
        self._canvas.itemconfigure(self._window, width=event.width)

    def _on_scroll_set(self, first: str, last: str) -> None:
        # Only show the scrollbar when it's actually needed, so the common
        # case looks like an ordinary tab.
        if float(first) <= 0.0 and float(last) >= 1.0:
            self._bar.grid_remove()
        else:
            self._bar.grid(row=0, column=1, sticky="ns")
        self._bar.set(first, last)

    def _scrollable(self) -> bool:
        first, last = self._canvas.yview()
        return not (first <= 0.0 and last >= 1.0)

    def _pointer_inside(self) -> bool:
        widget = self.winfo_containing(self.winfo_pointerx(), self.winfo_pointery())
        while widget is not None:
            if widget is self:
                return True
            widget = getattr(widget, "master", None)
        return False

    def _make_wheel(self, delta: int):
        def handler(_event=None):
            if self._scrollable() and self._pointer_inside():
                self._canvas.yview_scroll(delta, "units")
        return handler

    def _on_mousewheel(self, event) -> None:
        if self._scrollable() and self._pointer_inside():
            self._canvas.yview_scroll(-1 if event.delta > 0 else 1, "units")


# --------------------------------------------------------------------------
# Tab 1 — the app
# --------------------------------------------------------------------------
class AppTab(ttk.Frame):
    def __init__(self, parent, shared: Shared) -> None:
        super().__init__(parent, padding=PAD)
        self.shared = shared
        self.columnconfigure(0, weight=1)

        ttk.Label(self, text="Where is your dashboard's code?",
                  font=("TkDefaultFont", 12, "bold")).grid(row=0, column=0, sticky="w")

        self.choice = tk.StringVar(value="browse")
        box = ttk.Frame(self)
        box.grid(row=1, column=0, sticky="ew", pady=(PAD, 0))
        box.columnconfigure(0, weight=1)

        for i, (key, label) in enumerate([
            ("browse", "It's already on this server"),
            ("git", "Download it from GitHub (or another Git address)"),
            ("zip", "I have a .zip file"),
        ]):
            ttk.Radiobutton(box, text=label, value=key, variable=self.choice,
                            command=self._switch).grid(row=i, column=0, sticky="w")

        self.panel = ttk.Frame(self)
        self.panel.grid(row=2, column=0, sticky="ew", pady=(PAD, 0))
        self.panel.columnconfigure(1, weight=1)

        self.path_var = tk.StringVar()
        self.git_var = tk.StringVar()
        self.zip_var = tk.StringVar()
        self.result = tk.StringVar(value="")

        ttk.Label(self, textvariable=self.result, wraplength=680,
                  justify="left").grid(row=3, column=0, sticky="w", pady=(PAD, 0))
        self._switch()

    def _clear_panel(self) -> None:
        for child in self.panel.winfo_children():
            child.destroy()

    def _switch(self) -> None:
        self._clear_panel()
        mode = self.choice.get()
        if mode == "browse":
            ttk.Label(self.panel, text="Folder:").grid(row=0, column=0, sticky="w")
            ttk.Entry(self.panel, textvariable=self.path_var).grid(
                row=0, column=1, sticky="ew", padx=PAD)
            ttk.Button(self.panel, text="Browse…", command=self._browse).grid(
                row=0, column=2)
            ttk.Button(self.panel, text="Use this folder",
                       command=lambda: self._adopt(self.path_var.get())).grid(
                row=1, column=1, sticky="w", padx=PAD, pady=(PAD, 0))
        elif mode == "git":
            ttk.Label(self.panel, text="Address:").grid(row=0, column=0, sticky="w")
            ttk.Entry(self.panel, textvariable=self.git_var).grid(
                row=0, column=1, sticky="ew", padx=PAD)
            ttk.Button(self.panel, text="Download", command=self._clone).grid(
                row=0, column=2)
            ttk.Label(self.panel,
                      text="Example:  https://github.com/your-lab/your-dashboard",
                      foreground="gray40").grid(row=1, column=1, sticky="w", padx=PAD)
        else:
            ttk.Label(self.panel, text="Zip file:").grid(row=0, column=0, sticky="w")
            ttk.Entry(self.panel, textvariable=self.zip_var).grid(
                row=0, column=1, sticky="ew", padx=PAD)
            ttk.Button(self.panel, text="Choose…", command=self._pick_zip).grid(
                row=0, column=2)
            ttk.Button(self.panel, text="Unpack it", command=self._unzip).grid(
                row=1, column=1, sticky="w", padx=PAD, pady=(PAD, 0))

    def _browse(self) -> None:
        chosen = filedialog.askdirectory(title="Select your dashboard folder")
        if chosen:
            self.path_var.set(chosen)
            self._adopt(chosen)

    def _pick_zip(self) -> None:
        chosen = filedialog.askopenfilename(title="Select a .zip file",
                                            filetypes=[("Zip archives", "*.zip")])
        if chosen:
            self.zip_var.set(chosen)

    def _clone(self) -> None:
        try:
            dest = backend.clone_repo(self.git_var.get())
        except backend.BackendError as exc:
            messagebox.showerror("Could not download", exc.full_text())
            return
        self._adopt(str(dest))

    def _unzip(self) -> None:
        try:
            dest = backend.extract_zip(self.zip_var.get())
        except backend.BackendError as exc:
            messagebox.showerror("Could not unpack", exc.full_text())
            return
        self._adopt(str(dest))

    def _adopt(self, path: str) -> None:
        path = path.strip()
        if not path:
            return
        try:
            info = backend.inspect_project(path)
        except backend.BackendError as exc:
            self.shared.project_dir = ""
            self.shared.info = None
            self.shared.changed()
            self.result.set("")
            messagebox.showerror("This doesn't look like a dashboard yet",
                                 exc.full_text())
            return
        self.shared.project_dir = path
        self.shared.info = info
        self.shared.changed()
        self.result.set(
            f"Found a {info.framework} dashboard in {path}\n"
            f"Entry point: {info.entry_point_desc}\n\n"
            + ("This project includes a data/ folder, so choose where that "
               "data lives on this server in step 2."
               if info.has_data_dir else
               "This project doesn't include a data/ folder. If your dashboard "
               "reads data files kept somewhere else — on your storage volume, "
               "say — point step 2 at them. Otherwise go straight to step 3."))


# --------------------------------------------------------------------------
# Tab 2 — the data
# --------------------------------------------------------------------------
class DataTab(ttk.Frame):
    def __init__(self, parent, shared: Shared) -> None:
        super().__init__(parent)
        self.shared = shared
        self.shared.listeners.append(self._refresh_header)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)

        # This is the tallest tab and its height varies with the selected
        # transfer route, so it scrolls. Without it the results box at the
        # bottom is simply unreachable at larger font sizes.
        self._scroll = ScrollableFrame(self)
        self._scroll.grid(row=0, column=0, sticky="nsew")
        body = self._scroll.body
        body.columnconfigure(0, weight=1)

        self.header = tk.StringVar()
        ttk.Label(body, textvariable=self.header, wraplength=680,
                  justify="left").grid(row=0, column=0, sticky="w")

        # -- where it should end up
        dest_box = ttk.LabelFrame(body, text="Where your data will live",
                                  padding=PAD)
        dest_box.grid(row=1, column=0, sticky="ew", pady=(PAD, 0))
        dest_box.columnconfigure(0, weight=1)

        self.locations: list[volumes.Location] = []
        self.loc_list = tk.Listbox(dest_box, height=4, exportselection=False)
        self.loc_list.grid(row=0, column=0, sticky="ew")
        self.loc_list.bind("<<ListboxSelect>>", self._pick_location)

        btns = ttk.Frame(dest_box)
        btns.grid(row=1, column=0, sticky="ew", pady=(PAD, 0))
        ttk.Button(btns, text="Refresh", command=self._load_locations).grid(row=0, column=0)
        ttk.Button(btns, text="Choose another folder…",
                   command=self._browse).grid(row=0, column=1, padx=PAD)

        self.mapping = tk.StringVar()
        ttk.Label(dest_box, textvariable=self.mapping, foreground="gray30",
                  font=("TkFixedFont", 10)).grid(row=2, column=0, sticky="w",
                                                 pady=(PAD, 0))

        # Reboot persistence. Presented as its own optional step rather than
        # folded into publishing: it changes system configuration, so it
        # should be a deliberate act with the exact change shown first.
        self.persist_row = ttk.Frame(dest_box)
        self.persist_row.columnconfigure(0, weight=1)
        self.persist_note = tk.StringVar()
        ttk.Label(self.persist_row, textvariable=self.persist_note,
                  wraplength=620, justify="left").grid(row=0, column=0, sticky="w")
        self.persist_btn = ttk.Button(self.persist_row,
                                      text="Make this permanent",
                                      command=self._persist)
        self.persist_btn.grid(row=0, column=1, padx=(PAD, 0))

        # -- how to get it there
        route_box = ttk.LabelFrame(body, text="How to get your data here",
                                   padding=PAD)
        route_box.grid(row=2, column=0, sticky="ew", pady=(PAD, 0))
        route_box.columnconfigure(0, weight=1)

        self.route_var = tk.StringVar(value="globus")
        self.routes = transfer.build_routes(
            backend.public_ip(), backend.username(), "")
        for i, route in enumerate(self.routes):
            ttk.Radiobutton(route_box, text=route.title, value=route.key,
                            variable=self.route_var,
                            command=self._show_route).grid(row=i, column=0, sticky="w")

        self.route_panel = ttk.Frame(body)
        self.route_panel.grid(row=3, column=0, sticky="ew", pady=(PAD, 0))
        self.route_panel.columnconfigure(0, weight=1)

        # -- did it arrive?
        check_box = ttk.LabelFrame(body, text="Check what's arrived", padding=PAD)
        check_box.grid(row=4, column=0, sticky="ew", pady=(PAD, 0))
        check_box.columnconfigure(0, weight=1)
        check_box.rowconfigure(1, weight=1)
        ttk.Button(check_box, text="Look in that folder now",
                   command=self._verify).grid(row=0, column=0, sticky="w")
        self.verify_out = tk.Text(check_box, height=6, wrap="none",
                                  state="disabled", font=("TkFixedFont", 10))
        self.verify_out.grid(row=1, column=0, sticky="nsew", pady=(PAD, 0))

        self._load_locations()
        self._show_route()
        self._refresh_header()

    def _refresh_header(self) -> None:
        info = self.shared.info
        target = info.data_mount_target if info else "the app's data folder"
        if info is None:
            self.header.set("Choose your dashboard in step 1 first.")
        elif not info.has_data_dir:
            # Deliberately not "you can skip this step". Moving data out of
            # the project and onto a volume is what the docs recommend, and
            # doing so removes the data/ folder this flag reports on — so
            # the projects most in need of this step are the ones that look
            # like they don't need it.
            self.header.set(
                "This project doesn't include a data/ folder of its own. If "
                "your dashboard reads data files that live somewhere else on "
                "this server — a storage volume, typically — choose that "
                f"folder below and it will appear inside your app at {target}. "
                "If your dashboard doesn't read any data files, skip to step 3.")
        else:
            self.header.set(
                "This dashboard reads from a data/ folder. Pick where that "
                f"data lives on this server; it appears inside the app at "
                f"{target}. It is mounted at run time rather than copied in, "
                "so you can update the data later without rebuilding anything.")
        self._update_mapping()

    def _load_locations(self) -> None:
        lsblk_text, findmnt_text = backend.read_block_devices()
        self.locations = volumes.discover_locations(lsblk_text, findmnt_text)
        self.loc_list.delete(0, "end")
        for loc in self.locations:
            self.loc_list.insert("end", loc.describe())

        # Preselect a mounted storage volume, since that is nearly always
        # the right answer and there's usually exactly one. Never preselect
        # the home directory: it's on the instance's root disk, so silently
        # defaulting to it would put a research dataset somewhere small and
        # impermanent without the researcher ever choosing it. With no
        # volume attached, leave this unanswered so the choice is deliberate.
        for i, loc in enumerate(self.locations):
            if loc.kind == "volume":
                self.loc_list.selection_set(i)
                self._select(loc)
                break

    def _pick_location(self, _event=None) -> None:
        sel = self.loc_list.curselection()
        if not sel:
            return
        loc = self.locations[sel[0]]
        if not loc.is_usable:
            messagebox.showinfo(
                "Not ready to use",
                loc.describe() + "\n\nAttach and mount it in Exosphere first, "
                "then press Refresh.")
            return
        self._select(loc)

    def _select(self, loc: volumes.Location) -> None:
        self.shared.data_dir = loc.path
        self.selected_location = loc
        self.shared.changed()
        self._update_mapping()
        self._show_route()
        if loc.on_root_disk:
            self.mapping.set(self.mapping.get() +
                             "\nNote: this is the system disk — fine for trying "
                             "things out, but use a storage volume for real data.")
        self._update_persist()

    def _update_persist(self) -> None:
        """Offer reboot persistence only when it's both possible and needed."""
        loc = getattr(self, "selected_location", None)
        if loc is None or loc.kind != "volume" or not loc.uuid:
            self.persist_row.grid_forget()
            return

        state = backend.mount_is_persisted(loc.uuid, loc.path)
        if state is True:
            self.persist_note.set(
                "This volume is already set to reconnect automatically after "
                "a reboot.")
            self.persist_btn.grid_remove()
        elif state is False:
            self.persist_note.set(
                "This volume is mounted now, but will NOT reconnect by itself "
                "after the instance reboots — your dashboard would restart "
                "with no data. This is worth fixing once.")
            self.persist_btn.grid()
        else:
            self.persist_row.grid_forget()
            return
        self.persist_row.grid(row=3, column=0, sticky="ew", pady=(PAD, 0))

    def _persist(self) -> None:
        loc = getattr(self, "selected_location", None)
        if loc is None:
            return
        preview = backend.fstab_preview(loc.uuid, loc.path, loc.fstype)
        if not messagebox.askyesno(
                "Make this permanent?",
                "This adds one line to the system's /etc/fstab so the volume "
                "reconnects automatically at every boot:\n\n"
                f"{preview}\n\n"
                "It includes 'nofail', which means the instance will still "
                "start normally even if this volume is ever removed. The "
                "current file is backed up first, and the change is undone "
                "automatically if it doesn't validate.\n\n"
                "You'll be asked for an administrator password. Continue?"):
            return
        try:
            out = backend.persist_mount(loc.uuid, loc.path, loc.fstype)
        except backend.BackendError as exc:
            messagebox.showerror("Could not make it permanent", exc.full_text())
            return
        messagebox.showinfo(
            "Done",
            out.strip() or "This volume will now reconnect after a reboot.")
        self._update_persist()

    def _browse(self) -> None:
        chosen = filedialog.askdirectory(title="Select the folder holding your data")
        if chosen:
            self.shared.data_dir = chosen
            self.shared.changed()
            self._update_mapping()
            self._show_route()

    def _update_mapping(self) -> None:
        info = self.shared.info
        if self.shared.data_dir and info is not None:
            self.mapping.set(volumes.mount_mapping(
                self.shared.data_dir, info.data_mount_target))
        elif self.shared.data_dir:
            self.mapping.set(f"Selected: {self.shared.data_dir}")
        else:
            self.mapping.set("")

    def _show_route(self) -> None:
        for child in self.route_panel.winfo_children():
            child.destroy()
        dest = self.shared.data_dir
        routes = transfer.build_routes(backend.public_ip(), backend.username(), dest)
        route = next(r for r in routes if r.key == self.route_var.get())

        ttk.Label(self.route_panel, text=route.blurb, wraplength=680,
                  justify="left").grid(row=0, column=0, sticky="w")
        ttk.Label(self.route_panel, text=f"Best for: {route.best_for}",
                  foreground="gray40").grid(row=1, column=0, sticky="w")

        row = 2
        if route.command:
            _selectable_text(self.route_panel, route.command, height=2).grid(
                row=row, column=0, sticky="ew", pady=(PAD, 0))
            ttk.Label(self.route_panel,
                      text="Select the text above and copy it — then run it on "
                           "your own computer, not here.",
                      foreground="gray40").grid(row=row + 1, column=0, sticky="w")
            row += 2

        link_row = ttk.Frame(self.route_panel)
        link_row.grid(row=row, column=0, sticky="w", pady=(PAD, 0))
        for i, (label, url) in enumerate(route.links):
            ttk.Button(link_row, text=label,
                       command=lambda u=url: backend.open_in_browser(u)).grid(
                row=0, column=i, padx=(0, PAD))
        if route.folder:
            ttk.Button(link_row, text="Open that folder",
                       command=lambda f=route.folder: backend.open_folder(f)).grid(
                row=0, column=len(route.links), padx=(0, PAD))

    def _verify(self) -> None:
        target = self.shared.data_dir
        if not target:
            messagebox.showinfo("Pick a folder first",
                                "Choose where your data will live, above.")
            return
        summary = transfer.summarise_folder(target)
        self.verify_out.configure(state="normal")
        self.verify_out.delete("1.0", "end")
        self.verify_out.insert("1.0", summary)
        self.verify_out.configure(state="disabled")


# --------------------------------------------------------------------------
# Tab 3 — publish
# --------------------------------------------------------------------------
class DeployTab(ttk.Frame):
    def __init__(self, parent, shared: Shared) -> None:
        super().__init__(parent, padding=PAD)
        self.shared = shared
        self.shared.listeners.append(self._refresh)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(3, weight=1)

        self.summary = tk.StringVar()
        ttk.Label(self, textvariable=self.summary, wraplength=680,
                  justify="left").grid(row=0, column=0, sticky="w")

        adv = ttk.LabelFrame(self, text="Advanced (rarely needed)", padding=PAD)
        adv.grid(row=1, column=0, sticky="ew", pady=(PAD, 0))
        self.framework_var = tk.StringVar()
        self.port_var = tk.StringVar()
        ttk.Label(adv, text="Force framework:").grid(row=0, column=0, sticky="w")
        ttk.Combobox(adv, textvariable=self.framework_var, width=16,
                     values=["", "r-shiny", "dash", "python-shiny", "streamlit"],
                     state="readonly").grid(row=0, column=1, padx=PAD)
        ttk.Label(adv, text="App's internal port:").grid(row=0, column=2, sticky="w")
        ttk.Entry(adv, textvariable=self.port_var, width=8).grid(row=0, column=3, padx=PAD)

        # The escape hatch for old projects. A requirements.txt pinning a
        # package released years ago often cannot build against a current
        # Python at all, but installs from a prebuilt wheel on the Python it
        # was written for — so choosing an older base image is frequently the
        # difference between "won't build" and "works first time". Editable
        # rather than a fixed list, since R projects need rocker/* values.
        self.base_image_var = tk.StringVar()
        ttk.Label(adv, text="Base image:").grid(row=1, column=0, sticky="w",
                                                pady=(PAD, 0))
        ttk.Combobox(adv, textvariable=self.base_image_var, width=28,
                     values=["", "python:3.11-slim", "python:3.10-slim",
                             "python:3.9-slim", "python:3.8-slim",
                             "python:3.7-slim", "rocker/r-ver:4.4.1",
                             "rocker/geospatial:4.4.1"]).grid(
            row=1, column=1, columnspan=2, sticky="w", padx=PAD, pady=(PAD, 0))
        ttk.Label(adv,
                  text="Leave blank unless a dependency won't build — an older "
                       "Python often fixes an old project.",
                  foreground="gray40", wraplength=560).grid(
            row=2, column=0, columnspan=4, sticky="w", pady=(4, 0))

        actions = ttk.Frame(self)
        actions.grid(row=2, column=0, sticky="ew", pady=(PAD, 0))
        self.deploy_btn = ttk.Button(actions, text="Publish my dashboard",
                                     command=self._deploy, state="disabled")
        self.deploy_btn.grid(row=0, column=0)
        self.cancel_btn = ttk.Button(actions, text="Stop", command=self._cancel,
                                     state="disabled")
        self.cancel_btn.grid(row=0, column=1, padx=PAD)
        self.elapsed = ttk.Label(actions, text="")
        self.elapsed.grid(row=0, column=2, padx=PAD)

        log_box = ttk.LabelFrame(self, text="Progress", padding=PAD)
        log_box.grid(row=3, column=0, sticky="nsew", pady=(PAD, 0))
        log_box.columnconfigure(0, weight=1)
        log_box.rowconfigure(0, weight=1)
        self.log = tk.Text(log_box, height=14, wrap="none", state="disabled",
                           font=("TkFixedFont", 9))
        self.log.grid(row=0, column=0, sticky="nsew")
        bar = ttk.Scrollbar(log_box, orient="vertical", command=self.log.yview)
        bar.grid(row=0, column=1, sticky="ns")
        self.log.configure(yscrollcommand=bar.set)

        self.handle: backend.RunHandle | None = None
        self.tailer: runner.LogTailer | None = None
        self._tick_id: str | None = None
        self.on_deployed = lambda: None

        self._refresh()
        self._reattach()

    def _refresh(self) -> None:
        info = self.shared.info
        if info is None:
            self.summary.set("Choose your dashboard in step 1 first.")
            self.deploy_btn.configure(state="disabled")
            return

        lines = [f"Ready to publish the {info.framework} dashboard in "
                 f"{self.shared.project_dir}."]
        if info.deps_state == "missing":
            lines.append(
                "\nBefore this can be published it needs a requirements.txt "
                "listing the Python packages it uses. Create one in the "
                "environment where the app already works, with:\n"
                "    pip freeze > requirements.txt")
        elif info.expect_slow_build:
            lines.append(
                "\nThis project has no renv.lock, so its R packages will be "
                "worked out and recorded first. Expect this to take a while — "
                "often 20 minutes or more. It only happens once.")
        # Show the mount whenever one is configured, regardless of whether
        # the project ships its own data/ folder — otherwise a project whose
        # data was moved onto a volume gives no indication that anything is
        # being attached at all.
        if self.shared.data_dir:
            lines.append(f"\nData: {self.shared.data_dir}\n"
                         f"      appears inside the app at {info.data_mount_target}")
            # Catch the empty-folder case before a build that can run for
            # many minutes. The chosen folder is mounted *over* the app's
            # own data/, so an empty one doesn't merely add nothing — it
            # hides whatever the project shipped, and the app then dies at
            # startup looking for files that were there a moment ago.
            if _folder_is_empty(self.shared.data_dir):
                lines.append(
                    "\n  WARNING: that folder is empty. It will be mounted over "
                    "the app's own data folder, hiding anything the project "
                    "shipped — the app will probably fail to start. Copy your "
                    "data there first, or choose a different folder in step 2.")
        elif info.has_data_dir:
            lines.append("\nThis app reads from a data/ folder — choose where "
                         "that data lives in step 2.")
        else:
            lines.append("\nNo data folder attached. If your dashboard reads "
                         "data files, set that up in step 2 first.")
        self.summary.set("\n".join(lines))

        ready = (info.deps_ok
                 and (not info.has_data_dir or bool(self.shared.data_dir))
                 and self.handle is None)
        self.deploy_btn.configure(state="normal" if ready else "disabled")

    def _deploy(self) -> None:
        if self.shared.info is None:
            return
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        handle = backend.start_deploy(
            self.shared.project_dir,
            data_dir=self.shared.data_dir,
            framework=self.framework_var.get().strip(),
            container_port=self.port_var.get().strip(),
            base_image=self.base_image_var.get().strip())
        self._attach(handle)

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
            self.elapsed.configure(text=f"Working… {self.tailer.elapsed()} elapsed")
            self._tick_id = self.after(1000, self._tick)

    def _finished(self, code: int) -> None:
        if self._tick_id is not None:
            self.after_cancel(self._tick_id)
            self._tick_id = None
        self.handle = None
        self.tailer = None
        self.cancel_btn.configure(state="disabled")
        self.elapsed.configure(text="")
        self._refresh()
        self.on_deployed()

        if code == 0:
            url = backend.container_status().get("url", "")
            # Not "success": run_smoke_test only proves the app answered.
            # Shiny and Streamlit show script errors in the browser and
            # still return 200, so looking at it is the only real check.
            body = ("Your dashboard is published"
                    + (f" at:\n{url}" if url else ".")
                    + "\n\nOpen it and check it looks the way you expect.")
            if url and messagebox.askyesno("Published", body + "\n\nOpen it now?"):
                backend.open_in_browser(url)
            elif not url:
                messagebox.showinfo("Published", body)
        elif code == runner.KILLED_EXIT_CODE:
            messagebox.showinfo("Stopped", "The build was stopped.")
        else:
            messagebox.showerror(
                "It didn't finish",
                "Something went wrong while publishing.\n\nThe reason is at "
                "the end of the progress log. The full log was saved in:\n"
                f"{backend.LOG_DIR}")

    def _cancel(self) -> None:
        if self.handle and messagebox.askyesno(
                "Stop?", "Stop building? You'll have to start again."):
            backend.cancel(self.handle)

    def _reattach(self) -> None:
        existing = backend.find_running_build()
        if existing is not None:
            self.summary.set("A publish started earlier is still running — "
                             "picking it back up.")
            self._attach(existing)


# --------------------------------------------------------------------------
# Tab 4 — manage
# --------------------------------------------------------------------------
class ManageTab(ttk.Frame):
    def __init__(self, parent, shared: Shared, deploy_tab: DeployTab) -> None:
        super().__init__(parent, padding=PAD)
        self.shared = shared
        self.deploy_tab = deploy_tab
        self.columnconfigure(0, weight=1)
        self.rowconfigure(3, weight=1)

        self.status = tk.StringVar(value="Checking…")
        ttk.Label(self, textvariable=self.status, wraplength=680,
                  justify="left", font=("TkDefaultFont", 11)).grid(
            row=0, column=0, sticky="w")

        row = ttk.Frame(self)
        row.grid(row=1, column=0, sticky="ew", pady=(PAD, 0))
        self.open_btn = ttk.Button(row, text="Open dashboard", command=self._open)
        self.open_btn.grid(row=0, column=0)
        ttk.Button(row, text="Refresh", command=self.refresh).grid(row=0, column=1, padx=PAD)
        ttk.Button(row, text="Restart", command=lambda: self._do("restart")).grid(row=0, column=2)
        ttk.Button(row, text="Stop", command=lambda: self._do("stop")).grid(row=0, column=3, padx=PAD)
        ttk.Button(row, text="Publish again", command=self._redeploy).grid(row=0, column=4)

        # The detail behind the headline. Collapsed into a plain grid of
        # label/value pairs rather than a table widget: there are only a
        # handful of facts, and they are the ones to read out over email when
        # asking for help.
        detail_box = ttk.LabelFrame(self, text="Details", padding=PAD)
        detail_box.grid(row=2, column=0, sticky="ew", pady=(PAD, 0))
        detail_box.columnconfigure(1, weight=1)
        self._detail_vars: dict[str, tk.StringVar] = {}
        for i, (key, caption) in enumerate(self.DETAIL_ROWS):
            ttk.Label(detail_box, text=caption).grid(row=i, column=0, sticky="w", padx=(0, PAD))
            var = tk.StringVar(value="—")
            self._detail_vars[key] = var
            ttk.Label(detail_box, textvariable=var, font=("TkFixedFont", 9)).grid(
                row=i, column=1, sticky="w")

        log_box = ttk.LabelFrame(self, text="Recent output from your app", padding=PAD)
        log_box.grid(row=3, column=0, sticky="nsew", pady=(PAD, 0))
        log_box.columnconfigure(0, weight=1)
        log_box.rowconfigure(0, weight=1)
        self.logs = tk.Text(log_box, height=12, wrap="none", state="disabled",
                            font=("TkFixedFont", 9))
        self.logs.grid(row=0, column=0, sticky="nsew")
        bar = ttk.Scrollbar(log_box, orient="vertical", command=self.logs.yview)
        bar.grid(row=0, column=1, sticky="ns")
        self.logs.configure(yscrollcommand=bar.set)
        ttk.Button(log_box, text="Show latest", command=self._show_logs).grid(
            row=1, column=0, sticky="w", pady=(PAD, 0))

        self.url = ""
        self._health_queue: queue.Queue[dict[str, str]] = queue.Queue()
        self._health_pending = False
        self.refresh()

    # Porcelain key -> caption. Ordered as someone would read down them when
    # working out what is wrong: what is running, then how it is served, then
    # what it is consuming.
    DETAIL_ROWS = (
        ("state", "Container"),
        ("docker_health", "Health check"),
        ("restarts", "Restarts"),
        ("serving", "Served by"),
        ("probes", "Responding"),
        ("autoheal", "Auto-restart"),
        ("mem_usage", "Memory"),
        ("root_disk", "Disk"),
    )

    def refresh(self) -> None:
        """Kick off a health check on a worker thread.

        Not run inline: ``manage.sh health`` makes several HTTP probes and
        samples ``docker stats``, and each probe waits out its own timeout
        when something is wedged — which is exactly when a researcher presses
        Refresh. Inline, that would freeze the window for the better part of a
        minute and look like the GUI itself had hung.
        """
        if self._health_pending:
            return
        self._health_pending = True
        self.status.set("Checking…")

        def work() -> None:
            try:
                result = backend.health()
            except Exception as exc:      # never let a worker thread die silently
                result = {"verdict": "", "detail": str(exc)}
            self._health_queue.put(result)

        threading.Thread(target=work, daemon=True).start()
        self.after(150, self._drain_health)

    def _drain_health(self) -> None:
        """Apply a finished health check. UI thread only — see runner.py."""
        try:
            health = self._health_queue.get_nowait()
        except queue.Empty:
            self.after(150, self._drain_health)
            return

        self._health_pending = False
        if not health:
            # manage.sh unavailable or it failed outright. Fall back to the
            # simpler status call rather than showing nothing.
            self._apply_status_fallback()
            return

        verdict = health.get("verdict", "")
        detail = health.get("detail", "")
        self.url = health.get("url", "") if verdict in ("ok", "unhealthy") else ""

        headline = backend.HEALTH_HEADLINES.get(verdict, "")
        if verdict == "ok":
            self.status.set(f"{headline} Your dashboard is at\n{self.url}")
        elif verdict == "not-deployed":
            self.status.set("Nothing is published yet. Use steps 1–3 to publish "
                            "your dashboard.")
        elif verdict == "stopped":
            self.status.set("Your dashboard is stopped. It will stay stopped, "
                            "including after a reboot, until you publish again.")
        elif headline:
            self.status.set(f"{headline}\n{detail}")
        else:
            self.status.set(detail or "Could not work out the current state.")

        proxied = health.get("proxy_enabled") == "1"
        serving = (f"nginx on port 80 → app on {health.get('app_bind', '?')}"
                   if proxied else
                   f"app directly on {health.get('app_bind', '?')} (no web server in front)")
        # HTTP codes as-is: they are the single most useful thing to quote
        # when asking for help, and 000 (nothing answered at all) is a
        # meaningfully different symptom from 502.
        probes = f"app {health.get('app_http', '?')}"
        if proxied:
            probes += (f" · nginx {health.get('nginx_http', '?')}"
                       f" · public {health.get('public_http', '?')}")

        values = dict(health)
        values["serving"] = serving
        values["probes"] = probes
        for key, var in self._detail_vars.items():
            var.set(values.get(key) or "—")

        self.open_btn.configure(state="normal" if self.url else "disabled")

    def _apply_status_fallback(self) -> None:
        """The pre-health display, for when manage.sh health isn't usable."""
        st = backend.container_status()
        state, health = st.get("state", "absent"), st.get("health", "unknown")
        self.url = st.get("url", "")
        if state == "absent":
            self.status.set("Nothing is published yet. Use steps 1–3 to publish "
                            "your dashboard.")
        elif health == "responding":
            self.status.set(f"Your dashboard is running and answering at\n{self.url}")
        elif state == "running":
            self.status.set(
                "The dashboard is running but not answering yet. If it just "
                "started, give it a moment and press Refresh. If this persists, "
                "look at the output below.")
        else:
            self.status.set(
                f"The dashboard is stopped ({state}). It will stay stopped, "
                "including after a reboot, until you publish again.")
        self.open_btn.configure(state="normal" if self.url else "disabled")

    def _open(self) -> None:
        if self.url:
            backend.open_in_browser(self.url)

    def _do(self, action: str) -> None:
        if action == "stop" and not messagebox.askyesno(
                "Stop the dashboard?",
                "Your dashboard will go offline and stay offline until you "
                "publish again — including after a reboot. Continue?"):
            return
        try:
            out = backend.manage(action)
        except backend.BackendError as exc:
            messagebox.showerror("That didn't work", exc.full_text())
            return
        messagebox.showinfo("Done", out.strip() or f"{action} complete.")
        self.refresh()

    def _show_logs(self) -> None:
        try:
            out = backend.manage("logs")
        except backend.BackendError as exc:
            out = exc.full_text()
        self.logs.configure(state="normal")
        self.logs.delete("1.0", "end")
        self.logs.insert("1.0", out)
        self.logs.see("end")
        self.logs.configure(state="disabled")

    def _redeploy(self) -> None:
        if self.shared.info is None:
            messagebox.showinfo(
                "Nothing selected",
                "Choose your dashboard in step 1 first, then publish from step 3.")
            return
        if messagebox.askyesno(
                "Publish again?",
                "Rebuild and republish from your current code? The running "
                "dashboard stays up until the new one is ready."):
            self.deploy_tab._deploy()


# --------------------------------------------------------------------------
class MainWindow(ttk.Frame):
    def __init__(self, root: tk.Tk) -> None:
        super().__init__(root, padding=PAD)
        self.grid(row=0, column=0, sticky="nsew")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)

        shared = Shared()
        nb = ttk.Notebook(self)
        nb.grid(row=0, column=0, sticky="nsew")

        self.app_tab = AppTab(nb, shared)
        self.data_tab = DataTab(nb, shared)
        self.deploy_tab = DeployTab(nb, shared)
        self.manage_tab = ManageTab(nb, shared, self.deploy_tab)
        self.deploy_tab.on_deployed = self.manage_tab.refresh

        nb.add(self.app_tab, text="1. Your app")
        nb.add(self.data_tab, text="2. Your data")
        nb.add(self.deploy_tab, text="3. Publish")
        nb.add(self.manage_tab, text="4. Manage")
        self.notebook = nb
        self.shared = shared
