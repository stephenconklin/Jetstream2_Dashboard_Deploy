# R: create a `renv.lock`

<p class="meta-line">15 minutes, plus install time. R Shiny projects only — Python users go <a href="../python-packages/">here</a>.</p>

A `renv.lock` is a JSON file listing every R package your dashboard uses **and
the exact version of each**. The server reads it and installs precisely those
versions.

---

## Do you need to do this?

**Strictly, no.** If your project has no `renv.lock`, the tooling makes one for
you: it scans your `.R` and `.Rmd` files for `library()` and `require()` calls,
installs what it finds, and records the result.

**In practice, yes, and here's why:**

| | Without a `renv.lock` | With one |
|---|---|---|
| Which versions get installed | Whatever is newest on CRAN today | The versions you tested with |
| First build time | Roughly **doubled** — packages are installed once to work out the list, then again to install from it | Normal |
| Rebuild next year | May differ from today's, or fail | Identical |
| Packages loaded dynamically | Missed — the scan only sees literal `library(x)` calls | Included |

That second row is the one people feel. An R geospatial build that takes 45
minutes with a lockfile can take an hour and a half without one.

!!! danger "The version-drift trap"

    CRAN only distributes the *current* version of each package. A dashboard
    that built perfectly in March can fail in June because `sf` released a
    version needing a newer GDAL than the server has — with no change to your
    code at all.

    A `renv.lock` is what makes your dashboard rebuildable next year. If you
    plan to cite this dashboard in a paper, treat the lockfile as part of the
    paper.

---

## How to make one

Do this **on your own computer**, in the environment where your dashboard
already works.

### 1. Install renv

```r
install.packages("renv")
```

### 2. Open your project in R

Set your working directory to the project folder — the one containing `app.R`.
In RStudio, opening the `.Rproj` file does this. Otherwise:

```r
setwd("~/path/to/my-dashboard")
```

### 3. Initialise renv

```r
renv::init()
```

This scans your code for `library()` / `require()` / `pkg::` calls, builds a
private library for the project, installs what it found, and writes
`renv.lock`.

It will ask how you want to handle the existing library. Choose:

> **1: Restore the project from the lockfile** — no
> **2: Install the packages, then snapshot** — :material-check: **yes, this one**

Expect this to take a while the first time. It's installing everything.

### 4. Confirm your app still works

```r
shiny::runApp()
```

This now runs against renv's private library rather than your system one, so
this is a genuine test: if a package was being loaded from somewhere renv
didn't find, you'll discover it here rather than 40 minutes into a build on the
server.

If something's missing, install it into the project and re-snapshot:

```r
renv::install("theMissingPackage")
renv::snapshot()
```

### 5. Check the lockfile exists

```r
file.exists("renv.lock")   # TRUE
```

Open it in a text editor if you like — it's readable JSON, and you should
recognise the package names in it.

---

## What renv leaves behind

`renv::init()` creates several things in your project:

```
my-dashboard/
├── renv.lock       ← the only one that matters for deployment
├── renv/           ← the private library and its machinery
├── .Rprofile       ← activates renv when R starts here
└── .Rprofile.d/    (sometimes)
```

**Only `renv.lock` needs to travel to the server.** The rest is machinery for
*your* machine.

!!! warning "Don't upload the `renv/` folder or `.Rprofile`"

    If those get onto the server, the app tries to activate a renv project
    whose package cache doesn't exist there, and fails to start with a
    misleading `there is no package called 'X'` error — for a package that
    installed perfectly during the build.

    If you're using Git, `renv::init()` writes a `.gitignore` that excludes the
    library automatically, so a `git clone` onto the server does the right
    thing. If you're uploading a zip or a folder, **delete `renv/` and
    `.Rprofile` from the copy you upload.**

---

## Special cases

??? note "My dashboard uses geospatial packages (`sf`, `terra`, `raster`, `stars`)"

    Good news: the tooling detects this automatically and switches to a base
    image that already has GDAL, GEOS and PROJ compiled in
    (`rocker/geospatial`). You don't have to configure anything.

    Two consequences:

    - **Builds are slower and larger.** Budget 45+ minutes for the first one.
    - **A lockfile matters more here than anywhere else.** Geospatial packages
      are the ones whose CRAN-latest versions most often demand newer system
      libraries than the image provides. If your build fails compiling `sf` or
      `terra`, that's what happened — see
      [Pinning R package versions](../reference/deployment.md#pinning-r-package-versions-to-avoid-cran-version-drift).

    One known case is handled for you: `terra` is automatically pinned to a
    version that compiles against the image's GDAL, *if* you have no lockfile
    of your own. A lockfile you supply is always honoured exactly as written.

??? note "My packages come from GitHub, Bioconductor, or a private repo"

    `renv` records the source, so `renv.lock` handles these correctly —
    `remotes::install_github("user/pkg")` shows up in the lockfile as a GitHub
    entry and gets restored from GitHub.

    A **private** repository will fail on the server, because it has no
    credentials. Either make the package public, or vendor the package source
    into your project.

??? note "I load packages dynamically"

    Code like this is invisible to any static scan:

    ```r
    for (p in config$packages) library(p, character.only = TRUE)
    ```

    A `renv.lock` fixes it — but only if the packages were installed when you
    ran `renv::snapshot()`. Run your app through every code path first, then
    snapshot.

??? note "renv::init() takes forever or fails to install something"

    Note which package failed, then install it by hand the way you normally
    would on your machine (often it needs a system library — `libgdal-dev`,
    `libudunits2-dev`, and so on). Then run `renv::snapshot()` to record it.

    If a package needs a **system** library, the server will need it too. Add a
    file called `apt.txt` to your project with one Ubuntu package name per
    line:

    ```
    libudunits2-dev
    libmagick++-dev
    ```

    Blank lines and `#` comments are fine.

??? note "I already have a `renv.lock` from a colleague"

    Use it — a supplied lockfile is restored exactly as written, and never
    second-guessed. But confirm it actually works first:

    ```r
    renv::restore()
    shiny::runApp()
    ```

---

## What to upload

From this page, your project needs:

- [x] `renv.lock` — **yes**
- [ ] `renv/` — no, exclude it
- [ ] `.Rprofile` — no, exclude it

---

Next → **[How your app finds its data](data-paths.md)**
