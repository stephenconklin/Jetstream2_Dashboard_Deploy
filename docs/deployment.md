# Deploying a dashboard/app to Jetstream2

A single Docker-based workflow for running an app on a Jetstream2 instance, generic across **R Shiny**, **Plotly Dash**, **Python Shiny**, and **Streamlit**. Assumes **one instance per project/researcher** — no multi-tenant package conflicts to manage, and the app is reachable directly on port 80 at the instance's fixed IP.

---

## Prerequisites

- Jetstream2 instance running **Ubuntu 22.04 (jammy)**, launched via Exosphere.
- A fixed/floating IP assigned to the instance.
- Security group allowing inbound **80/tcp** and **22/tcp**.
- SSH access as a sudo-capable user (Jetstream2's default `exouser`).
- Docker preinstalled (Jetstream2's standard Ubuntu image ships with it) — no install step needed. No `sudo`/root needed for anything in this workflow, assuming `exouser` is in the `docker` group, which is Jetstream2's default.

---

## Deploying your app

1. Clone this repo into your home directory on the instance:

   ```bash
   git clone https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy.git
   cd Jetstream2_Dashboard_Deploy
   ```

2. Get your project into [`deploy/app/`](../deploy/app/README.md) — this folder is gitignored (it's a drop-in slot, not something that ships in git), so a fresh clone always starts with it empty.

   - **To smoke-test the tooling itself** before pointing it at a real project, copy in one of the bundled examples (one per framework):

     ```bash
     cp -r examples/r-shiny-hello-world/* deploy/app/
     # or examples/dash-hello-world, examples/python-shiny-hello-world, examples/streamlit-hello-world
     ```

   - **To deploy a real project**, either copy/`git clone` it into `deploy/app/`, or skip this step and pass its path directly to `build_and_run.sh` in the next step (it copies the project into a temporary build context on its own, without needing anything placed under `deploy/app/`).

3. From the repo root:

   ```bash
   ./deploy/build_and_run.sh                         # deploys deploy/app/
   # or
   ./deploy/build_and_run.sh /path/to/other/project  # deploys a project elsewhere
   ```

   If you're triaging many candidate projects and just want to know what the script would do to each — detected framework, entry point, base image, whether the dependency file/`data/`/`apt.txt` are present — without actually building anything, add `--dry-run`:

   ```bash
   ./deploy/build_and_run.sh --dry-run /path/to/project
   ```

4. Visit `http://<instance-fixed-ip>/` in a browser.

**How the genericization works:**

- **Framework is auto-detected from the project's code, with a `FRAMEWORK=` override.** `build_and_run.sh` greps a project's `.R`/`.Rmd`/`.py` files for framework-specific signals — see [`deploy/lib/detect_framework.sh`](../deploy/lib/detect_framework.sh) for the exact patterns. This is content-based, not filename-based: `app.py` alone is ambiguous across Dash/Python Shiny/Streamlit (and plain Flask), so detection always inspects imports (`import dash`, `from shiny import App`, `import streamlit`), with Streamlit's `streamlit_app.py` filename only as a secondary signal. If detection finds conflicting signals in different files, or nothing at all, it fails loudly with an actionable message rather than guessing — set `FRAMEWORK=r-shiny|dash|python-shiny|streamlit` to force a choice and bypass detection entirely.
- **One Dockerfile per framework** (`deploy/docker/Dockerfile.r-shiny`, `.dash`, `.python-shiny`, `.streamlit`), selected via `docker build -f` once the framework is known. Each keeps its own build steps simple rather than one Dockerfile branching internally across 4 different ecosystems.
- **Base image is auto-detected for R Shiny, with a swappable override; fixed for the 3 Python frameworks.** For R Shiny, `build_and_run.sh` scans the project's `.R`/`.Rmd` files for `library()`/`require()`/`::` usage of `sf`, `terra`, `raster`, `stars`, `rgdal`, or `rgeos`, and picks `rocker/geospatial:4.4.1` automatically when it finds one — otherwise it falls back to `rocker/r-ver:4.4.1` (bare R). This is a best-effort heuristic (a regex over source files, not a real dependency graph), so set `BASE_IMAGE` explicitly to skip detection — e.g. `BASE_IMAGE=rocker/shiny-verse ./build_and_run.sh` for a tidyverse-heavy project the scan wouldn't otherwise flag. Dash/Python Shiny/Streamlit default to `python:3.11-slim`, also overridable via `BASE_IMAGE`.
  - **Version-drift warning for R geospatial projects without a lockfile.** If the same scan detects geospatial R packages but the project has no `renv.lock`, `build_and_run.sh` prints a warning before building: without a lockfile, `install_deps.R` always installs whatever's newest on CRAN, and a new release of `sf`/`terra`/etc. can require a newer GDAL/GEOS/PROJ than the fixed base image ships — breaking a build that worked previously, with no code change on your end. This can't be predicted reliably ahead of time (only actually compiling proves it), so the warning is just a nudge, not a guarantee. See "Pinning R package versions to avoid CRAN version drift" below.
- **A baseline of common compile-time headers is always installed** in `Dockerfile.r-shiny` (`libuv`, `zlib`, `openssl`, `libcurl`, `libxml2`, `fontconfig`/`freetype`/`harfbuzz`/`fribidi`, `png`/`jpeg`). These aren't optional because `shiny` itself won't install without them — its dependency `httpuv` needs `libuv`/`zlib` to compile, and common plotting packages need the font-rendering libs. Anything beyond this baseline (GDAL, Java, ImageMagick, …) is either covered by a `BASE_IMAGE` override or the project's `apt.txt`. The 3 Python Dockerfiles rely on `python:3.11-slim` + pip wheels for the common case, with `apt.txt` as the same escape hatch.
- **R packages are auto-detected, not hardcoded; Python's dependency file is required, not optional.** [`install_deps.R`](../deploy/docker/install_deps.R) (R Shiny only) runs at build time: if the project ships an `renv.lock`, it restores those exact versions; otherwise it statically scans the project's `.R`/`.Rmd` files for `library()`/`require()` calls (via `renv::dependencies()`, which doesn't require the project to have ever used `renv`) and installs whatever the base image doesn't already provide. If any required package is still missing afterward, the script fails loudly — `install.packages()`/`renv::restore()` otherwise print an error but exit 0, which would let `docker build` report success on a broken image. **Python has no equivalent fallback**: there's no reliable way to infer a PyPI package name from an import statement (e.g. `import cv2` comes from the package `opencv-python`, not `cv2`), so `requirements.txt` is required for Dash/Python Shiny/Streamlit — `build_and_run.sh` fails with an actionable message (and the reasoning above) if it's missing, rather than attempting any auto-scan.
- **A missing `renv.lock` (R Shiny only) is generated automatically, before the real `docker build`.** If the project has no `renv.lock`, `build_and_run.sh` builds `Dockerfile.r-shiny`'s `deps-base` stage (the apt/compile-header environment the real build will use) and runs [`generate_lock.R`](../deploy/docker/generate_lock.R) inside it via `docker run`: it scans dependencies the same way `install_deps.R` does, installs them into a throwaway library, and `renv::snapshot()`s the result into the project directory — without leaving any `renv/` scaffold or `.Rprofile` behind, just the lockfile. The real build then finds that lockfile and restores from it via `install_deps.R`, so every build is reproducible by default, not only ones where you ran the manual pinning workflow yourself. This roughly doubles R Shiny build time when no lockfile is present (dependencies get installed once to generate the lock, once more via `renv::restore()` in the real build) — the tradeoff for reproducibility becoming the default instead of opt-in. It does **not** resolve a genuine compile failure (e.g. a CRAN-latest package needing a newer system library than the image ships) — that still surfaces as a failure of this preflight step, just earlier and with cleaner output than a `docker build` failure buried deep in log output. See "Pinning R package versions to avoid CRAN version drift" below for what to do when that happens.
- **Repos always resolve against live CRAN, not a frozen snapshot** (R Shiny only). Many R base images (`rocker/geospatial` included) point the default `"CRAN"` repo at a Posit Package Manager snapshot frozen on the date the image was built — and a `renv.lock` itself also embeds the exact repository URLs active when it was written (its `"R"$"Repositories"` section), which `renv::restore()` prefers over the session's `options("repos")`. `install_deps.R` sets `options(renv.config.repos.override = "https://cloud.r-project.org")` before installing anything, which forces `renv::restore()` to ignore both frozen sources and resolve every package against the real, rolling CRAN mirror instead. Without this, a `renv.lock`-pinned package version released after either snapshot date would 404 indefinitely — plain `options(repos = ...)` alone does *not* fix this, since `renv::restore()` doesn't consult it when the lockfile has its own recorded repository URLs.
- **Extra system libraries are opt-in, for every framework.** An optional `apt.txt` in the project directory (one package per line) covers anything beyond the baseline and `BASE_IMAGE` — e.g. `default-jdk` for `rJava`, `libgdal-dev` for a Python `geopandas` dependency. Empty or absent is fine.
- **Entry point convention is each framework's own, detected beyond the basic case.** R Shiny: `app.R`, or a `ui.R`/`server.R` pair, or an R Markdown Shiny document (`runtime: shiny` in its YAML front matter, e.g. a flexdashboard) — a golem-packaged app that only ships `inst/app.R` gets a specific error telling you to add a root-level shim, rather than a generic "nothing found." Dash/Python Shiny: `app.py`. Streamlit: `streamlit_app.py` (or `app.py`). No per-project server config is needed since the tool always serves a single app at `/`.
- **The project's code is baked into the image** at build time (not bind-mounted), so the resulting image is self-contained and versioned.
- **Data is bind-mounted AND passed as a container env var, never baked into the image.** If the project has a `data/` directory, `build_and_run.sh` bind-mounts a host path over a framework-specific target (`/srv/shiny-server/data` for R Shiny, `/app/data` for the 3 Python frameworks) at runtime instead of copying its contents into the image, and also sets a `DATA_DIR` env var inside the container pointing at that same path — set `DATA_DIR=/path/to/data ./build_and_run.sh` to specify the host path non-interactively, or leave `DATA_DIR` unset and the script will prompt for it (with a nudge toward the typical Jetstream2 storage volume location, `/media/volume/<volume-name>/...`). Either way, updating the data only needs a `docker restart`, not a rebuild. If the project has no `data/` directory, nothing is prompted or mounted.
  - **What this requires of the app's code:** an R Shiny app must reference files with a project-root-relative path — e.g. `read_csv("data/wq_baltimore.csv")` — since that's what resolves to Shiny Server's `app_dir` (`/srv/shiny-server`) and where the mount lands. A Python app (Dash/Python Shiny/Streamlit) can instead just read `os.environ["DATA_DIR"]` directly — more portable, since it doesn't hardcode a path convention. An app that already has its own env var name for this (e.g. a `VI_DATACUBE_ROOT`-style variable) can bridge with a one-line shim at the top of its entry file: `os.environ.setdefault("VI_DATACUBE_ROOT", os.environ["DATA_DIR"])`.
- **Each framework has its own internal container port**, looked up in one place (`container_port_for_framework()` in [`deploy/lib/common.sh`](../deploy/lib/common.sh)): 3838 for Shiny Server, 8050 for Dash (gunicorn), 8000 for Python Shiny (`shiny run`), 8501 for Streamlit. Always mapped to host port 80 via `docker run -p 80:<port>` — Docker's port mapping handles the privileged bind, so no Nginx/reverse proxy is needed.
- **Network flakiness is retried, not treated as fatal.** Deploying many different projects means hitting more transient apt/pip/CRAN mirror hiccups over time, so several layers retry before giving up: `apt_retry.sh` (shared by all 4 Dockerfiles) wraps every `apt-get install` with up to 3 attempts (10s backoff), `install_deps.R` retries `renv::restore()`/`install.packages()` up to 3 times (checking what's actually still missing afterward, since neither throws an R error on partial failure), and `build_and_run.sh` itself retries a failed `docker build` up to 3 times (10s backoff) in case the flakiness happens outside those inner retry windows (e.g. pulling `BASE_IMAGE`).
- **A post-run smoke test catches runtime crashes a successful build can't see.** A clean `docker build` + `docker run -d` only proves the image is valid and the container started — not that the app process inside stayed up. After starting the container, `build_and_run.sh` polls `http://localhost:80/` for up to 60s; if the app never responds (e.g. a missing data file or an app error crashed it seconds after startup), it prints the last 50 lines of `docker logs` and exits non-zero instead of reporting success. Requires `curl` on the host — if it's missing, the smoke test is skipped with a warning rather than treated as a hard dependency.
- Container always runs with `--restart unless-stopped`.

**To update the app after a code change:** re-run `build_and_run.sh`. It rebuilds the image (Docker layer caching keeps this fast unless the system/package layers changed) and replaces the running container.

**To swap in a completely different app on the same instance:** point `build_and_run.sh` at the new project instead — e.g. `./deploy/build_and_run.sh /path/to/other-project [image-name]`. The default image/container name is `dashboard-app` when you don't pass one, but you don't need to keep it consistent across deploys: `run_container()` in `common.sh` runs `docker rm -f <container-name>` for the new name, then also removes *any other* container currently bound to host port 80 (`docker ps -aq --filter "publish=80"`), regardless of its name. This cleanly stops and removes whatever's currently running — no manual cleanup needed — and the old image tag just gets overwritten rather than accumulating on disk.

This tool is scoped to one app at a time per instance (see "Assumes one instance per project/researcher" at the top of this doc) — it doesn't support two apps running simultaneously: every container binds host port 80, so the port-based cleanup above is what prevents a differently-named second deploy from failing with "port is already allocated" or leaving the old container squatting on port 80. If you want two dashboards reachable at once, provision a second Jetstream2 instance rather than trying to run both here.

**To update data when using `DATA_DIR`:** just update the files at that host path and `docker restart <container-name>` — no rebuild needed, since the data is bind-mounted rather than baked in.

**Known limitations:**
- No TLS, since there's no domain to challenge against yet — see "Open items" below.
- R dependency auto-detection is static analysis — it won't catch packages loaded dynamically (e.g. via a variable passed to `library()`), so an unusual project may occasionally need an explicit `renv.lock` instead of relying on the scan.
- Framework detection is a regex/content-based heuristic, not a real dependency or AST analysis — it can occasionally get an unusual project wrong or find a genuine ambiguity, which is exactly what the `FRAMEWORK=` override exists for.

---

## Choosing package versions

Currently pinned:
- Shiny Server `1.5.22.1017` (R Shiny only) — check [posit.co/download/shiny-server](https://posit.co/download/shiny-server) for the current release before provisioning new instances.
- `rocker/r-ver:4.4.1` (R Shiny default) — check [rocker-project.org](https://rocker-project.org) for the R version to standardize on, or the R version your `BASE_IMAGE` override ships.
- `python:3.11-slim` (Dash/Python Shiny/Streamlit default).

Update the version strings in the relevant Dockerfile's `ARG`/`FROM` lines (and this doc, if standardizing on a new default across frameworks) together, so a version bump doesn't silently drift out of sync with what's documented here.

---

## Pinning R package versions to avoid CRAN version drift

`build_and_run.sh` now generates a `renv.lock` automatically when a project doesn't ship one (see "A missing `renv.lock` is generated automatically" above), so most projects never need this section. It's the fallback for when that automatic step itself fails to compile a package — most commonly a geospatial package (`sf`, `terra`, `raster`, …) whose CRAN-latest release needs a newer GDAL/GEOS/PROJ than the pinned `BASE_IMAGE` provides. That failure means CRAN shipped a package release requiring newer system libraries than this image has, with no change to the project's own code — and it can newly appear on a project that built fine last month, simply because CRAN moved.

To pin an older, compatible version by hand and get a working build:

1. Start an interactive R session in the *same* base image the deploy will actually use, so whatever compiles here is guaranteed to compile at deploy time too — a lockfile only records version numbers, not whether they'll build against this image's system libraries:
   ```bash
   docker run --rm -it -v /path/to/project:/app rocker/geospatial:4.4.1 bash
   cd /app && R
   ```
2. **Do not run `renv::init()` (or anything else that writes `.Rprofile`/`renv/`) inside `/app`.** That scaffold is bind-mounted straight onto the host project directory, and if it's ever left there, `build_and_run.sh` will copy it into the final image (`COPY app/ /srv/shiny-server/`). At runtime, Shiny Server sources that `.Rprofile` and activates a renv project whose package cache was built as `root` during the interactive session — but Shiny Server runs each app as the unprivileged `shiny` user, which can't traverse into `root`'s home directory to follow the cache symlinks. The app fails to start with a misleading `there is no package called 'X'` error for whatever package renv resolved that way, even though the package installed successfully during the build. Install into an isolated library instead, and only ever write `renv.lock` back to the project directory:
   ```r
   options(repos = c(CRAN = "https://cloud.r-project.org"))
   if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv")

   lib_dir <- tempfile("renv-lib-")
   dir.create(lib_dir)
   .libPaths(c(lib_dir, .libPaths()))
   ```
3. Install the project's dependencies with `renv::install()` (not base `install.packages()` — once `renv` is loaded, a raw `install.packages(url, repos = NULL, type = "source")` call can fail with a cryptic `object '..md5..' not found` error). `renv::install()` accepts a `package@version` syntax that resolves directly against CRAN's archive, so there's no need to hand-construct archive URLs:
   ```r
   # for a package that needs an older, compatible version:
   renv::install("terra@1.8-15", library = lib_dir)
   # then the rest of the project's normal library()'d packages as usual
   renv::install(c("shiny", "sf", "..."), library = lib_dir)
   ```
   If a *different* package's dependency floor later forces `terra` back up to a version that doesn't compile (e.g. `Installation of 'terra@1.8-15' was requested, but ... requires terra >= 1.8-21`), keep testing progressively newer `terra` versions until one both compiles *and* satisfies whatever's demanding a newer floor — or pin that other package to an older version instead, the same way. **Always re-list every version-pinned package explicitly in each subsequent `renv::install()` call** — if you omit it, `renv` will silently re-resolve it to CRAN-latest as an unconstrained transitive dependency and can undo the pin.
4. Once everything installs without error, snapshot — passing `library` explicitly so `renv` looks at the isolated library, and `lockfile` so it writes only `renv.lock`, not a full project scaffold:
   ```r
   renv::snapshot(project = ".", library = lib_dir, lockfile = "renv.lock", prompt = FALSE)
   ```
   This writes `renv.lock` into the project directory (visible on the host too, via the bind mount) — nothing else.
5. Make sure `renv.lock` ships with the deployed project — commit it to the app's own repo if you maintain it, or otherwise just make sure it's present in whatever directory you pass to `build_and_run.sh` (it doesn't need to be tracked by the app's upstream repo; `install_deps.R` only checks whether the file exists on disk at build time).

From then on, `install_deps.R` detects the lockfile and calls `renv::restore()` instead of installing CRAN-latest, so rebuilds are reproducible regardless of what CRAN does in the meantime.

---

## Pinning Python package versions

For Dash/Python Shiny/Streamlit, `requirements.txt` is the direct equivalent of an R `renv.lock`, and — unlike R — it's required, not optional (see "R packages are auto-detected, not hardcoded; Python's dependency file is required, not optional" above). To generate one from a known-working environment:

```bash
pip freeze > requirements.txt
```

Run this inside whatever environment (virtualenv, conda env, or the same base image used for deployment) actually has the app working, so the pinned versions are ones you've confirmed work together. Unlike R's geospatial packages, the 3 Python frameworks and their typical dependencies are mostly pure-Python or ship prebuilt wheels, so version drift against the base image's system libraries is a much rarer problem here — but a project depending on something that compiles from source (e.g. certain `geopandas`/GDAL-adjacent packages) can hit the same class of issue, and the same "pin it explicitly" fix applies.

---

## Open items / possible future work

- TLS once a domain is available (Nginx sidecar or Caddy in front of the container).
- A curated list of known-good `BASE_IMAGE` overrides per framework for common heavier dependencies (e.g. a GDAL-ready Python image for geospatial Dash/Streamlit apps, analogous to `rocker/geospatial` for R).
