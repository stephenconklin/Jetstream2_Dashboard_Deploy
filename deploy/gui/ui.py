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
import time
import tkinter as tk
from dataclasses import dataclass, field
from tkinter import filedialog, messagebox, ttk

import backend
import progress
import runner
import transfer
import volumes

PAD = 10

# Secondary text: hints, examples, captions. Dark enough to read on Azure
# light's white, clearly quieter than body text.
MUTED_FG = "#5c5c5c"

# One colour per progress level (see progress.py). Always shown with the
# level's symbol and a sentence, never alone, so nothing depends on telling
# the colours apart. Each is dark enough to read as text on white.
LEVEL_COLOURS = {
    progress.TODO: "#757575",
    progress.ATTENTION: "#a15c00",
    progress.WORKING: "#1565c0",
    progress.DONE: "#2e7d32",
    progress.FAILED: "#c62828",
}


def _init_styles() -> None:
    """Name the few appearance variants this window uses.

    Everything here exists because an inline ``foreground=``/``font=`` option
    on a widget overrides the active theme outright — so hardcoding them is
    the one thing in this file that a theme change cannot reach. Naming them
    instead keeps the whole window's appearance settable from one place.

    Deliberately does not set colours the theme already handles. Called once
    from MainWindow, which is the only funnel every widget is built through.
    """
    style = ttk.Style()
    style.configure("Muted.TLabel", foreground=MUTED_FG)
    style.configure("Title.TLabel", font=("TkDefaultFont", 12, "bold"))
    style.configure("Subtitle.TLabel", font=("TkDefaultFont", 11))
    for level, colour in LEVEL_COLOURS.items():
        style.configure(f"{level}.Status.TLabel", foreground=colour)
    style.configure("Live.TLabel", font=("TkDefaultFont", 11, "bold"))


@dataclass
class Shared:
    """State the tabs pass between each other."""

    project_dir: str = ""
    # The main file the researcher picked by hand, or "" to let the shell's
    # detection decide. Passed to both the dry-run and the deploy, so the
    # two can never disagree about which file is the app.
    entry_file: str = ""
    # Where the data comes from: "bundle" (published inside the app with the
    # code), "mount" (data_dir, mounted at run time), or "" until the data
    # tab has picked a default for the current project.
    data_mode: str = ""
    # The folder name the app's code reads data from; data_dir is mounted
    # there. Also passed to every dry-run, since it decides has_data_dir.
    data_subdir: str = "data"
    data_dir: str = ""
    info: backend.ProjectInfo | None = None
    # What's actually serving (refreshed by MainWindow's poll), and the state
    # of a publish started from this window: "", building, done or failed.
    live: progress.Live = field(default_factory=progress.Live)
    build: str = ""
    # Every visual cue reads from this. Recomputed *before* any listener
    # runs, so no listener can see a plan that's one change out of date.
    plan: progress.Plan = field(default_factory=progress.Plan)
    listeners: list = field(default_factory=list)

    def changed(self) -> None:
        if self.info is not None and not self.data_mode:
            # Publish the data with the app — it needs nothing from the
            # researcher at all — unless the folder is too big to, or the code
            # reads a data folder the project doesn't have (its data lives
            # elsewhere, so publishing it as-is would start an app with none).
            self.data_mode = ("mount" if self.info.too_big_to_bundle
                              or self.info.reads_missing_data_dir else "bundle")
        self.plan = progress.assess(self.draft(), self.live, self.build)
        for fn in self.listeners:
            fn()

    def draft(self) -> progress.Draft:
        mounting = self.data_mode == "mount" and bool(self.data_dir)
        return progress.Draft(
            project_dir=self.project_dir, info=self.info,
            data_mode=self.data_mode, data_dir=self.data_dir,
            data_subdir=self.data_subdir,
            # The one I/O-backed fact; cheap, since it stops at the first file.
            data_dir_empty=mounting and _folder_is_empty(self.data_dir))


def _friendly_time(stamp: str) -> str:
    """Render the deploy label's UTC timestamp in the instance's local time.

    Falls back to the raw string rather than guessing: the label is written by
    the shell, and a value this can't parse is more useful shown verbatim than
    silently dropped.
    """
    if not stamp:
        return ""
    try:
        # calendar.timegm, not time.mktime minus time.timezone: the latter
        # uses the zone's standard offset and so lands an hour out for half
        # the year, which makes "published at" disagree with the clock the
        # researcher pressed the button by.
        import calendar
        local = time.localtime(calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")))
        return time.strftime("%d %b %Y at %H:%M", local)
    except (ValueError, OverflowError):
        return stamp


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


class WrapLabel(ttk.Label):
    """A paragraph that wraps to the width its container actually has.

    A fixed ``wraplength`` is in pixels, so the same paragraph that fills a
    small window bunches up in the left half of a large one (or of a remote
    desktop with a bigger font). This re-wraps whenever the container is
    resized. Only for labels that span their container's full width — a
    label sharing its row with a button would wrap underneath it.
    """

    # Room for the frame's own padding and, in a status line, the colour strip.
    RESERVE = 2 * PAD + 12

    def __init__(self, master=None, **kw) -> None:
        super().__init__(master, **kw)
        master.bind("<Configure>", self._fit, add="+")

    def _fit(self, event) -> None:
        # The route panel rebuilds its labels, so a binding can outlive the
        # label it was made for.
        if not self.winfo_exists():
            return
        width = event.width - self.RESERVE
        if width > 200:
            self.configure(wraplength=width)


class StatusLine(ttk.Frame):
    """One sentence with a coloured edge: where a step stands, in words."""

    def __init__(self, parent) -> None:
        super().__init__(parent)
        self.columnconfigure(1, weight=1)
        self.strip = tk.Frame(self, width=5, bg=LEVEL_COLOURS[progress.TODO])
        self.strip.grid(row=0, column=0, sticky="ns", padx=(0, PAD))
        self.text = tk.StringVar()
        self.label = WrapLabel(self, textvariable=self.text, wraplength=640,
                               justify="left", style="todo.Status.TLabel")
        self.label.grid(row=0, column=1, sticky="w", pady=4)

    def show(self, step: progress.Step) -> None:
        self.strip.configure(bg=LEVEL_COLOURS[step.level])
        self.label.configure(style=f"{step.level}.Status.TLabel")
        self.text.set(f"{step.symbol}  {step.message}")


def _set_subtree_enabled(widget, enabled: bool) -> None:
    """Grey out (or restore) everything inside a frame.

    Text widgets are skipped: every one in this window is a read-only
    display that is kept disabled permanently, and re-enabling it here would
    make it editable.
    """
    for child in widget.winfo_children():
        if isinstance(child, tk.Text):
            continue
        if isinstance(child, ttk.Widget):
            try:
                child.state(["!disabled"] if enabled else ["disabled"])
            except tk.TclError:
                pass
        elif isinstance(child, tk.Listbox):
            child.configure(state="normal" if enabled else "disabled")
        _set_subtree_enabled(child, enabled)


def _has_code_files(path: str) -> bool:
    """Whether a folder has any top-level .R or .py file to choose from."""
    from pathlib import Path
    try:
        return any(p.suffix in (".R", ".r", ".py")
                   for p in Path(path).iterdir() if p.is_file())
    except OSError:
        return False


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
        super().__init__(parent)
        self.shared = shared
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)

        # A fixed stack of controls with no row that wants extra height, so
        # it scrolls rather than clipping — same reasoning as DataTab, and
        # more pressing since the theme pads more than Tk's default did.
        # Tabs 3 and 4 deliberately do NOT do this: both weight their log
        # pane to absorb spare height, which a canvas viewport would take
        # away, freezing the log at its minimum size.
        self._scroll = ScrollableFrame(self)
        self._scroll.grid(row=0, column=0, sticky="nsew")
        body = self._scroll.body
        body.columnconfigure(0, weight=1)

        ttk.Label(body, text="Where is your dashboard's code?",
                  style="Title.TLabel").grid(row=0, column=0, sticky="w")

        self.choice = tk.StringVar(value="browse")
        box = ttk.Frame(body)
        box.grid(row=1, column=0, sticky="ew", pady=(PAD, 0))
        box.columnconfigure(0, weight=1)

        for i, (key, label) in enumerate([
            ("browse", "It's already on this server"),
            ("git", "Download it from GitHub (or another Git address)"),
            ("zip", "I have a .zip file"),
        ]):
            ttk.Radiobutton(box, text=label, value=key, variable=self.choice,
                            command=self._switch).grid(row=i, column=0, sticky="w")

        self.panel = ttk.Frame(body)
        self.panel.grid(row=2, column=0, sticky="ew", pady=(PAD, 0))
        self.panel.columnconfigure(1, weight=1)

        self.path_var = tk.StringVar()
        self.git_var = tk.StringVar()
        self.zip_var = tk.StringVar()
        self.result = tk.StringVar(value="")

        WrapLabel(body, textvariable=self.result, wraplength=620,
                  justify="left").grid(row=3, column=0, sticky="w", pady=(PAD, 0))

        # -- which file is the app. Researchers name their main file after
        # their project, not app.R, and a folder often holds several
        # scripts — so the detected choice is shown and can be changed, and
        # an ambiguous folder asks rather than failing.
        self.entry_box = ttk.LabelFrame(body, text="Your dashboard's main file",
                                        padding=PAD)
        self.entry_box.columnconfigure(1, weight=1)
        ttk.Label(self.entry_box, text="Main file:").grid(row=0, column=0, sticky="w")
        self.entry_var = tk.StringVar()
        self.entry_combo = ttk.Combobox(self.entry_box, textvariable=self.entry_var,
                                        state="readonly", width=36)
        self.entry_combo.grid(row=0, column=1, sticky="w", padx=PAD)
        self.entry_combo.bind("<<ComboboxSelected>>", self._entry_picked)
        ttk.Button(self.entry_box, text="Choose another file…",
                   command=self._choose_entry).grid(row=0, column=2)
        self.entry_note = tk.StringVar()
        WrapLabel(self.entry_box, textvariable=self.entry_note, wraplength=640,
                  justify="left").grid(row=1, column=0, columnspan=3,
                                       sticky="w", pady=(PAD, 0))

        # -- habits that work on a laptop and break on the server. Advisory:
        # the shell's checks are pattern matches, so this never blocks
        # publishing — it says what to look at if the app misbehaves.
        self.notes_box = ttk.LabelFrame(body, text="Worth checking in your code",
                                        padding=PAD)
        self.notes_box.columnconfigure(0, weight=1)
        WrapLabel(self.notes_box,
                  text="These work on your own computer but usually not on the "
                       "server. They won't stop you publishing, but if your "
                       "dashboard shows an error, start here.",
                  wraplength=640, justify="left").grid(row=0, column=0, sticky="w")
        self.notes_text = tk.Text(self.notes_box, height=6, wrap="word",
                                  state="disabled", font=("TkFixedFont", 10))
        self.notes_text.grid(row=1, column=0, sticky="ew", pady=(PAD, 0))
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
                      style="Muted.TLabel").grid(row=1, column=1, sticky="w", padx=PAD)
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

    def _adopt(self, path: str, entry_file: str = "") -> None:
        path = path.strip()
        if not path:
            return
        # A different project starts its data choices over; re-picking the
        # main file of the same project keeps them.
        new_project = path != self.shared.project_dir
        data_subdir = "data" if new_project else self.shared.data_subdir
        try:
            info = backend.inspect_project(path, entry_file=entry_file,
                                           data_subdir=data_subdir)
        except backend.BackendError as exc:
            if entry_file and self.shared.project_dir == path:
                # A rejected choice of main file. Keep the project as it was
                # and put the dropdown back, rather than forgetting the
                # whole folder over one bad pick.
                messagebox.showerror("That file can't be used", exc.full_text())
                self._show_entry(self.shared.info)
                return
            self.shared.project_dir = ""
            self.shared.entry_file = ""
            self.shared.info = None
            self.shared.changed()
            self.result.set("")
            self.entry_box.grid_remove()
            self.notes_box.grid_remove()
            # Detection found nothing it recognised, but the folder does hold
            # code — most often an app whose main file is shaped unusually.
            # The researcher knows which file they run; let them say so.
            if not entry_file and _has_code_files(path):
                if messagebox.askyesno(
                        "Which file is your dashboard?",
                        exc.full_text() + "\n\nIf you know which file starts "
                        "your dashboard — the one you open and run in RStudio, "
                        "say — you can choose it yourself.\n\nChoose it now?"):
                    self._choose_entry(path)
                return
            messagebox.showerror("This doesn't look like a dashboard yet",
                                 exc.full_text())
            return
        self.shared.entry_file = entry_file
        if new_project:
            self.shared.data_subdir = data_subdir
            self.shared.data_mode = ""
        self._apply(path, info)

    def _entry_picked(self, _event=None) -> None:
        chosen = self.entry_var.get()
        info = self.shared.info
        if info is None or not chosen or chosen == info.entry_file:
            return
        self._adopt(self.shared.project_dir, entry_file=chosen)

    def _choose_entry(self, project_dir: str = "") -> None:
        from pathlib import Path
        project_dir = project_dir or self.shared.project_dir
        if not project_dir:
            messagebox.showinfo("Choose your folder first",
                                "Pick the folder your dashboard is in, above.")
            return
        chosen = filedialog.askopenfilename(
            title="Select the file that runs your dashboard",
            initialdir=project_dir,
            filetypes=[("R or Python files", "*.R *.r *.py"), ("All files", "*")])
        if not chosen:
            return
        if Path(chosen).resolve().parent != Path(project_dir).resolve():
            messagebox.showerror(
                "Choose a file inside your dashboard folder",
                f"The main file has to be directly inside\n{project_dir}\n"
                "— not in a subfolder, and not somewhere else. Your dashboard "
                "is run from that folder.")
            return
        self._adopt(project_dir, entry_file=Path(chosen).name)

    def _show_notes(self, info: backend.ProjectInfo | None) -> None:
        notes = info.code_notes if info is not None else []
        if not notes:
            self.notes_box.grid_remove()
            return
        self.notes_box.grid(row=5, column=0, sticky="ew", pady=(PAD, 0))
        self.notes_text.configure(state="normal", height=min(10, 2 * len(notes) + 1))
        self.notes_text.delete("1.0", "end")
        self.notes_text.insert("1.0", "\n".join(f"• {n}" for n in notes))
        self.notes_text.configure(state="disabled")

    def _show_entry(self, info: backend.ProjectInfo | None) -> None:
        """Fill the main-file row from what the shell reported."""
        if info is None:
            self.entry_box.grid_remove()
            return
        self.entry_box.grid(row=4, column=0, sticky="ew", pady=(PAD, 0))
        candidates = info.candidates
        if info.entry_file and info.entry_file not in candidates:
            candidates.append(info.entry_file)
        self.entry_combo.configure(values=candidates)

        if not info.entry_file and not info.needs_entry_choice:
            # A ui.R/server.R pair or a Shiny .Rmd: run by convention, no
            # single file to choose.
            self.entry_var.set(info.entry_point_desc)
            self.entry_combo.configure(state="disabled")
            self.entry_note.set("")
            return

        self.entry_combo.configure(state="readonly")
        self.entry_var.set(info.entry_file)
        if info.needs_entry_choice:
            self.entry_note.set(
                "More than one file in this folder could be your dashboard. "
                "Pick the one you run to start it.")
        elif info.framework == "r-shiny" and info.entry_file != "app.R":
            self.entry_note.set(
                f"Your main file is called {info.entry_file} rather than app.R. "
                "That's fine: publishing adds a small app.R that runs it. "
                "Nothing in your folder is changed.")
        elif len(candidates) > 1:
            self.entry_note.set("Not the right file? Pick a different one.")
        else:
            self.entry_note.set("")

    def show_restored(self, path: str, info: backend.ProjectInfo, when: str,
                      entry_file: str = "", data_subdir: str = "") -> None:
        """Reopen on the project the running dashboard was published from.

        Worded as *currently published* rather than *selected*, and explicit
        that the folder may have moved on since. The container records where
        it was built from, not a copy of what was in that folder at the time,
        so the two can genuinely differ — and implying otherwise would be the
        same class of overclaim as calling a liveness check a success.
        """
        self.path_var.set(path)
        self.shared.entry_file = entry_file
        self.shared.data_subdir = data_subdir or "data"
        self.shared.data_mode = ""
        self._apply(path, info)
        published = f" on {when}" if when else ""
        self.result.set(
            f"Currently published: the {info.framework} dashboard in {path}"
            f"{published}.\n\n"
            "This is what your instance is serving now. If the code in that "
            "folder has changed since, publishing again in step 3 picks up "
            "those changes.")

    def show_missing(self, path: str) -> None:
        """Explain a published dashboard whose source folder has gone.

        Nothing can be restored in this state, and saying nothing would leave
        the first three tabs blank while tab 4 reports a perfectly healthy
        dashboard — which reads as the application having lost track of it.
        The app itself is fine: the code was baked into the image at build
        time, so it keeps serving regardless of what happened to the folder.
        """
        self.result.set(
            f"Your dashboard is running, but the folder it was published "
            f"from is no longer there:\n{path}\n\n"
            "It keeps running — its code was copied into the image when you "
            "published. But to publish again you'll need to point step 1 at "
            "the code's new location, or download it again.")

    def _apply(self, path: str, info: backend.ProjectInfo) -> None:
        self.shared.project_dir = path
        self.shared.info = info
        self.shared.changed()
        self._show_entry(info)
        self._show_notes(info)
        self.path_var.set(path)
        # The status line above the tab now says what was found; this only
        # holds the occasional longer explanation (restored, folder gone).
        self.result.set("")


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
        WrapLabel(body, textvariable=self.header, wraplength=620,
                  justify="left").grid(row=0, column=0, sticky="w")

        # -- the one question this tab asks. Researchers mostly keep data
        # right next to their code, and that should just work; a storage
        # volume is for data too big to publish with the app.
        mode_box = ttk.LabelFrame(body, text="Where are your dashboard's data files?",
                                  padding=PAD)
        mode_box.grid(row=1, column=0, sticky="ew", pady=(PAD, 0))
        self.mode_var = tk.StringVar(value="bundle")
        ttk.Radiobutton(mode_box, value="bundle", variable=self.mode_var,
                        command=self._mode_changed,
                        text="In my app folder, with the code — publish them along "
                             "with it").grid(row=0, column=0, sticky="w")
        ttk.Radiobutton(mode_box, value="mount", variable=self.mode_var,
                        command=self._mode_changed,
                        text="In a separate folder on this server, such as a storage "
                             "volume (best for large data)").grid(row=1, column=0, sticky="w")

        # -- option 1
        self.bundle_text = tk.StringVar()
        self.bundle_panel = WrapLabel(body, textvariable=self.bundle_text,
                                      wraplength=620, justify="left")

        # -- option 2: everything from here down only applies to a mount.
        self.mount_caption = WrapLabel(
            body, style="Muted.TLabel", wraplength=620, justify="left",
            text="The settings below are only for the second option — data in "
                 "a separate folder on this server.")
        self.mount_frame = mf = ttk.Frame(body)
        mf.columnconfigure(0, weight=1)

        name_box = ttk.LabelFrame(mf, text="What your code calls that folder",
                                  padding=PAD)
        name_box.grid(row=0, column=0, sticky="ew", pady=(PAD, 0))
        name_box.columnconfigure(2, weight=1)
        ttk.Label(name_box, text="Folder name:").grid(row=0, column=0, sticky="w")
        self.subdir_var = tk.StringVar(value="data")
        subdir_entry = ttk.Entry(name_box, textvariable=self.subdir_var, width=18)
        subdir_entry.grid(row=0, column=1, sticky="w", padx=PAD)
        subdir_entry.bind("<Return>", lambda _e: self._apply_subdir())
        subdir_entry.bind("<FocusOut>", lambda _e: self._apply_subdir())
        ttk.Label(name_box,
                  text="The folder your code reads from. If it says "
                       "read.csv(\"data/sites.csv\"), this is data.",
                  style="Muted.TLabel", wraplength=340, justify="left").grid(
            row=0, column=2, sticky="w")

        dest_box = ttk.LabelFrame(mf, text="Where your data lives on this server",
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
        ttk.Label(dest_box, textvariable=self.mapping, style="Muted.TLabel",
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
        route_box = ttk.LabelFrame(mf, text="How to get your data here",
                                   padding=PAD)
        route_box.grid(row=2, column=0, sticky="ew", pady=(PAD, 0))
        route_box.columnconfigure(0, weight=1)

        self.route_var = tk.StringVar(value="cloud")
        self.routes = transfer.build_routes(
            backend.public_ip(), backend.username(), "")
        for i, route in enumerate(self.routes):
            ttk.Radiobutton(route_box, text=route.title, value=route.key,
                            variable=self.route_var,
                            command=self._show_route).grid(row=i, column=0, sticky="w")

        self.route_panel = ttk.Frame(mf)
        self.route_panel.grid(row=3, column=0, sticky="ew", pady=(PAD, 0))
        self.route_panel.columnconfigure(0, weight=1)

        # -- did it arrive?
        check_box = ttk.LabelFrame(mf, text="Check what's arrived", padding=PAD)
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
        """Re-render for the current project. A Shared listener.

        The default data_mode is chosen in Shared.changed(), before any
        listener runs, so this only ever reads it.
        """
        info = self.shared.info
        if info is None:
            self.header.set("Choose your dashboard in step 1 first.")
            self.bundle_panel.grid_remove()
            self.mount_caption.grid_remove()
            self.mount_frame.grid_remove()
            self._update_mapping()
            return

        self.mode_var.set(self.shared.data_mode)
        self.subdir_var.set(self.shared.data_subdir)

        self.header.set(
            "Your dashboard can only read files it can see on this server. "
            "Choose where they are, below. If it doesn't read any data files, "
            "leave this as it is and go on to step 3.")

        # The volume controls stay on screen either way and are greyed out
        # rather than hidden under the first option: researchers can see the
        # second option exists and what it involves, and the layout doesn't
        # jump when they switch.
        bundling = self.shared.data_mode == "bundle"
        if bundling:
            self.bundle_panel.grid(row=2, column=0, sticky="ew", pady=(PAD, 0))
            self.bundle_text.set(self._bundle_summary(info))
            self.mount_caption.grid(row=3, column=0, sticky="w", pady=(PAD, 0))
        else:
            self.bundle_panel.grid_remove()
            self.mount_caption.grid_remove()
        self.mount_frame.grid(row=4, column=0, sticky="ew")
        self._apply_mode_enabled()
        self._update_mapping()

    def _apply_mode_enabled(self) -> None:
        _set_subtree_enabled(self.mount_frame,
                             self.shared.data_mode == "mount")

    def _bundle_summary(self, info: backend.ProjectInfo) -> str:
        size = volumes._human(info.app_kb * 1024)
        lines = [f"Everything in your app folder is published with your "
                 f"dashboard — {size} in all. Your code can keep reading its "
                 "files exactly as it does on your own computer."]
        if info.has_data_dir:
            lines.append(f"That includes your {info.data_subdir}/ folder "
                         f"({volumes._human(info.data_kb * 1024)}).")
        lines.append("\nWhen a data file changes, publish again (step 3) to "
                     "update it.")
        if info.too_big_to_bundle:
            lines.append(
                f"\nWARNING: {size} is too much to publish with the app — every "
                "re-publish copies all of it again. Move your data into one "
                "folder on a storage volume and choose the second option above.")
        return "\n".join(lines)

    def _mode_changed(self) -> None:
        self.shared.data_mode = self.mode_var.get()
        self.shared.changed()

    def _apply_subdir(self) -> None:
        """Re-ask the shell about the project with the new folder name."""
        name = self.subdir_var.get().strip().strip("/")
        if not name or name == self.shared.data_subdir or self.shared.info is None:
            self.subdir_var.set(self.shared.data_subdir)
            return
        try:
            info = backend.inspect_project(self.shared.project_dir,
                                           entry_file=self.shared.entry_file,
                                           data_subdir=name)
        except backend.BackendError as exc:
            messagebox.showerror("That folder name can't be used", exc.full_text())
            self.subdir_var.set(self.shared.data_subdir)
            return
        self.shared.data_subdir = name
        self.shared.info = info
        self.shared.changed()

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

    def show_restored(self, path: str) -> None:
        """Reselect the data folder the running dashboard was published with.

        Matched against the discovered locations so the list highlights it and
        the volume-specific extras (free space, the reboot-persistence offer)
        behave exactly as they would after picking it by hand. A path that
        isn't one of those — a plain folder chosen with "Choose another
        folder…" — is still restored, just without the volume extras.
        """
        if not path:
            return
        self.shared.data_mode = "mount"
        for i, loc in enumerate(self.locations):
            if loc.path == path:
                self.loc_list.selection_clear(0, "end")
                self.loc_list.selection_set(i)
                self._select(loc)
                return
        self.shared.data_dir = path
        self.shared.changed()
        self._update_mapping()
        self._show_route()

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

        WrapLabel(self.route_panel, text=route.blurb, wraplength=620,
                  justify="left").grid(row=0, column=0, sticky="w")
        ttk.Label(self.route_panel, text=f"Best for: {route.best_for}",
                  style="Muted.TLabel").grid(row=1, column=0, sticky="w")

        row = 2
        if route.command:
            _selectable_text(self.route_panel, route.command, height=2).grid(
                row=row, column=0, sticky="ew", pady=(PAD, 0))
            ttk.Label(self.route_panel,
                      text="Select the text above and copy it — then run it on "
                           "your own computer, not here.",
                      style="Muted.TLabel").grid(row=row + 1, column=0, sticky="w")
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
        # Rebuilt widgets start enabled; keep them in step with the mode.
        if hasattr(self, "mount_caption"):
            self._apply_mode_enabled()

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
        WrapLabel(self, textvariable=self.summary, wraplength=620,
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
        self._overrides_project = None
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
                  style="Muted.TLabel", wraplength=560).grid(
            row=2, column=0, columnspan=4, sticky="w", pady=(4, 0))

        actions = ttk.Frame(self)
        actions.grid(row=2, column=0, sticky="ew", pady=(PAD, 0))
        # The one primary action in the whole window, so it gets the theme's
        # accent treatment. Every other button here is secondary by design.
        # Its wording says what pressing it will do — publish, update, or
        # replace a different dashboard — and comes from the shared plan.
        self.deploy_label = tk.StringVar(value="Publish my dashboard")
        self.deploy_btn = ttk.Button(actions, textvariable=self.deploy_label,
                                     command=self._deploy, state="disabled",
                                     style="Accent.TButton")
        self.deploy_btn.grid(row=0, column=0)
        self.cancel_btn = ttk.Button(actions, text="Stop", command=self._cancel,
                                     state="disabled")
        self.cancel_btn.grid(row=0, column=1, padx=PAD)
        self.elapsed = ttk.Label(actions, text="")
        self.elapsed.grid(row=0, column=2, padx=PAD)
        # Why the button is greyed, right beside it. A disabled button with
        # no reason is the most confusing thing a window can show.
        self.reason = tk.StringVar(value="")
        ttk.Label(actions, textvariable=self.reason, style="Muted.TLabel",
                  wraplength=420, justify="left").grid(row=0, column=3, sticky="w")

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
        # The Advanced overrides describe one project. Carried over to the
        # next, an old Python base image chosen to rescue a Dash app made an
        # R dashboard fail with "Rscript: not found".
        if self.shared.project_dir != self._overrides_project:
            self._overrides_project = self.shared.project_dir
            for var in (self.framework_var, self.port_var, self.base_image_var):
                var.set("")

        plan = self.shared.plan
        self.deploy_label.set(plan.publish_label)
        ready = plan.publish_ready and self.handle is None
        self.deploy_btn.configure(state="normal" if ready else "disabled")
        self.reason.set("" if ready or self.handle is not None
                        else plan.publish_reason)

        info = self.shared.info
        if info is None:
            self.summary.set("Choose your dashboard in step 1 first.")
            return

        kind = progress.FRAMEWORK_NAMES.get(info.framework, info.framework)
        lines = [f"The {kind} dashboard in {self.shared.project_dir}."]
        if info.needs_entry_choice:
            lines = ["Several files in your folder could be the dashboard. "
                     "Pick its main file in step 1 first."]
        elif info.entry_file:
            lines.append(f"Main file: {info.entry_file}")
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
        mounting = self.shared.data_mode == "mount"
        if not mounting:
            lines.append(f"\nData: published with the app "
                         f"({volumes._human(info.app_kb * 1024)} in all).")
            if info.too_big_to_bundle:
                lines.append(
                    "  WARNING: that's a lot to publish with the app. Consider "
                    "a storage volume instead (step 2).")
        # Show the mount whenever one is configured, regardless of whether
        # the project ships its own data folder — otherwise a project whose
        # data was moved onto a volume gives no indication that anything is
        # being attached at all.
        elif self.shared.data_dir:
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
        else:
            lines.append("\nYou chose to keep your data in a separate folder — "
                         "pick that folder in step 2.")
        self.summary.set("\n".join(lines))

    def _deploy(self) -> None:
        plan = self.shared.plan
        if self.shared.info is None or not plan.publish_ready:
            return
        if plan.needs_confirm:
            live = self.shared.live
            was = live.project_dir or "a folder it didn't record"
            if not messagebox.askyesno(
                    "Replace the live dashboard?",
                    f"The dashboard that's live now was published from:\n{was}"
                    f"\n\nPublishing will replace it with:\n"
                    f"{self.shared.project_dir}\n\n"
                    "The current one keeps running while the new one is built. "
                    "Once the new one starts, the old one is gone — to bring "
                    "it back you'd publish its folder again.\n\nReplace it?",
                    icon="warning"):
                return
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        mounting = self.shared.data_mode == "mount"
        handle = backend.start_deploy(
            self.shared.project_dir,
            data_dir=self.shared.data_dir if mounting else "",
            data_subdir=self.shared.data_subdir,
            # Only meaningful when the project has its own data folder; the
            # shell needs to be told explicitly rather than asked on a
            # terminal the GUI doesn't have.
            bundle_data=not mounting and self.shared.info.has_data_dir,
            entry_file=self.shared.entry_file,
            framework=self.framework_var.get().strip(),
            container_port=self.port_var.get().strip(),
            base_image=self.base_image_var.get().strip())
        self._attach(handle)

    def _attach(self, handle: backend.RunHandle) -> None:
        self.handle = handle
        self.shared.build = "building"
        self.shared.changed()
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
        self.shared.build = ("done" if code == 0
                             else "" if code == runner.KILLED_EXIT_CODE
                             else "failed")
        self.shared.changed()
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
    # How often the tab re-checks itself while the researcher is looking at
    # it. Slow enough that the probes never queue up behind each other (a
    # wedged app makes each health check wait out its own timeouts), fast
    # enough that "it just came back" is visible without pressing anything.
    AUTO_REFRESH_MS = 30_000

    def __init__(self, parent, shared: Shared, deploy_tab: DeployTab) -> None:
        super().__init__(parent, padding=PAD)
        self.shared = shared
        self.deploy_tab = deploy_tab
        self.columnconfigure(0, weight=1)
        # Row 5 is the log box — the only thing that should absorb extra
        # height when the window is resized.
        self.rowconfigure(5, weight=1)

        self.status = tk.StringVar(value="Checking…")
        WrapLabel(self, textvariable=self.status, wraplength=620,
                  justify="left", style="Subtitle.TLabel").grid(
            row=0, column=0, sticky="w")

        row = ttk.Frame(self)
        row.grid(row=1, column=0, sticky="ew", pady=(PAD, 0))
        self.open_btn = ttk.Button(row, text="Open dashboard", command=self._open)
        self.open_btn.grid(row=0, column=0)
        ttk.Button(row, text="Refresh", command=self.refresh).grid(row=0, column=1, padx=PAD)
        # Label switches to "Start" when the container is stopped: `docker
        # restart` starts a stopped container perfectly well, but a button
        # offering to "restart" something a researcher just stopped reads as
        # though it will do nothing.
        self.restart_label = tk.StringVar(value="Restart")
        self.restart_btn = ttk.Button(row, textvariable=self.restart_label,
                                      command=lambda: self._do("restart"))
        self.restart_btn.grid(row=0, column=2)
        self.stop_btn = ttk.Button(row, text="Stop", command=lambda: self._do("stop"))
        self.stop_btn.grid(row=0, column=3, padx=PAD)
        self.republish_btn = ttk.Button(row, text="Publish again",
                                        command=self._redeploy)
        self.republish_btn.grid(row=0, column=4)
        shared.listeners.append(self._apply_plan)

        # Second row: the things that are occasionally needed rather than
        # routinely, kept off the primary row so it stays readable.
        row2 = ttk.Frame(self)
        row2.grid(row=2, column=0, sticky="ew", pady=(6, 0))
        self.auto_refresh = tk.BooleanVar(value=True)
        ttk.Checkbutton(row2, text="Keep checking automatically",
                        variable=self.auto_refresh,
                        command=self._auto_toggled).grid(row=0, column=0)
        ttk.Button(row2, text="Save a report to send for help",
                   command=self._save_report).grid(row=0, column=1, padx=PAD)
        self.checked_at = tk.StringVar(value="")
        ttk.Label(row2, textvariable=self.checked_at,
                  style="Muted.TLabel").grid(row=0, column=2, sticky="w")

        # The detail behind the headline. Collapsed into a plain grid of
        # label/value pairs rather than a table widget: there are only a
        # handful of facts, and they are the ones to read out over email when
        # asking for help.
        detail_box = ttk.LabelFrame(self, text="Details", padding=PAD)
        detail_box.grid(row=3, column=0, sticky="ew", pady=(PAD, 0))
        detail_box.columnconfigure(1, weight=1)
        self._detail_vars: dict[str, tk.StringVar] = {}
        for i, (key, caption) in enumerate(self.DETAIL_ROWS):
            ttk.Label(detail_box, text=caption).grid(row=i, column=0, sticky="w", padx=(0, PAD))
            var = tk.StringVar(value="—")
            self._detail_vars[key] = var
            ttk.Label(detail_box, textvariable=var, font=("TkFixedFont", 9)).grid(
                row=i, column=1, sticky="w")

        # Storage. Its own box rather than another Details row because it is
        # the one fact here that a researcher can act on directly, and the
        # action belongs next to the number.
        disk_box = ttk.LabelFrame(self, text="Storage", padding=PAD)
        disk_box.grid(row=4, column=0, sticky="ew", pady=(PAD, 0))
        disk_box.columnconfigure(0, weight=1)
        self.disk_summary = tk.StringVar(value="Checking…")
        ttk.Label(disk_box, textvariable=self.disk_summary, wraplength=560,
                  justify="left").grid(row=0, column=0, sticky="w")
        self.cleanup_btn = ttk.Button(disk_box, text="Free up space",
                                      command=self._cleanup)
        self.cleanup_btn.grid(row=0, column=1, sticky="e", padx=(PAD, 0))

        log_box = ttk.LabelFrame(self, text="Recent output from your app", padding=PAD)
        log_box.grid(row=5, column=0, sticky="nsew", pady=(PAD, 0))
        log_box.columnconfigure(0, weight=1)
        log_box.rowconfigure(0, weight=1)
        self.logs = tk.Text(log_box, height=12, wrap="none", state="disabled",
                            font=("TkFixedFont", 9))
        self.logs.grid(row=0, column=0, sticky="nsew")
        bar = ttk.Scrollbar(log_box, orient="vertical", command=self.logs.yview)
        bar.grid(row=0, column=1, sticky="ns")
        self.logs.configure(yscrollcommand=bar.set)
        log_buttons = ttk.Frame(log_box)
        log_buttons.grid(row=1, column=0, sticky="w", pady=(PAD, 0))
        ttk.Button(log_buttons, text="Show latest", command=self._show_logs).grid(row=0, column=0)
        ttk.Button(log_buttons, text="Save to a file…", command=self._save_logs).grid(
            row=0, column=1, padx=PAD)

        self.url = ""
        # One queue carrying both probes: they are gathered by a single worker
        # so the tab can never render a health verdict and a disk figure taken
        # at meaningfully different times.
        self._health_queue: queue.Queue[dict] = queue.Queue()
        self._health_pending = False
        self._auto_job: str | None = None
        self.refresh()
        self._schedule_auto()

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

    def refresh(self, quiet: bool = False) -> None:
        """Kick off a health and storage check on a worker thread.

        Not run inline: ``manage.sh health`` makes several HTTP probes and
        samples ``docker stats``, and each probe waits out its own timeout
        when something is wedged — which is exactly when a researcher presses
        Refresh. Inline, that would freeze the window for the better part of a
        minute and look like the GUI itself had hung.

        ``quiet`` is for the automatic poll: it leaves the previous reading on
        screen instead of blanking it to "Checking…" every 30 seconds, which
        otherwise makes a perfectly healthy dashboard look like it is
        constantly being re-diagnosed.
        """
        if self._health_pending:
            return
        self._health_pending = True
        if not quiet:
            self.status.set("Checking…")

        def work() -> None:
            payload: dict = {}
            try:
                payload["health"] = backend.health()
            except Exception as exc:      # never let a worker thread die silently
                payload["health"] = {"verdict": "", "detail": str(exc)}
            try:
                payload["disk"] = backend.disk()
            except Exception:
                # Storage is secondary. A failure here must not cost the
                # researcher the health verdict, which is the reason they
                # opened this tab.
                payload["disk"] = {}
            self._health_queue.put(payload)

        threading.Thread(target=work, daemon=True).start()
        self.after(150, self._drain_health)

    def _schedule_auto(self) -> None:
        """Queue the next automatic poll, replacing any already queued."""
        if self._auto_job is not None:
            self.after_cancel(self._auto_job)
        self._auto_job = self.after(self.AUTO_REFRESH_MS, self._auto_tick)

    def _auto_tick(self) -> None:
        """The periodic check.

        Skipped entirely when this tab isn't the one on screen: the probes
        cost a second or two of a wedged app's timeouts, and there is no
        reason to spend that on a tab nobody is looking at. The timer keeps
        running either way, so switching back to this tab shows a current
        reading within one interval.
        """
        if self.auto_refresh.get() and self.winfo_ismapped():
            self.refresh(quiet=True)
        self._schedule_auto()

    def _auto_toggled(self) -> None:
        if self.auto_refresh.get():
            self.refresh(quiet=True)
            self._schedule_auto()
        elif self._auto_job is not None:
            self.after_cancel(self._auto_job)
            self._auto_job = None

    def _drain_health(self) -> None:
        """Apply a finished check. UI thread only — see runner.py."""
        try:
            payload = self._health_queue.get_nowait()
        except queue.Empty:
            self.after(150, self._drain_health)
            return

        self._health_pending = False
        health = payload.get("health") or {}
        self._apply_disk(payload.get("disk") or {})
        self.checked_at.set(f"checked {time.strftime('%H:%M:%S')}")
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

        self.restart_label.set(
            "Start" if health.get("state") in ("exited", "created", "paused") else "Restart")
        self.open_btn.configure(state="normal" if self.url else "disabled")
        self._apply_container_state(health.get("state", ""))

    def _apply_disk(self, disk: dict[str, str]) -> None:
        """Render the storage line. UI thread only.

        The wording is the point of this panel. "9GB free" means nothing to
        someone who has never watched a build run out of it, so a low reading
        says what it will cost them and what to press.
        """
        if not disk:
            self.disk_summary.set("Storage information isn't available.")
            self.cleanup_btn.configure(state="disabled")
            return

        summary = disk.get("root_summary") or "unknown"
        reclaimable = disk.get("cache_reclaimable") or ""
        images_reclaimable = disk.get("images_reclaimable") or ""
        app_size = disk.get("app_image_size") or ""

        line = f"Disk: {summary}."
        if app_size:
            line += f"  Your dashboard's image is {app_size}."
        if reclaimable or images_reclaimable:
            line += (f"\nCan be freed up: {images_reclaimable or '0B'} of old layers, "
                     f"{reclaimable or '0B'} of build cache.")

        if disk.get("low_disk") == "1":
            threshold = disk.get("low_disk_threshold_gb", "15")
            line += (f"\n\nThis is tight — a large build wants more than {threshold}GB and "
                     "can fail partway through with a confusing error. Freeing up space "
                     "now is worthwhile.")
        self.disk_summary.set(line)
        self.cleanup_btn.configure(state="normal")

    def _cleanup(self) -> None:
        """Reclaim disk space, on a worker thread with the button disabled.

        Pruning a large build cache is disk-bound and can take minutes, so
        this cannot run inline. The confirmation spells out the one real
        consequence — a slower next publish — rather than asking a researcher
        to reason about what a dangling layer is.
        """
        if not messagebox.askyesno(
                "Free up space?",
                "This removes leftover pieces of previous builds and the build "
                "cache.\n\nYour dashboard keeps running and is not affected. The "
                "next time you publish will be slower, because those pieces have "
                "to be rebuilt.\n\nContinue?"):
            return

        self.cleanup_btn.configure(state="disabled")
        self.disk_summary.set("Freeing up space… this can take a few minutes.")
        result_queue: queue.Queue[dict] = queue.Queue()

        def work() -> None:
            try:
                result_queue.put({"ok": backend.cleanup()})
            except backend.BackendError as exc:
                result_queue.put({"error": exc.full_text()})
            except Exception as exc:
                result_queue.put({"error": str(exc)})

        threading.Thread(target=work, daemon=True).start()

        def drain() -> None:
            try:
                outcome = result_queue.get_nowait()
            except queue.Empty:
                self.after(200, drain)
                return
            self.cleanup_btn.configure(state="normal")
            if "error" in outcome:
                messagebox.showerror("That didn't work", outcome["error"])
            else:
                freed = outcome["ok"].get("freed_gb", "")
                summary = outcome["ok"].get("root_summary", "")
                if freed and freed != "0":
                    messagebox.showinfo(
                        "Space freed",
                        f"Reclaimed about {freed}GB.\n\nThe disk is now {summary}.")
                else:
                    messagebox.showinfo(
                        "Nothing left to free",
                        "There was nothing significant to clean up.\n\n"
                        f"The disk is {summary}.")
            self.refresh()

        self.after(200, drain)

    def _save_report(self) -> None:
        """Write the diagnostic report and show where it went."""
        try:
            path = backend.save_report()
        except backend.BackendError as exc:
            messagebox.showerror("That didn't work", exc.full_text())
            return
        if messagebox.askyesno(
                "Report saved",
                f"Saved to:\n{path}\n\nAttach this file to an email when asking "
                "for help — it has your dashboard's status, recent output, and "
                "how much space is left.\n\nOpen the folder now?"):
            backend.open_folder(str(path.parent))

    def _save_logs(self) -> None:
        """Write the app's recent output to a file the researcher chooses."""
        try:
            out = backend.manage("logs")
        except backend.BackendError as exc:
            messagebox.showerror("That didn't work", exc.full_text())
            return
        path = filedialog.asksaveasfilename(
            title="Save your app's output",
            defaultextension=".txt",
            initialfile=f"dashboard-log-{time.strftime('%Y%m%d-%H%M%S')}.txt")
        if not path:
            return
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(out)
        except OSError as exc:
            messagebox.showerror("Could not save", str(exc))
            return
        messagebox.showinfo("Saved", f"Your app's output was saved to:\n{path}")

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
        self.restart_label.set(
            "Start" if state in ("exited", "created", "paused") else "Restart")
        self.open_btn.configure(state="normal" if self.url else "disabled")
        self._apply_container_state(state)

    def _apply_container_state(self, state: str) -> None:
        """Grey out what can't apply: nothing to restart or stop if there's
        no dashboard, and nothing to stop if it's already stopped."""
        exists = state not in ("", "absent")
        self.restart_btn.configure(state="normal" if exists else "disabled")
        self.stop_btn.configure(
            state="normal" if state == "running" else "disabled")

    def _apply_plan(self) -> None:
        plan = self.shared.plan
        self.republish_btn.configure(
            text=plan.publish_label if plan.publish_ready else "Publish again",
            state="normal" if plan.publish_ready else "disabled")

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
        if self.shared.plan.needs_confirm:
            # Publishing a different project: the publish tab's own
            # confirmation names both folders, which says more than this one.
            self.deploy_tab._deploy()
            return
        if messagebox.askyesno(
                "Publish again?",
                "Rebuild and republish from your current code? The running "
                "dashboard stays up until the new one is ready."):
            self.deploy_tab._deploy()


# --------------------------------------------------------------------------
class MainWindow(ttk.Frame):
    def __init__(self, root: tk.Tk) -> None:
        # Before any widget is built: a ttk style is read when a widget is
        # created, not re-read afterwards.
        _init_styles()
        super().__init__(root, padding=PAD)
        self.grid(row=0, column=0, sticky="nsew")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)
        # Row 2 (the notebook, below) is the only row that grows.

        shared = Shared()
        self.shared = shared

        # -- what's live, above everything: it's the one fact that doesn't
        # belong to any single step, and the one a researcher most needs to
        # be sure of while preparing a change.
        self.rowconfigure(2, weight=1)
        live = ttk.Frame(self)
        live.grid(row=0, column=0, sticky="ew")
        live.columnconfigure(1, weight=1)
        self.live_strip = tk.Frame(live, width=6, bg=LEVEL_COLOURS[progress.TODO])
        self.live_strip.grid(row=0, column=0, rowspan=2, sticky="ns", padx=(0, PAD))
        self.live_line = tk.StringVar(value="Checking what's live…")
        self.live_label = ttk.Label(live, textvariable=self.live_line,
                                    style="Live.TLabel")
        self.live_label.grid(row=0, column=1, sticky="w")
        self.relation_line = tk.StringVar(value="")
        self.relation_label = ttk.Label(live, textvariable=self.relation_line,
                                        wraplength=540, justify="left")
        self.relation_label.grid(row=1, column=1, sticky="w")
        self.live_open = ttk.Button(live, text="Open dashboard",
                                    command=self._open_live, state="disabled")
        self.live_open.grid(row=0, column=2, rowspan=2, sticky="e")

        # -- the key to the symbols on the tabs and status lines.
        ttk.Label(self, text=progress.LEGEND, style="Muted.TLabel").grid(
            row=1, column=0, sticky="e", pady=(6, 2))

        nb = ttk.Notebook(self)
        nb.grid(row=2, column=0, sticky="nsew")

        # Steps 1-3 are each wrapped in a page: its status line on top, the
        # step itself, and (for 1 and 2) a button to the next step.
        self.status_lines: dict[int, StatusLine] = {}
        self.next_buttons: dict[int, ttk.Button] = {}
        pages = []
        for index in (progress.APP, progress.DATA, progress.PUBLISH):
            page = ttk.Frame(nb, padding=(0, PAD, 0, 0))
            page.columnconfigure(0, weight=1)
            page.rowconfigure(1, weight=1)
            line = StatusLine(page)
            line.grid(row=0, column=0, sticky="ew", padx=PAD)
            self.status_lines[index] = line
            pages.append(page)

        self.app_tab = AppTab(pages[0], shared)
        self.data_tab = DataTab(pages[1], shared)
        self.deploy_tab = DeployTab(pages[2], shared)
        for page, tab in zip(pages, (self.app_tab, self.data_tab, self.deploy_tab)):
            tab.grid(row=1, column=0, sticky="nsew")
        for index, target, text in ((progress.APP, progress.DATA, "Next: Your data  →"),
                                    (progress.DATA, progress.PUBLISH, "Next: Publish  →")):
            btn = ttk.Button(pages[index], text=text,
                             command=lambda t=target: self.notebook.select(t))
            btn.grid(row=2, column=0, sticky="e", padx=PAD, pady=(0, PAD))
            self.next_buttons[index] = btn

        self.manage_tab = ManageTab(nb, shared, self.deploy_tab)
        self.deploy_tab.on_deployed = self._after_deploy

        self.tab_names = ("1. Your app", "2. Your data", "3. Publish", "4. Manage")
        for page in (*pages, self.manage_tab):
            nb.add(page, text="")
        self.notebook = nb

        shared.listeners.append(self._apply_plan)
        self._live_queue: queue.Queue[progress.Live] = queue.Queue()
        self._live_pending = False
        shared.changed()
        self.refresh_live()
        self._schedule_live()

        self._restore_queue: queue.Queue[dict] = queue.Queue()
        self._restore_from_running_dashboard()

    def _restore_from_running_dashboard(self) -> None:
        """Reopen tabs 1-3 on whatever is currently published, if anything.

        Without this the window comes back blank after every restart, even
        while a dashboard of the researcher's is serving — so the application
        appears to have forgotten something the instance plainly still knows.

        Two subprocess calls (``manage.sh status``, then a ``--dry-run`` of the
        recorded folder), so it runs on a worker thread: at startup on a busy
        instance those together take long enough to be visible as a frozen
        window, which is the worst possible first impression.

        Failures here are silent by design. This is a convenience restoring
        state the researcher can always re-enter by hand, and an error dialog
        on startup — for a project folder that has since been edited, say —
        would be alarming out of proportion to what was lost.
        """
        def work() -> None:
            result: dict = {}
            try:
                dep = backend.deployment()
                result["deployment"] = dep
                if dep.can_restore:
                    # Reopen on the main file that was published, falling
                    # back to plain detection if that file has since been
                    # renamed or removed.
                    try:
                        result["info"] = backend.inspect_project(
                            dep.project_dir, entry_file=dep.entry_file,
                            data_subdir=dep.data_subdir)
                        result["entry_file"] = dep.entry_file
                    except backend.BackendError:
                        result["info"] = backend.inspect_project(
                            dep.project_dir, data_subdir=dep.data_subdir)
            except Exception:
                pass
            self._restore_queue.put(result)

        threading.Thread(target=work, daemon=True).start()
        self.after(200, self._drain_restore)

    # -- the live bar and the step cues -----------------------------------
    LIVE_REFRESH_MS = 30_000

    def _apply_plan(self) -> None:
        """Push the shared plan into every cue the window owns."""
        plan = self.shared.plan
        live = self.shared.live
        for index, name in enumerate(self.tab_names):
            if index in plan.steps:
                symbol = plan.steps[index].symbol
            else:  # Manage: how the live dashboard is doing
                symbol = progress.SYMBOLS[plan.live_level]
            self.notebook.tab(index, text=f" {symbol} {name} ",
                              state="normal" if index in plan.unlocked else "disabled")
        for index, line in self.status_lines.items():
            line.show(plan.steps[index])
        for index, btn in self.next_buttons.items():
            done = plan.steps[index].level == progress.DONE or (
                not plan.steps[index].blocking)
            btn.configure(state="normal" if done and (index + 1) in plan.unlocked
                          else "disabled")

        self.live_strip.configure(bg=LEVEL_COLOURS[plan.live_level])
        self.live_label.configure(foreground=LEVEL_COLOURS[plan.live_level])
        self.live_line.set(f"{progress.SYMBOLS[plan.live_level]}  {plan.live_line}")
        self.relation_line.set(plan.relation_line)
        # Replacing a different dashboard is the one irreversible thing here,
        # so say it in the warning colour, not body text.
        self.relation_label.configure(
            style="attention.Status.TLabel" if plan.needs_confirm else "TLabel")
        self.live_open.configure(
            state="normal" if live.url and live.health == "responding" else "disabled")

        # A locked tab can't stay selected: fall back to the first open one.
        current = self.notebook.index(self.notebook.select())
        if current not in plan.unlocked:
            self.notebook.select(min(plan.unlocked))

    def _open_live(self) -> None:
        if self.shared.live.url:
            backend.open_in_browser(self.shared.live.url)

    def _after_deploy(self) -> None:
        self.manage_tab.refresh()
        self.refresh_live()

    def refresh_live(self) -> None:
        """Re-read what's serving, on a worker: manage.sh status probes the
        app over HTTP, which waits out a timeout when the app is wedged."""
        if self._live_pending:
            return
        self._live_pending = True

        def work() -> None:
            try:
                dep = backend.deployment()
                live = progress.Live(
                    state=dep.state, health=dep.health,
                    project_dir=dep.project_dir, data_dir=dep.data_dir,
                    data_subdir=dep.data_subdir, entry_file=dep.entry_file,
                    deployed_at=_friendly_time(dep.deployed_at), url=dep.url)
            except Exception:
                live = progress.Live(state="absent")
            self._live_queue.put(live)

        threading.Thread(target=work, daemon=True).start()
        self.after(200, self._drain_live)

    def _drain_live(self) -> None:
        try:
            live = self._live_queue.get_nowait()
        except queue.Empty:
            self.after(200, self._drain_live)
            return
        self._live_pending = False
        self.shared.live = live
        self.shared.changed()

    def _schedule_live(self) -> None:
        # Unlike the Manage tab's own poll, this runs whichever tab is on
        # screen: the bar is always visible, so it must always be current.
        def tick() -> None:
            self.refresh_live()
            self._schedule_live()
        self.after(self.LIVE_REFRESH_MS, tick)

    def _drain_restore(self) -> None:
        """Apply the restored state. UI thread only — see runner.py."""
        try:
            result = self._restore_queue.get_nowait()
        except queue.Empty:
            self.after(200, self._drain_restore)
            return

        dep = result.get("deployment")
        info = result.get("info")
        if dep is None:
            return
        if dep.project_dir and not dep.project_dir_exists:
            self.app_tab.show_missing(dep.project_dir)
            return
        if info is None:
            return

        self.app_tab.show_restored(dep.project_dir, info,
                                   _friendly_time(dep.deployed_at),
                                   result.get("entry_file", ""),
                                   dep.data_subdir)
        # Order matters: the data tab's mapping line needs shared.info, which
        # the app tab has just set.
        if dep.data_dir:
            self.data_tab.show_restored(dep.data_dir)
