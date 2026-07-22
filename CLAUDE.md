# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Deployment tooling for running a dashboard/app on a Jetstream2 instance — not an app itself. There is no application code here to build/test/lint in the usual sense; the "product" is a shell script + a Dockerfile per framework that take an arbitrary R Shiny, Plotly Dash, Python Shiny, or Streamlit project as input and get it reachable in a browser on port 80. `examples/*/` are minimal self-test fixtures (one per framework), not real features.

## Commands

Smoke-test the pipeline end-to-end with a bundled example (one per framework):

```bash
cp -r examples/r-shiny-hello-world/* deploy/app/       && ./deploy/build_and_run.sh
cp -r examples/dash-hello-world/* deploy/app/          && ./deploy/build_and_run.sh
cp -r examples/python-shiny-hello-world/* deploy/app/  && ./deploy/build_and_run.sh
cp -r examples/streamlit-hello-world/* deploy/app/     && ./deploy/build_and_run.sh
```

Deploy an arbitrary project (either drop it into `deploy/app/` first, or pass its path directly — `build_and_run.sh` copies it into a temp build context either way):

```bash
./deploy/build_and_run.sh /path/to/project [image-name]
```

Force a framework instead of relying on auto-detection (useful if detection guesses wrong, or a project is genuinely ambiguous):

```bash
FRAMEWORK=dash ./deploy/build_and_run.sh /path/to/project
```

Override the base image (e.g. R projects needing heavier system libs pre-built):

```bash
BASE_IMAGE=rocker/geospatial:4.4.1 ./deploy/build_and_run.sh
```

Triage a project without building anything (reports detected framework, entry point, base image, dependency-file/`data/`/`apt.txt` presence):

```bash
./deploy/build_and_run.sh --dry-run /path/to/project
```

There's no CI, test suite, or linter in this repo — verifying a change means actually running the command above (or reasoning carefully through the shell script / Dockerfile logic, since a real run requires Docker).

## Architecture

One script, [`deploy/build_and_run.sh`](deploy/build_and_run.sh), auto-detects which of 4 frameworks a dropped-in project is, then builds and runs it with one of 4 per-framework Dockerfiles, bound to host port 80. Shared logic (retries, the `--dry-run` summary, the `DATA_DIR` prompt, the build/run/smoke-test steps) lives in `deploy/lib/common.sh`; framework detection lives in `deploy/lib/detect_framework.sh`. Design principle, unchanged from when this only supported R Shiny: **nothing about a specific target project is hardcoded** — only framework-level differences are.

- **Framework auto-detection is content-based, not filename-based.** `detect_framework()` (in `deploy/lib/detect_framework.sh`) greps a project's `.R`/`.Rmd`/`.py` files for framework-specific signals — `app.R`/`ui.R`+`server.R`/`.Rmd` with `runtime: shiny` for R Shiny; `import dash` + `server = app.server` for Dash; `from shiny import App` + a top-level `app = App(...)` for Python Shiny; `import streamlit` for Streamlit. A bare `app.py` is ambiguous across 3 of these frameworks (and Flask), so filename alone is never trusted. If detection is inconclusive or conflicting signals are found across different files, it fails loudly rather than guessing, and tells the user to set `FRAMEWORK=r-shiny|dash|python-shiny|streamlit` to force a choice.
- **One Dockerfile per framework** (`deploy/docker/Dockerfile.{r-shiny,dash,python-shiny,streamlit}`), selected by `build_and_run.sh` via `docker build -f`. Keeps each framework's build steps simple rather than one Dockerfile branching internally on 4 different ecosystems.
- **R packages are auto-detected, not hardcoded; Python packages are not.** `install_deps.R` (R Shiny only) restores `renv.lock` if the project ships one; otherwise it statically scans `.R`/`.Rmd` files via `renv::dependencies()` and installs whatever's missing, failing loudly if anything is still missing afterward (since `install.packages()`/`renv::restore()` normally exit 0 even on partial failure). Python has no equivalent static-scan fallback — there's no reliable way to infer a PyPI package name from an import statement (e.g. `import cv2` comes from `opencv-python`) — so `requirements.txt` is **required** for Dash/Python Shiny/Streamlit; `build_and_run.sh` fails with an actionable message if it's missing.
- **A missing `renv.lock` is generated automatically, before the real build.** `Dockerfile.r-shiny` is split into a `deps-base` stage (apt headers, Shiny Server, project `apt.txt`) and a `final` stage built on top of it. If a project has no `renv.lock`, `generate_renv_lock()` (in `common.sh`) builds just `deps-base` via `docker build --target deps-base`, then runs `deploy/docker/generate_lock.R` inside it via `docker run` — scanning deps the same way `install_deps.R` does, installing them into a throwaway library, and `renv::snapshot()`-ing the result into the project directory (no `renv/` scaffold or `.Rprofile` left behind, just the lockfile). The real build then restores from that lockfile via `install_deps.R`. This makes reproducible builds the default rather than something requiring a manual `renv::snapshot()` runbook — at the cost of roughly doubling R Shiny build time when no lockfile exists (deps get installed once to generate the lock, once more to restore it). It does not auto-resolve a genuine compile failure (e.g. `terra` needing a newer GDAL than `BASE_IMAGE` ships) — that still surfaces as a failure of this preflight step, same as it would in the main build, just earlier and with cleaner output.
- **System libraries are layered, not project-specific.** Each Dockerfile installs its own baseline (R Shiny: compile-time headers `shiny`/`httpuv` need; Python frameworks: whatever `python:3.11-slim` + pip wheels don't already cover). Beyond that: a `BASE_IMAGE` build-arg override (R default `rocker/r-ver:4.4.1`, auto-upgraded to `rocker/geospatial:4.4.1` if geospatial R packages are detected; Python default `python:3.11-slim`) for heavier pre-built environments, and an optional project-supplied `apt.txt` (one package per line, supported by all 4 Dockerfiles) for anything else. Don't add project-specific system packages to a Dockerfile itself — they belong in one of these two extension points.
- **`deploy/app/` is a gitignored drop-in slot**, not a place to commit code — only its `README.md` is tracked (see `.gitignore`). Don't add real app code there expecting it to persist/ship.
- **Entry point convention is each framework's own** (R Shiny: `app.R`/`ui.R`+`server.R`/`.Rmd` with `runtime: shiny`; Dash/Python Shiny: `app.py`; Streamlit: `streamlit_app.py` or `app.py`) — no per-project server config is needed since the tool serves a single app at `/`. `build_and_run.sh` gives a specific, actionable error for a golem-packaged R app that only ships `inst/app.R` (needs a root-level shim), rather than a generic "nothing found" message.
- **Data is bind-mounted AND passed as an env var, never baked into the image.** If a project has a `data/` directory, `build_and_run.sh` mounts a host path (`DATA_DIR`, prompted for interactively if unset) onto a framework-specific target (`/srv/shiny-server/data` for R Shiny, `/app/data` for the 3 Python frameworks — see `container_data_mount_target_for_framework()` in `common.sh`) AND sets a `DATA_DIR` env var inside the container pointing at that same path. R Shiny apps read it via a `data/`-relative path (matching Shiny Server's `app_dir`); Python apps can read `os.environ["DATA_DIR"]` directly (an app with its own env var name, e.g. `VI_DATACUBE_ROOT`, can bridge with a one-line `os.environ.setdefault(...)` shim).
- **Each framework has its own internal container port**, looked up in one place (`container_port_for_framework()` in `common.sh`: 3838 R Shiny / 8050 Dash / 8000 Python Shiny / 8501 Streamlit) and always mapped to host port 80.
- **Network flakiness is retried, not fatal.** `apt_retry.sh` (shared by all 4 Dockerfiles) wraps every `apt-get install` with a few retries, `install_deps.R` retries `renv::restore()`/`install.packages()` based on what's still missing afterward (these don't throw R errors on partial failure), and `build_and_run.sh` retries a failed `docker build` itself. Across many different projects, transient mirror/network hiccups are common enough to be worth a few retries before failing a whole build.
- **A post-run smoke test catches runtime crashes a successful build can't see.** After `docker run -d`, `build_and_run.sh` polls the container over HTTP for ~60s before declaring success; if the app process crashed at startup (e.g. a missing data file, or an app error), it dumps `docker logs --tail 50` and exits non-zero instead of silently reporting the container as "running."

When changing a pinned version (Shiny Server, an R/Python base image), keep the relevant Dockerfile's `ARG`/`FROM` line and `docs/deployment.md`'s version notes in sync.

## Design constraints to keep in mind

- One instance = one app; no multi-tenant/multi-app support is in scope.
- No TLS currently (no domain to challenge against) — see "Open items" in `docs/deployment.md` before adding HTTPS support.
- Framework detection is a best-effort heuristic (regex over source files), not a real dependency/AST analysis — the `FRAMEWORK=` override exists specifically for when it guesses wrong.
