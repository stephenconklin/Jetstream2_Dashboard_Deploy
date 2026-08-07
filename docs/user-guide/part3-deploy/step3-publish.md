# Step 3 · Publish

<p class="meta-line">One click, then 5–45 minutes of waiting you don't have to watch. Tab 3 of the application.</p>

This tab shows you what's about to happen, then does it.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab3-ready.png</span>
  </div>
  <figcaption>Tab 3 before publishing: the readiness summary, the Advanced
  panel collapsed, and the Publish my dashboard button enabled.</figcaption>
</figure>

---

## 1. Read the summary

At the top is a plain-English account of what will be built:

```
Ready to publish the r-shiny dashboard in /home/exouser/salmon-dashboard.

Data: /media/volume/salmon-data
      appears inside the app at /srv/shiny-server/data
```

Check the project folder, and check the data mapping. This is your last chance
to catch a wrong folder before spending build time on it.

The summary may also warn you about one of these:

??? warning "\"This project has no renv.lock, so its R packages will be worked out and recorded first\""

    Not an error. The tooling will scan your code, work out which R packages
    you use, install them once to record the exact versions, then install them
    again from that record.

    **It roughly doubles the first build time** — often 20 minutes or more
    extra. It only happens once; after this your project has a `renv.lock` and
    subsequent builds are normal speed.

    You can avoid it by
    [creating the lockfile yourself](../part2-prepare/r-packages.md), which is
    worth doing for anything you'll rebuild.

??? danger "\"WARNING: that folder is empty\""

    The data folder you chose in step 2 has nothing in it. It will be attached
    over your app's `data/` directory, hiding anything your project shipped, and
    **your app will probably fail to start**.

    Go back to [step 2](step2-your-data.md#check-what-s-arrived), upload your
    data, and press **Look in that folder now** until it lists files.

??? failure "\"Before this can be published it needs a requirements.txt\""

    A hard stop for Python projects — the Publish button stays disabled.

    Create the file in the environment where your app works:

    ```bash
    pip freeze > requirements.txt
    ```

    See [creating a requirements.txt](../part2-prepare/python-packages.md),
    then re-select the folder on tab 1.

??? note "\"No data folder attached\""

    You haven't chosen a data location, and your project doesn't ship a `data/`
    folder. This is fine **if** your dashboard genuinely reads no files —
    otherwise go back to [step 2](step2-your-data.md).

---

## 2. Advanced options { #advanced-options }

Skip this section entirely on your first attempt. Come back if the build fails.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab3-advanced.png</span>
  </div>
  <figcaption>The Advanced panel expanded, showing Force framework, App's
  internal port, and Base image.</figcaption>
</figure>

**Force framework**
:   Overrides the automatic detection. Use it if tab 1 detected the wrong
    framework, or reported an ambiguity you can't resolve by deleting a file.

**App's internal port**
:   The port your app's server listens on inside its container. Leave blank —
    the defaults are correct (3838 R Shiny, 8050 Dash, 8000 Python Shiny, 8501
    Streamlit) unless your code hardcodes something different, which
    [it shouldn't](../part2-prepare/entry-point.md#your-app-must-listen-on-all-interfaces-not-just-localhost).

**Base image**
:   The starting environment your dashboard is built on top of. This is the
    **escape hatch for old projects**, and it fixes more failures than anything
    else here.

    | Situation | Try |
    |---|---|
    | Old Python project, a package won't compile | `python:3.9-slim`, then `3.8`, then `3.7` |
    | Modern Python project | leave blank (`python:3.11-slim`) |
    | R project needing more geospatial libraries | `rocker/geospatial:4.4.1` |
    | R project, heavy tidyverse use | `rocker/shiny-verse` |

    The reasoning, and the specific error messages that point to it, are in
    [When an old project's pins no longer build](../part2-prepare/python-packages.md#when-an-old-project-wont-build).

---

## 3. Press Publish

Click **Publish my dashboard**.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab3-building.png</span>
  </div>
  <figcaption>A build in progress: the Progress log scrolling, the elapsed
  timer, and the Stop button enabled.</figcaption>
</figure>

The **Progress** pane fills with output, and a timer counts up beside the
buttons.

### How long to expect

| Framework | First build | Later builds |
|---|---|---|
| Streamlit, Dash, Python Shiny | 5–15 min | 1–3 min |
| R Shiny (with `renv.lock`) | 20–45 min | 2–5 min |
| R Shiny (no `renv.lock`) | 40–90 min | 2–5 min |
| R Shiny, geospatial | 45–90 min | 3–8 min |

Later builds are much faster because the slow parts — the base image, the
system libraries, the packages — are cached and reused.

### You don't have to watch

**The build is not part of the application.** It runs independently, writing to
a log file the window merely displays. So you can:

- Close the application window
- Close the browser tab
- Lose your internet connection entirely
- Shut your laptop

…and the build carries on. Reopen the application later and it reattaches to
the running build and resumes showing you the log.

This is deliberate: a 40-minute R build that died because a laptop lid closed
would be unacceptable.

??? tip "What the log is telling you"

    You don't have to read it, but if you're curious, a build moves through
    roughly these phases:

    1. **Preparing the build context** — copying your code (skipping `.git`,
       `data/`, virtual environments)
    2. **Pulling the base image** — instant on the prepared image, which
       pre-downloads all of them
    3. **Installing system libraries** — apt output; anything from your
       `apt.txt` happens here
    4. **Installing your packages** — the long part. R compiles from source;
       Python usually downloads prebuilt wheels
    5. **Starting the container**
    6. **Checking it answers** — polling your app until it responds

    Phase 4 is where nearly all failures happen, and where nearly all the time
    goes.

### Stopping a build

**Stop** cancels it. Nothing is left half-published — if a dashboard was
already running, it keeps running untouched.

---

## 4. When it finishes

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-published-dialog.png</span>
  </div>
  <figcaption>The "Published" dialog showing the dashboard's URL and offering
  to open it.</figcaption>
</figure>

```
Your dashboard is published at:
http://149.165.170.42/

Open it and check it looks the way you expect.

                                    [ Open it now ]  [ Later ]
```

**Click "Open it now" and actually look at your dashboard.**

!!! danger "\"Published\" does not mean \"working\""

    This is the most important sentence in the guide.

    The check behind that message proves your dashboard **answered a web
    request**. It does not prove it works. Shiny and Streamlit both catch
    errors in your code and display them *as a page* — returning a perfectly
    healthy HTTP 200 while showing a traceback to whoever opens it.

    So a dashboard that can't find its data file, or has a typo in a plotting
    call, is reported as published — accurately, because it *is* reachable. It
    just shows an error to your visitors.

    The application is deliberately worded to say *live*, never *success*.
    **The only real test is loading the page and using it.**

Click through your dashboard the way a visitor would: change the inputs, load
each tab, draw each plot. Everything that reads a data file is worth exercising
at least once, because data paths are the most common thing to be broken here.

---

## If it fails

An error dialog appears pointing you at the end of the progress log.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-failed-dialog.png</span>
  </div>
  <figcaption>The failure dialog, naming the log directory.</figcaption>
</figure>

**Scroll to the bottom of the Progress pane.** The actual reason is in the last
20 lines or so — everything above it is normal build output. The message is the
underlying tool's own words, so it's precise.

Every attempt also leaves a timestamped log in `~/dashboard-deploy-logs/`,
which is the most useful thing to send when asking for help.

The common failures, by what you see:

| In the log | Cause | Fix |
|---|---|---|
| `no space left on device` | Disk full | [Free up space](step4-manage.md#storage) |
| `there is no package called 'X'` | Missing R package, or an uploaded `renv/` folder | [renv](../part2-prepare/r-packages.md#what-renv-leaves-behind) |
| `fatal error: ...h: No such file or directory` | Package needs an older Python, or a system library | [Base image](#advanced-options) or `apt.txt` |
| `ERROR: Could not find a version that satisfies` | A pinned package doesn't exist for this Python | [Base image](#advanced-options) |
| `configure: error: ... GDAL ... PROJ ...` | Geospatial version drift | [Pinning R versions](../reference/deployment.md#pinning-r-package-versions-to-avoid-cran-version-drift) |
| `ImportError: cannot import name ...` | Unpinned transitive dependency moved on | [Pin it](../part2-prepare/python-packages.md#when-an-old-project-wont-build) |
| The app never answered | App crashed at startup — the log's last 50 lines show why | [Troubleshooting](../help/troubleshooting.md) |

More detail on each: **[When something goes wrong](../help/troubleshooting.md)**.

---

Next → **[Step 4 · Manage](step4-manage.md)**
