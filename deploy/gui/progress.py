"""Where the researcher is in the process, worked out in one place.

Every visual cue in the window — the symbol on each tab, the status line at
the top of each step, which tabs are locked, the live bar, the publish
button's wording and whether it's enabled — is read from the Plan this
module returns. Deriving them separately in each widget is how a window ends
up with a green tick next to a disabled button, which is precisely the
confusion these cues exist to remove.

Deliberately pure: no Tk, no subprocesses, no file system. The window gathers
the facts (including the one I/O-backed fact, whether the data folder is
empty) and passes them in, so the whole decision table can be exercised on a
machine with no display.

Every level comes with words, never colour or a symbol alone: the symbol is a
shorthand for the sentence beside it, and the window shows a key to them.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

# Levels, in the order a step normally moves through them.
TODO = "todo"            # not started, or not available yet
ATTENTION = "attention"  # something needs the researcher before it can go on
WORKING = "working"      # a build is running
DONE = "done"
FAILED = "failed"

SYMBOLS = {TODO: "○", ATTENTION: "⚠", WORKING: "◐", DONE: "✓", FAILED: "✗"}

# Shown under the tabs. Same words the status lines use, so the key teaches
# the vocabulary rather than adding a second one.
LEGEND = "   ".join(f"{SYMBOLS[k]} {w}" for k, w in (
    (TODO, "to do"), (ATTENTION, "needs your attention"), (WORKING, "working"),
    (DONE, "done"), (FAILED, "didn't finish")))

FRAMEWORK_NAMES = {"r-shiny": "R Shiny", "dash": "Plotly Dash",
                   "python-shiny": "Python Shiny", "streamlit": "Streamlit"}

# Tab indices.
APP, DATA, PUBLISH, MANAGE = range(4)


@dataclass
class Step:
    level: str
    message: str
    # Whether a step in this state stops publishing. False for warnings the
    # researcher is allowed to go ahead past, like a big app folder.
    blocking: bool = True

    @property
    def symbol(self) -> str:
        return SYMBOLS[self.level]


@dataclass
class Live:
    """What's actually serving, from the container's own labels."""

    state: str = "absent"          # absent | running | exited | …
    health: str = "unknown"        # responding | not-responding | stopped
    project_dir: str = ""
    data_dir: str = ""
    data_subdir: str = ""
    entry_file: str = ""
    deployed_at: str = ""          # already made friendly by the caller
    url: str = ""

    @property
    def exists(self) -> bool:
        return self.state not in ("", "absent")


@dataclass
class Draft:
    """What the researcher has set up in tabs 1 and 2."""

    project_dir: str = ""
    info: object | None = None     # backend.ProjectInfo; duck-typed here
    data_mode: str = ""            # bundle | mount
    data_dir: str = ""
    data_subdir: str = "data"
    data_dir_empty: bool = False


@dataclass
class Plan:
    steps: dict[int, Step] = field(default_factory=dict)
    unlocked: set[int] = field(default_factory=set)
    live_level: str = TODO
    live_line: str = ""
    relation_line: str = ""        # how the draft relates to what's live
    publish_label: str = "Publish my dashboard"
    publish_ready: bool = False
    publish_reason: str = ""       # why the button is greyed, when it is
    needs_confirm: bool = False    # publishing replaces a different project


def _same_path(a: str, b: str) -> bool:
    if not a or not b:
        return False
    return os.path.realpath(a) == os.path.realpath(b)


def _app_step(d: Draft) -> Step:
    info = d.info
    if not d.project_dir or info is None:
        return Step(TODO, "Choose the folder your dashboard is in.")
    if info.needs_entry_choice:
        n = len(info.candidates)
        return Step(ATTENTION, f"Choose your main file — {n} files in this "
                               "folder could be your dashboard.")
    if not info.deps_ok:
        return Step(ATTENTION, "This project needs a requirements.txt before it "
                               "can be published — see step 3 for how.")
    main = info.entry_file or info.entry_point_desc
    folder = os.path.basename(d.project_dir.rstrip("/")) or d.project_dir
    kind = FRAMEWORK_NAMES.get(info.framework, info.framework)
    msg = f"{kind} dashboard in the folder “{folder}”, main file {main}."
    notes = len(info.code_notes)
    if notes:
        msg += (f" {notes} thing{'s' if notes != 1 else ''} worth checking in "
                "your code, listed below — they won't stop you publishing.")
    return Step(DONE, msg)


def _human_kb(kb: int) -> str:
    size = float(kb) * 1024
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.0f} {unit}" if unit in ("B", "KB") else f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


def _data_step(d: Draft, app: Step) -> Step:
    info = d.info
    if info is None or app.level == TODO:
        return Step(TODO, "Complete step 1 first.")
    if d.data_mode == "mount":
        if not d.data_dir:
            return Step(ATTENTION, "Choose the folder your data is in, below.")
        if d.data_dir_empty:
            return Step(ATTENTION, "That folder is empty — upload your data to it "
                                   "before publishing.")
        return Step(DONE, f"Your data in {d.data_dir} appears inside the app as "
                          f"{d.data_subdir}/.")
    if info.reads_missing_data_dir:
        sub = info.data_subdir or "data"
        return Step(ATTENTION, f"Your code reads files from {sub}/, but your app "
                               f"folder has no {sub}/ folder — so they won't be "
                               "there. Choose the second option and pick where "
                               "that data is.",
                    blocking=False)
    if info.too_big_to_bundle:
        return Step(ATTENTION, f"Your app folder is {_human_kb(info.app_kb)} — a lot "
                               "to publish with the app. Consider putting the data "
                               "on a storage volume (the second option).",
                    blocking=False)
    return Step(DONE, f"Your data files are published with the app "
                      f"({_human_kb(info.app_kb)} in all).")


def _relation(d: Draft, live: Live) -> tuple[str, str, str, bool]:
    """(kind, sentence, publish label, needs confirmation)."""
    if not live.exists:
        return "first", "", "Publish my dashboard", False
    if not d.project_dir or d.info is None:
        return "none", "", "Publish my dashboard", False
    if not live.project_dir:
        return ("unknown",
                "A dashboard is live, but it doesn't record which folder it came "
                "from. Publishing will replace it.",
                "Replace the live dashboard…", True)
    if not _same_path(d.project_dir, live.project_dir):
        return ("different",
                "This is a different project from the one that's live — "
                "publishing will replace it.",
                "Replace the live dashboard…", True)

    # A container from before the entry_file label existed records none;
    # treat that as "not known to differ" rather than as a change.
    entry_same = (not live.entry_file
                  or live.entry_file == (d.info.entry_file or ""))
    if d.data_mode == "mount" and d.data_dir:
        data_same = (_same_path(d.data_dir, live.data_dir)
                     and (d.data_subdir or "data") == (live.data_subdir or "data"))
    else:
        data_same = not live.data_dir
    same = entry_same and data_same
    if same:
        when = f" on {live.deployed_at}" if live.deployed_at else ""
        return ("same",
                f"Same folder and settings as what's live. Any edits to your "
                f"files since it was published{when} go live when you publish "
                "again.",
                "Publish again", False)
    return ("changed",
            "You've changed the main file or the data settings since this was "
            "published. They go live when you publish.",
            "Update my dashboard", False)


def _live_line(live: Live) -> tuple[str, str]:
    if not live.exists:
        return TODO, "Nothing published yet."
    name = os.path.basename(live.project_dir.rstrip("/")) if live.project_dir else "Your dashboard"
    when = f" · published {live.deployed_at}" if live.deployed_at else ""
    if live.health == "responding":
        return DONE, f"LIVE — {name}{when}"
    if live.state == "running":
        return ATTENTION, (f"{name} is running but not answering — see "
                           "4. Manage.")
    return ATTENTION, f"{name} is stopped — start it again from 4. Manage."


def assess(draft: Draft, live: Live, build: str = "") -> Plan:
    """Work out every cue in the window.

    ``build`` is the state of a publish started from this window: "" (none
    yet), "building", "done" or "failed".
    """
    plan = Plan()
    app = _app_step(draft)
    data = _data_step(draft, app)

    kind, relation, label, confirm = _relation(draft, live)
    plan.live_level, plan.live_line = _live_line(live)
    plan.relation_line = relation
    plan.publish_label = label
    plan.needs_confirm = confirm

    blockers = [s for s in (app, data) if s.level != DONE and s.blocking]
    if blockers:
        first = 1 if blockers[0] is app else 2
        plan.publish_reason = f"Finish step {first} first: {blockers[0].message}"
    if build == "building":
        publish = Step(WORKING, "Publishing… " + (
            "Your current dashboard stays up until the new one is ready."
            if live.exists else "This can take a while; you can leave it running."))
        plan.publish_reason = "A publish is already running."
        plan.relation_line = ("Building a new version — the current dashboard "
                              "stays up until it's ready."
                              if live.exists else "")
    elif build == "failed":
        publish = Step(FAILED, "The last publish didn't finish. The reason is at "
                               "the end of the progress log below.")
    elif blockers:
        publish = Step(TODO, f"Finish step {first} first.")
    elif build == "done" and kind == "same" and live.health == "responding":
        publish = Step(DONE, "Published. Open it and check it looks the way you "
                             "expect.")
    elif kind == "same" and live.health == "responding":
        publish = Step(DONE, "This is what's live. Publish again to pick up any "
                             "edits you've made since.")
    else:
        publish = Step(TODO, f"Ready — press “{label.rstrip('…')}” below when "
                             "you are.")

    plan.publish_ready = build != "building" and not blockers
    plan.steps = {APP: app, DATA: data, PUBLISH: publish}

    plan.unlocked = {APP, MANAGE}
    if build == "building":
        # Settings can't change a build that has already started, so they
        # can't be edited while one runs — only watched.
        plan.unlocked = {PUBLISH, MANAGE}
    elif app.level != TODO:
        plan.unlocked |= {DATA, PUBLISH}
    return plan
