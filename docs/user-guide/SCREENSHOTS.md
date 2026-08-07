# Screenshot capture checklist

Every figure in the guide is already written, captioned and positioned — each
one currently renders as a dashed placeholder box naming the file that should
replace it. This document is the shot list.

**This file is not part of the published site** (it's excluded in `mkdocs.yml`).

---

## How to swap a placeholder for a real image

1. Capture the shot and save it as the exact filename listed below, into
   `docs/user-guide/assets/screenshots/`.
2. Find the placeholder in the page (search for the filename).
3. Replace the `<div class="shot__box">…</div>` block with an `<img>`, and drop
   the `shot--todo` class. **Keep the `<figcaption>` exactly as it is** — it's
   already written.

Before:

```html
<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab1-detected.png</span>
  </div>
  <figcaption>Tab 1 after a successful selection, showing …</figcaption>
</figure>
```

After:

```html
<figure class="shot">
  <img src="../../assets/screenshots/p3-tab1-detected.png"
       alt="Tab 1 showing a detected r-shiny dashboard and its entry point">
  <figcaption>Tab 1 after a successful selection, showing …</figcaption>
</figure>
```

!!! note "Watch the relative path"

    Pages one level deep (`part3-deploy/step1-your-app.md`) need
    `../assets/…`. With `use_directory_urls` on — the MkDocs default — the
    served URL is one level deeper again, so `../../assets/…` is correct from a
    page inside a subfolder. Run `mkdocs serve` and check the image actually
    appears; a broken path shows as a missing-image icon, not an error.

---

## Capture guidance

**Resolution.** Capture at 1600px wide or more. Material scales images down
cleanly but cannot invent detail. For full-window shots of the application,
size the window to roughly 1000×750 first — the guide's screenshots should look
consistent with each other.

**Redact before you capture, not after.** Real IP addresses, usernames other
than `exouser`, allocation IDs, project names you'd rather not publish. The
easiest approach is to set up a throwaway instance and a demo project
(`examples/r-shiny-hello-world/` in this repo works) specifically for capturing.

**Consistency matters more than beauty.** Same theme, same window size, same
zoom level throughout. A guide whose screenshots obviously come from six
different sessions reads as unmaintained.

**Crop to the subject.** For a panel-level shot, crop to the panel plus a
little surrounding context — not the whole desktop.

**Annotate sparingly.** A single red rectangle around the control being
discussed is worth adding where a shot is busy (the Exosphere create form, the
desktop with the icon). Don't annotate shots the caption already covers.

**File format.** PNG. Keep each file under about 500 KB; run them through
`pngquant` or `oxipng` if they're larger.

---

## Part 1 · The Jetstream2 instance and volume

These come from Exosphere in a browser, not from the instance.

| # | Filename | What must be visible |
|---|---|---|
| 1 | `p1-exosphere-home.png` | Exosphere home after login: the allocation selector and the **Create** button |
| 2 | `p1-choose-image.png` | The image chooser with the Dashboard Deploy image selected; the search box and the Public / Shared-with-me tabs both in frame |
| 3 | `p1-create-instance-form.png` | The Create Instance form: **Name**, **Flavor**, **Enable web desktop** (ticked), and the disk-size slider. Annotate the web-desktop checkbox — it's the setting people miss |
| 4 | `p1-instance-building.png` | The instance list with the new instance in **Building**, showing its progress message |
| 5 | `p1-instance-ready.png` | The instance detail page in **Ready**, showing the IP address and the **Web Desktop** action. Redact or substitute the IP |
| 6 | `p1-create-volume.png` | The Create Volume form with **Name** and **Size** filled in |
| 7 | `p1-volume-list.png` | The volume list with the new volume in **Available** |
| 8 | `p1-attach-volume.png` | The Attach Volume dialog with a target instance selected |
| 9 | `p1-format-mount.png` | Exosphere's format-and-mount prompt for a newly attached volume |
| 10 | `p1-volume-attached.png` | The volume page after attaching: state **In use** and the mount point under `/media/volume/` |

!!! tip "Jetstream2's own documentation"

    [docs.jetstream-cloud.org](https://docs.jetstream-cloud.org/) has current
    screenshots of most of these flows. If Exosphere's interface changes, check
    there first — and consider linking to their page for a step rather than
    maintaining a duplicate screenshot of it. Attribute anything you reuse.

---

## Part 3 · The desktop application

Capture these on a real instance with a real (or demo) project published.

### Getting in

| # | Filename | What must be visible |
|---|---|---|
| 11 | `p3-webdesktop-link.png` | The instance page in Exosphere with the **Web Desktop** action highlighted |
| 12 | `p3-desktop-icon.png` | The Ubuntu desktop with the **Deploy My Dashboard** icon, with enough surrounding desktop to be findable. Annotate the icon |
| 13 | `p3-first-open.png` | The application freshly opened on tab 1, nothing selected |
| 14 | `p3-app-overview.png` | **Hero image.** The whole window with all four tabs visible, on tab 1 with a project selected and detection reported. This one is worth extra care — it's the first picture most readers see |

### Tab 1 · Your app

| # | Filename | What must be visible |
|---|---|---|
| 15 | `p3-tab1-empty.png` | Tab 1 with the three radio options, nothing chosen |
| 16 | `p3-tab1-git.png` | Git option selected, a repository URL in the Address field |
| 17 | `p3-tab1-zip.png` | Zip option selected, a file chosen, **Unpack it** visible |
| 18 | `p3-tab1-browse.png` | Browse option with a folder path filled in |
| 19 | `p3-tab1-detected.png` | After a successful selection: framework, entry point, and the data-folder note. **Capture an R Shiny project** so the framework line reads `r-shiny` and matches the guide's example text |

### Tab 2 · Your data

| # | Filename | What must be visible |
|---|---|---|
| 20 | `p3-tab2-full.png` | The whole tab: locations, transfer routes, check panel. May need the window taller than usual |
| 21 | `p3-tab2-locations.png` | The location list with a mounted volume showing free space, and the home folder beneath it with its warning text |
| 22 | `p3-tab2-routes.png` | The four transfer routes with one selected and its detail panel showing. Globus or rsync makes the most illustrative choice |
| 23 | `p3-tab2-verify.png` | The check panel after a **successful** listing: file count, total size, first few filenames |
| 24 | `p3-tab2-persist.png` | The reboot-persistence panel with its warning text and **Make this permanent**. Only appears on a volume not yet in `/etc/fstab` — capture it *before* pressing the button |

### Tab 3 · Publish

| # | Filename | What must be visible |
|---|---|---|
| 25 | `p3-tab3-ready.png` | Before publishing: the readiness summary including the data mapping, Advanced collapsed, **Publish my dashboard** enabled |
| 26 | `p3-tab3-advanced.png` | Advanced expanded: Force framework, App's internal port, Base image, and the hint text below |
| 27 | `p3-tab3-building.png` | A build in progress: log scrolling, elapsed timer, **Stop** enabled. Catch it during package installation so the log looks like real work |
| 28 | `p3-published-dialog.png` | The **Published** dialog with the URL and **Open it now**. Redact the IP |
| 29 | `p3-failed-dialog.png` | The failure dialog naming the log directory. Force one by publishing a project with a deliberately broken `requirements.txt` |

### Tab 4 · Manage

| # | Filename | What must be visible |
|---|---|---|
| 30 | `p3-tab4-healthy.png` | The whole tab with a healthy dashboard: headline with URL, buttons, Details, Storage, log pane |
| 31 | `p3-tab4-buttons.png` | Close crop of the button row |
| 32 | `p3-tab4-details.png` | The Details panel with all eight rows populated and a `200` in **Responding** |
| 33 | `p3-tab4-storage.png` | The Storage panel with free space, image size, reclaimable space, **Free up space**. Ideally on an instance with a few builds behind it, so the numbers are non-zero |
| 34 | `p3-tab4-logs.png` | The log pane with real R Shiny startup output |
| 35 | `p3-tab4-report.png` | The **Report saved** dialog naming the file path |

---

## Optional extras

Not referenced by any page yet — add the figure markup if you capture them.

- A published dashboard in a browser, showing the address bar with the IP.
  Would strengthen [Share and update your dashboard](part3-deploy/share-your-dashboard.md).
- A dashboard rendering an error page (Shiny's grey error, Streamlit's red box)
  to illustrate "published does not mean working" in
  [Step 3](part3-deploy/step3-publish.md#4-when-it-finishes). This is the most
  valuable optional shot — it makes an abstract warning concrete.
- The `/_deploy/unavailable.html` maintenance page.

---

## Tracking progress

- [ ] Part 1 — Exosphere (10 shots)
- [ ] Part 3 — getting in (4 shots)
- [ ] Part 3 — tab 1 (5 shots)
- [ ] Part 3 — tab 2 (5 shots)
- [ ] Part 3 — tab 3 (5 shots)
- [ ] Part 3 — tab 4 (6 shots)

**35 shots total.** Realistically two sessions: one in Exosphere while creating
a fresh instance and volume (shots 1–12), and one on the instance working
through a real publish end to end (shots 13–35). Doing the second in one pass,
in guide order, is much faster than hunting for individual states later — and
it doubles as a full test of the guide's accuracy.
