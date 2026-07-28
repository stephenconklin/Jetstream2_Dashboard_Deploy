"""Streaming a long build into a Tk widget without freezing the UI.

Tkinter is not thread-safe. The single rule this module enforces is that
only the thread which created the root window ever touches a widget;
everything else communicates through a ``queue.Queue`` drained by a
``root.after()`` callback on the UI thread.

The build itself is *not* a child of this process — see run_detached.sh for
why. This module tails its log file, which means it can attach to a build
that started before the GUI did, and detach without stopping it.
"""

from __future__ import annotations

import queue
import threading
import time
from pathlib import Path
from typing import Callable

from backend import RunHandle

# Drain at most this many lines per tick. A `docker build` of a geospatial R
# image emits tens of thousands of lines; draining without a cap starves the
# event loop and the window stops repainting — the exact freeze this whole
# design exists to avoid.
MAX_LINES_PER_TICK = 200

# How often the UI thread checks for new output.
POLL_MS = 120

# Tk's Text widget degrades visibly past a few tens of thousands of lines,
# and a full R build exceeds that. Old lines are dropped from the widget;
# the complete log is always on disk regardless.
MAX_SCROLLBACK_LINES = 5000

# Reported when the run vanished without recording an exit status — i.e. it
# was killed hard. 128+SIGKILL, matching the shell convention, so it reads
# correctly if it ever surfaces in a log or bug report.
KILLED_EXIT_CODE = 137


class LogTailer:
    """Follows a log file on a worker thread, feeding lines to the UI.

    Parameters
    ----------
    handle:
        The detached run to follow.
    on_line:
        Called on the UI thread with a batch of new lines (a single string).
    on_finish:
        Called on the UI thread with the process exit code once the run ends.
    """

    def __init__(self, handle: RunHandle,
                 on_line: Callable[[str], None],
                 on_finish: Callable[[int], None]) -> None:
        self.handle = handle
        self._on_line = on_line
        self._on_finish = on_finish
        self._queue: queue.Queue[tuple[str, object]] = queue.Queue()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._widget_after: Callable[..., str] | None = None
        self._after_id: str | None = None
        self.started_at = time.time()

    # -- worker thread ----------------------------------------------------

    def _follow(self) -> None:
        """Read the log as it grows; stop once the exit sentinel appears.

        Opened with errors="replace" because build output occasionally
        carries partial UTF-8 (progress bars, truncated writes) and a
        UnicodeDecodeError here would silently kill the tail.
        """
        path = Path(self.handle.log_path)
        # The file may not exist for a moment after launch.
        for _ in range(100):
            if path.exists() or self._stop.is_set():
                break
            time.sleep(0.05)

        # Consecutive polls where the log is idle and the wrapper process is
        # gone but no exit sentinel has appeared. A cancelled build that had
        # to be SIGKILLed dies without recording its status, and waiting for
        # a file that will never be written would hang the tail forever —
        # which is exactly what the UI's "Cancel" button would look like if
        # this counter didn't exist. A few polls of grace first, since the
        # wrapper may be milliseconds from writing it.
        missing_sentinel_polls = 0
        GRACE_POLLS = 12  # ~1.8s at 0.15s per poll

        try:
            with path.open("r", encoding="utf-8", errors="replace") as fh:
                while not self._stop.is_set():
                    chunk = fh.read()
                    if chunk:
                        missing_sentinel_polls = 0
                        self._queue.put(("out", chunk))
                        continue
                    # No new output. If the run has finished, read once more
                    # to catch anything written between the last read and
                    # the sentinel appearing, then stop.
                    code = self.handle.exit_code()
                    if code is not None:
                        tail = fh.read()
                        if tail:
                            self._queue.put(("out", tail))
                        self._queue.put(("done", code))
                        return

                    if not self.handle.process_alive():
                        missing_sentinel_polls += 1
                        if missing_sentinel_polls >= GRACE_POLLS:
                            tail = fh.read()
                            if tail:
                                self._queue.put(("out", tail))
                            self._queue.put((
                                "out",
                                "\n[build stopped before it could report a "
                                "result — usually because it was cancelled]\n"))
                            self._queue.put(("done", KILLED_EXIT_CODE))
                            return
                    else:
                        missing_sentinel_polls = 0
                    time.sleep(0.15)
        except OSError as exc:
            self._queue.put(("out", f"\n[could not read log file: {exc}]\n"))
            self._queue.put(("done", self.handle.exit_code() or 1))

    # -- UI thread --------------------------------------------------------

    def start(self, widget_after: Callable[..., str]) -> None:
        """Begin tailing. ``widget_after`` is a Tk widget's ``after``."""
        self._widget_after = widget_after
        self._thread = threading.Thread(target=self._follow, daemon=True)
        self._thread.start()
        self._pump()

    def _pump(self) -> None:
        """Drain the queue on the UI thread and reschedule."""
        finished_code: int | None = None
        batch: list[str] = []
        lines_seen = 0

        while lines_seen < MAX_LINES_PER_TICK:
            try:
                kind, payload = self._queue.get_nowait()
            except queue.Empty:
                break
            if kind == "out":
                text = str(payload)
                batch.append(text)
                lines_seen += text.count("\n") or 1
            elif kind == "done":
                finished_code = int(payload)  # type: ignore[arg-type]
                break

        if batch:
            self._on_line("".join(batch))

        if finished_code is not None:
            self._on_finish(finished_code)
            return

        if not self._stop.is_set() and self._widget_after is not None:
            self._after_id = self._widget_after(POLL_MS, self._pump)

    def stop(self) -> None:
        """Stop tailing. Does not stop the build — that's backend.cancel."""
        self._stop.set()

    def elapsed(self) -> str:
        """mm:ss since this tailer started, for the 'still working' label.

        Long silences are normal — renv::restore() and GDAL compiles can go
        minutes without output — and without a visibly ticking clock people
        conclude the build has hung and kill it.
        """
        secs = int(time.time() - self.started_at)
        return f"{secs // 60:d}:{secs % 60:02d}"


def append_to_text(text_widget, chunk: str) -> None:
    """Append to a Tk Text, trimming scrollback and autoscrolling politely.

    Autoscroll only happens when the view is already at the bottom, so a
    researcher who has scrolled up to read an error isn't yanked away from
    it by continuing output.
    """
    at_bottom = text_widget.yview()[1] >= 0.999

    text_widget.configure(state="normal")
    text_widget.insert("end", chunk)

    line_count = int(text_widget.index("end-1c").split(".")[0])
    if line_count > MAX_SCROLLBACK_LINES:
        excess = line_count - MAX_SCROLLBACK_LINES
        text_widget.delete("1.0", f"{excess + 1}.0")

    text_widget.configure(state="disabled")
    if at_bottom:
        text_widget.see("end")
