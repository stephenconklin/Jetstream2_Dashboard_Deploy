# Azure ttk theme (vendored)

Upstream: https://github.com/rdbende/Azure-ttk-theme
Pinned commit: `997dbbef09563c3a0b2541ae3de5cd774f1640fb` (2023-10-30)
Licence: MIT — see `LICENSE`, which must stay alongside these files.

Vendored rather than installed because the GUI is **stdlib only, no pip
dependencies** (see the GUI section of the repo's `CLAUDE.md`). This is a Tcl
script plus PNG assets, so copying it in adds no Python dependency and no
packaging step: `deploy/desktop/setup_image.sh` ships the whole repo by
`git clone` / `git merge --ff-only`, so a tracked file is on the researcher
image automatically.

## Do not hand-edit these files

Everything here is upstream's, byte for byte, so it can be re-pulled by
replacing the directory and bumping the commit above. Local adjustments belong
in `deploy/gui/__main__.py` (`_apply_theme`) or `deploy/gui/ui.py`
(`_init_styles`) instead.

Two adjustments currently live there, both deliberate:

- `set_theme` sets the font to `"Segoe Ui" 10`, which does not exist on Ubuntu.
  `_apply_theme` re-points both the `.` style and the `*font` option at
  `TkDefaultFont` afterwards, so themed widgets and the labels that pin a font
  explicitly agree on a family.
- `set_theme` also configures `.` with `-fieldbackground` set to the *selection*
  colour. `azure-light`'s own per-widget styles override it, but anything
  inheriting straight from `.` would come out blue.

Only the light mode is used. `theme/dark.tcl` and `theme/dark/` are kept anyway
because `azure.tcl` sources both unconditionally at load time and errors
without them.

Upstream's own caveat worth knowing: Tk is slow at PNGs, and this loads ~120 of
them at source time. If that ever drags on a remote desktop, upstream has a
gif-based branch.
