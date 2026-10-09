# Final checks before you upload

<p class="meta-line">10 minutes. Each of these takes seconds and each one saves you a 20-minute build.</p>

---

## The checklist

Work down it. Every item is something that has cost somebody a failed build.

### Your code

- [ ] **The app runs on your own computer, right now**, from a fresh start.
      Not "it worked last month" — run it.
- [ ] **The starting file is at the top level** of the project folder. Any
      name is fine (`water_quality.R` works as well as `app.R`), and so are
      `ui.R`+`server.R` or an `.Rmd` with `runtime: shiny`.
- [ ] **Dash only:** `app.py` contains `server = app.server`.
- [ ] **No leftover app files** from an earlier version. They won't break
      anything, but you'll be asked which file is the real one.
- [ ] **No absolute paths** — see
      [checking your paths](data-paths.md#checking-your-paths-before-you-upload).
- [ ] **No hardcoded host or port** in the code that starts the server.

### Your package list

=== "R Shiny"

    - [ ] `renv.lock` exists in the project root
    - [ ] The app runs against the renv library (`renv::restore()` then
          `shiny::runApp()`)
    - [ ] No need to upload `renv/`. An `.Rprofile` that activates renv is
          switched off automatically in the published copy
    - [ ] `apt.txt` added, if any package needed a system library

=== "Python"

    - [ ] `requirements.txt` exists in the project root
    - [ ] It was generated in the environment where the app actually works
    - [ ] It contains no `file://` or `@ /path/to/...` lines
    - [ ] `apt.txt` added, if any package needed a system library

### Your data

- [ ] Your code reads data by **relative** path: a bare file name for files
      next to your code, or `data/…` (or `DATA_DIR`) for a data folder
- [ ] You know which of the
      [three arrangements](data-paths.md#three-arrangements-all-fine) you're
      using: small data in your project folder, published with the app, or
      large data on your volume (`/media/volume/<name>`), attached to it

### Size

- [ ] The project folder, **including** any data you'll publish with it, is
      under about a gigabyte

    Everything in the project folder is copied into the published dashboard,
    on every publish. Large files make every build slow and the image huge.
    Move anything big onto the volume.

    Check it:

    === "macOS / Linux"

        ```bash
        du -sh /path/to/my-dashboard
        du -sh /path/to/my-dashboard/* | sort -h | tail -10
        ```

    === "Windows PowerShell"

        ```powershell
        Get-ChildItem -Recurse | Measure-Object -Property Length -Sum
        ```

---

## The best test available: run the dry run

If you have a terminal and can clone the repository on your own machine, this
tells you what the server will conclude about your project — without building
anything, and without changing anything:

```bash
git clone https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy.git
cd Jetstream2_Dashboard_Deploy
./deploy/build_and_run.sh --dry-run /path/to/my-dashboard
```

A healthy result looks like this:

```console
Framework:       r-shiny
Entry point:     water_quality.R
                 (not named app.R — the build adds an app.R that runs it)
Base image:      rocker/geospatial:4.4.1
Dependencies:    renv.lock present
App folder:      48 MB would be published with the app
data/ folder:    not in the project (set DATA_DIR=/path to mount data from elsewhere)
apt.txt:         absent/empty
Code check:      nothing found
```

Read it as five questions:

| Line | What to check |
|---|---|
| **Framework** | Is it the one you expect? If not, detection found the wrong signal. |
| **Entry point** | Is that really your app's starting file? If several files could be, it says so; name the right one with `ENTRY_FILE=…` |
| **Dependencies** | `missing` means the build will stop. Fix it now. |
| **App folder** | Under about a gigabyte? That's what gets published with the app |
| **Code check** | Anything listed is worth fixing before you upload: a path on your own computer, a `setwd()`, a file name whose capitals don't match |

!!! info "Don't have a terminal, or on Windows?"

    Skip this. The application in Part 3 runs exactly the same check the moment
    you select your project folder, and shows you the same facts. You'll find
    out within seconds of getting there.

---

## Getting it ready to move

Three ways to get your project onto the server, and preparing now makes Part 3
much smoother.

<div class="grid cards" markdown>

-   :material-github: **Git — best**

    Push your prepared project to GitHub or GitLab. In Part 3 you paste the
    URL and the application fetches it. Updating later is a `git push` plus a
    republish.

    Private repos work too, but you'll be prompted for credentials — a
    personal access token, not your password.

-   :material-folder-zip: **A `.zip` file — simplest**

    Zip the project folder. In Part 3, drag it onto the remote desktop and the
    application unpacks it for you.

    Remember to leave out `renv/`, `venv/` and any large data first.

-   :material-console: **rsync — for big projects**

    If you're comfortable with a terminal and added an SSH key in Part 1, copy
    it straight across. The application shows you the exact command with your
    instance's address already filled in.

</div>

---

## :material-check-all: Part 2 complete

Your project should now be a folder containing:

```
my-dashboard/
├── app.R  (any name; or app.py / streamlit_app.py / ui.R + server.R)
├── renv.lock  (R)  or  requirements.txt  (Python)
├── apt.txt         ← only if you needed one
└── ... your other code, www/, assets/, R/ ...
```

…with data either small and alongside your code (published with the app), or
already destined for your volume.

Next → **[Part 3 · Publish it](../part3-deploy/index.md)**
