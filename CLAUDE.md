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

Lint the shell scripts (the only automated check in the repo):

```bash
./deploy/lint.sh                      # shellcheck -x over every tracked .sh
git config core.hooksPath .githooks   # one-time: run it automatically pre-commit
```

There's no CI and no test suite — beyond `lint.sh`, verifying a change means actually running one of the commands above (or reasoning carefully through the shell script / Dockerfile logic, since a real run requires Docker). Note `lint.sh` catches shell defects only; it says nothing about whether an image builds or an app starts.

Two shellcheck conventions worth knowing before editing these scripts: `build_and_run.sh` carries a file-wide `source-path=SCRIPTDIR` directive so `-x` can follow `lib/*.sh` (without it, every variable the sourced functions consume is reported as an unused assignment), and **any comment line beginning with the word "shellcheck" is parsed as a directive** — prose mentioning the tool must not start a line with its name, or the file fails to parse.

## Architecture

One script, [`deploy/build_and_run.sh`](deploy/build_and_run.sh), auto-detects which of 4 frameworks a dropped-in project is, then builds and runs it with one of 4 per-framework Dockerfiles, bound to host port 80. Shared logic (retries, the `--dry-run` summary, the `DATA_DIR` prompt, the build/run/smoke-test steps) lives in `deploy/lib/common.sh`; framework detection lives in `deploy/lib/detect_framework.sh`. Design principle, unchanged from when this only supported R Shiny: **nothing about a specific target project is hardcoded** — only framework-level differences are.

- **Framework auto-detection is content-based, not filename-based.** `detect_framework()` (in `deploy/lib/detect_framework.sh`) greps a project's `.R`/`.Rmd`/`.py` files for framework-specific signals — `app.R`/`ui.R`+`server.R`/`.Rmd` with `runtime: shiny` for R Shiny; `import dash` + `server = app.server` for Dash; `from shiny import App` + a top-level `app = App(...)` for Python Shiny; `import streamlit` for Streamlit. A bare `app.py` is ambiguous across 3 of these frameworks (and Flask), so filename alone is never trusted. If detection is inconclusive or conflicting signals are found across different files, it fails loudly rather than guessing, and tells the user to set `FRAMEWORK=r-shiny|dash|python-shiny|streamlit` to force a choice.
- **One Dockerfile per framework** (`deploy/docker/Dockerfile.{r-shiny,dash,python-shiny,streamlit}`), selected by `build_and_run.sh` via `docker build -f`. Keeps each framework's build steps simple rather than one Dockerfile branching internally on 4 different ecosystems.
- **R packages are auto-detected, not hardcoded; Python packages are not.** `install_deps.R` (R Shiny only) restores `renv.lock` if the project ships one; otherwise it statically scans `.R`/`.Rmd` files via `renv::dependencies()` and installs whatever's missing, failing loudly if anything is still missing afterward (since `install.packages()`/`renv::restore()` normally exit 0 even on partial failure). Python has no equivalent static-scan fallback — there's no reliable way to infer a PyPI package name from an import statement (e.g. `import cv2` comes from `opencv-python`) — so `requirements.txt` is **required** for Dash/Python Shiny/Streamlit; `build_and_run.sh` fails with an actionable message if it's missing. One fallback exists: a project managed with `uv` instead of pip (`pyproject.toml` + `uv.lock`, no `requirements.txt`) gets one generated automatically — `generate_requirements_from_uv()` (in `common.sh`) runs `uv export --no-hashes --frozen -o requirements.txt` via astral's official `ghcr.io/astral-sh/uv` image before the real build, since `uv.lock` is already a fully-resolved, pinned dependency set and just needs reformatting, not re-resolving.
- **A missing `renv.lock` is generated automatically, before the real build.** `Dockerfile.r-shiny` is split into a `deps-base` stage (apt headers, Shiny Server, project `apt.txt`) and a `final` stage built on top of it. If a project has no `renv.lock`, `generate_renv_lock()` (in `common.sh`) builds just `deps-base` via `docker build --target deps-base`, then runs `deploy/docker/generate_lock.R` inside it via `docker run` — scanning deps the same way `install_deps.R` does, installing them into a throwaway library, and `renv::snapshot()`-ing the result into the project directory (no `renv/` scaffold or `.Rprofile` left behind, just the lockfile). The real build then restores from that lockfile via `install_deps.R`. This makes reproducible builds the default rather than something requiring a manual `renv::snapshot()` runbook — at the cost of roughly doubling R Shiny build time when no lockfile exists (deps get installed once to generate the lock, once more to restore it). It does not auto-resolve a genuine compile failure in general (e.g. some other package needing a newer system library than `BASE_IMAGE` ships) — that still surfaces as a failure of this preflight step, same as it would in the main build, just earlier and with cleaner output. One specific, known case of this *is* handled automatically: `generate_lock.R` and `install_deps.R` check `gdal-config --version` before installing, and pin `terra` to `1.8-5` instead of CRAN-latest when it's older than `3.8.0` — the GDAL version `terra`'s C++ source started requiring for a 3-argument `GDALMDArray::AsClassicDataset()` call, which `rocker/geospatial:4.4.1`'s GDAL 3.4.1 doesn't have. This auto-pin only applies when a project has no `renv.lock` of its own; a project-supplied lockfile is restored exactly as written (`install_deps.R` never overrides a version the project explicitly pinned), so if that lockfile itself pins a `terra` version newer than `1.8-5` against this same old GDAL, `install_deps.R` instead prints an upfront warning naming the pinned version and pointing at the manual pinning runbook, before `renv::restore()` burns through 3 retries discovering the same compile failure. See the `KNOWN_COMPATIBLE_VERSIONS` table in both scripts and docs/deployment.md's "Pinning R package versions" section.
- **System libraries are layered, not project-specific.** Each Dockerfile installs its own baseline (R Shiny: compile-time headers `shiny`/`httpuv` need; Python frameworks: whatever `python:3.11-slim` + pip wheels don't already cover). Beyond that: a `BASE_IMAGE` build-arg override (R default `rocker/r-ver:4.4.1`, auto-upgraded to `rocker/geospatial:4.4.1` if geospatial R packages are detected; Python default `python:3.11-slim`) for heavier pre-built environments, and an optional project-supplied `apt.txt` (one package per line, supported by all 4 Dockerfiles) for anything else. Don't add project-specific system packages to a Dockerfile itself — they belong in one of these two extension points.
- **The temp build context is assembled by `tar` with excludes, not `cp -R`.** `build_image()` copies the project through a `tar | tar` pipe so `data/`, `.git`, `.venv`, `.env`, `__pycache__`, `node_modules`, and `.Rproj.user` are skipped *during* the copy rather than deleted after it, and writes a matching `.dockerignore` into the context as a second line of defence. Two reasons, both real: these projects routinely carry multi-GB datasets, and copying one into `/tmp` only to delete it (or, in the R deps-base preflight, not delete it at all) fills the disk and stalls the context upload; and `COPY app/ .` would otherwise bake `.git` history and any stray `.env` into the image layers. The context is tracked in a global `BUILD_CTX` cleaned up by an `EXIT`/`INT`/`TERM` trap, since a `RETURN` trap doesn't fire on `exit` and leaked a full project copy on every failure path.
- **`deploy/app/` is a gitignored drop-in slot**, not a place to commit code — only its `README.md` is tracked (see `.gitignore`). Don't add real app code there expecting it to persist/ship.
- **Entry point convention is each framework's own** (R Shiny: `app.R`/`ui.R`+`server.R`/`.Rmd` with `runtime: shiny`; Dash/Python Shiny: `app.py`; Streamlit: `streamlit_app.py` or `app.py`) — no per-project server config is needed since the tool serves a single app at `/`. `build_and_run.sh` gives a specific, actionable error for a golem-packaged R app that only ships `inst/app.R` (needs a root-level shim), rather than a generic "nothing found" message.
- **Data is bind-mounted AND passed as an env var, never baked into the image.** If a project has a `data/` directory, `build_and_run.sh` mounts a host path (`DATA_DIR`, prompted for interactively if unset) onto a framework-specific target (`/srv/shiny-server/data` for R Shiny, `/app/data` for the 3 Python frameworks — see `container_data_mount_target_for_framework()` in `common.sh`) AND sets a `DATA_DIR` env var inside the container pointing at that same path. R Shiny apps read it via a `data/`-relative path (matching Shiny Server's `app_dir`); Python apps can read `os.environ["DATA_DIR"]` directly (an app with its own env var name, e.g. `VI_DATACUBE_ROOT`, can bridge with a one-line `os.environ.setdefault(...)` shim).
- **Each framework has its own internal container port**, looked up in one place (`container_port_for_framework()` in `common.sh`: 3838 R Shiny / 8050 Dash / 8000 Python Shiny / 8501 Streamlit) and always mapped to host port 80.
- **Redeploying replaces the running container in place.** `run_container()` runs `docker rm -f "$CONTAINER_NAME"` before every `docker run` (default name/image `dashboard-app`, or an explicit image-name argument), then also removes *any other* container currently bound to host port 80 (`docker ps -aq --filter "publish=80"`). Since every container binds port 80 unconditionally and this tool is scoped to one running app per instance at a time (see "Design constraints" below), the port-based cleanup means re-running `build_and_run.sh` against a *different* project — even under a different image-name — cleanly tears down whatever's currently running and swaps in the new one, rather than failing with "port is already allocated."
- **Network flakiness is retried, not fatal.** `apt_retry.sh` (shared by all 4 Dockerfiles) wraps every `apt-get install` with a few retries, `install_deps.R` retries `renv::restore()`/`install.packages()` based on what's still missing afterward (these don't throw R errors on partial failure), and `build_and_run.sh` retries a failed `docker build` itself. Across many different projects, transient mirror/network hiccups are common enough to be worth a few retries before failing a whole build.
- **A project's `apt.txt` is read through `apt_retry.sh --from-file`, never passed to apt raw.** All 4 Dockerfiles call it the same way (`RUN apt_retry.sh --from-file /tmp/apt.txt`), and the sanitizing lives in that one script rather than being repeated per-Dockerfile: it strips CRLF line endings (a Windows-edited `apt.txt` otherwise makes apt report "Unable to locate package curl" for a correctly-spelled `curl\r`) and `#` comments (otherwise installed as literal packages named `#`, `a`, `comment`). Absent or package-free files exit 0, so an empty `apt.txt` stays a no-op.
- **R Shiny builds force `--platform linux/amd64` on a non-amd64 Docker host** (`resolve_build_platform()` in `common.sh`), because Shiny Server is published only as an amd64 `.deb` — without it the build dies mid-way on an Apple Silicon Mac with an error that never mentions architecture. Jetstream2 is x86_64, so this only affects local testing; `BUILD_PLATFORM` overrides it, and the 3 Python frameworks are unaffected.
- **`--dry-run --porcelain` is the machine-readable interface** (`print_dry_run_porcelain()` in `common.sh`), and the only structured contract this repo offers. `key=value`, not JSON, so bash needs no escaping. It exists so `deploy/gui/` never greps human-readable prose — which means **the prose messages stay free to change**. When adding a fact to the dry-run summary, add it to both printers; `DEPS_STATUS` (sentence) and `DEPS_STATE` (enum) are deliberately parallel for this reason. `container_port`/`data_mount_target` are emitted from the existing lookup functions so callers never hardcode ports or mount paths.
- **`--dry-run` must stay strictly read-only.** `build_and_run.sh` computes everything the summary needs *before* the dry-run gate and does all side-effecting work (the uv `requirements.txt` generation, the missing-dependency-file hard failure, `renv.lock` generation, the `DATA_DIR` prompt) after it. Adding a new preflight step means putting it below that gate and reporting its *intent* above it.
- **`apt_retry.sh` also rewrites apt sources from `http://` to `https://` before every install.** Some Jetstream2 instances block outbound port 80 at the security-group level while leaving 443 open; Ubuntu/Debian's default sources point at `http://` mirrors, so apt hangs/times out on every attempt regardless of retries until this rewrite is in place. Handles both the classic `sources.list` format and the deb822 `*.sources` format newer releases use, and is idempotent (`http://` isn't a substring of `https://`).
- **A post-run smoke test catches startup crashes a successful build can't see.** After `docker run -d`, `build_and_run.sh` polls the container over HTTP for ~60s before declaring success; if the app process died at startup (e.g. a missing dependency or a bad entry point), it dumps `docker logs --tail 50` and exits non-zero instead of silently reporting the container as "running." It's a **liveness** check only — Streamlit and Shiny render script-level exceptions in the browser rather than exiting, so an app that throws still returns 200 and is reported as deployed. Don't tighten this into a correctness check without accounting for that; the honest fix is loading the page.

When changing a pinned version (Shiny Server, an R/Python base image), keep the relevant Dockerfile's `ARG`/`FROM` line and `docs/deployment.md`'s version notes in sync.

## The desktop GUI (`deploy/gui/`)

A Tkinter front end for researchers, added on top of the shell tooling rather than replacing it. Python 3.10 (Ubuntu 22.04's), **stdlib only, no pip dependencies**.

- **It is a thin layer, and that's load-bearing.** `backend.py` is the *only* module allowed to construct a subprocess command, so "no deployment logic in Python" is checkable by reading one file. Ports, mount targets, framework detection and base-image choice all come back from `--dry-run --porcelain`; never hardcode them in Python. On failure, show the script's stderr **verbatim** — its messages are written for researchers, and this keeps them correct as the shell evolves.
- **Builds are detached, not children of the GUI.** `run_detached.sh` runs the deploy in its own session writing to `~/dashboard-deploy-logs/`, and the GUI tails that file. Researchers arrive over a remote desktop, so a dropped session would otherwise kill a 25-minute R build. The GUI reattaches on startup via `~/.local/state/dashboard-deploy/current.pid`. Two consequences worth remembering: a cancelled build that had to be SIGKILLed never writes its exit sentinel (the tailer has a fallback for this), and the wrapper is the GUI's own child, so it must be **reaped** or `os.kill(pid, 0)` keeps succeeding on the zombie.
- **Tk is not thread-safe.** Only the thread that created `root` touches widgets; everything else goes through a `queue.Queue` drained by `root.after()`. Lines per tick and widget scrollback are both capped — an uncapped drain of a geospatial R build freezes the UI just as thoroughly as blocking would.
- **Never claim success, only liveness.** The post-publish message says the app is live and asks the user to open it. See the smoke-test bullet above for why.
- **`persist_mount.sh` is a root-only shell script, never Python.** A bad `/etc/fstab` can leave an instance unbootable at a console a remote-desktop user can't reach, so it needs `nofail` and atomic rollback — both trivial in shell, both easy to get wrong spread across GUI callbacks. Escalate with `pkexec`, then passwordless `sudo`, then tell the user the command. **Never** collect a password in a Tk entry and pipe it to `sudo -S`.
- **`deploy/desktop/setup_image.sh`** prepares the researcher-facing Jetstream2 image. If you add a runtime dependency to the GUI, add it there too — `python3-tk` in particular is not part of `python3` on Ubuntu, and without it the desktop icon does nothing visible at all.

## Design constraints to keep in mind

- One instance = one app; no multi-tenant/multi-app support is in scope.
- No TLS currently (no domain to challenge against) — see "Open items" in `docs/deployment.md` before adding HTTPS support.
- Framework detection is a best-effort heuristic (regex over source files), not a real dependency/AST analysis — the `FRAMEWORK=` override exists specifically for when it guesses wrong.
