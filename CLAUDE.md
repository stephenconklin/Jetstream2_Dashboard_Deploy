# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Deployment tooling for running an R Shiny app on a Jetstream2 instance — not a Shiny app itself. There is no application code here to build/test/lint in the usual sense; the "product" is a set of shell scripts and a Dockerfile that take an arbitrary Shiny project as input and get it reachable in a browser on port 80. `examples/hello-world/app.R` is a minimal self-test fixture, not a real feature.

## Commands

Smoke-test the Docker workflow end-to-end with the bundled example app:

```bash
cp -r examples/hello-world/* deploy/docker/app/
./deploy/docker/build_and_run.sh
```

Deploy an arbitrary project (either drop it into `deploy/docker/app/` first, or pass its path directly — `build_and_run.sh` copies it into a temp build context either way):

```bash
./deploy/docker/build_and_run.sh /path/to/project [image-name]
```

Override the base image for projects needing heavier system libs pre-built (e.g. geospatial):

```bash
BASE_IMAGE=rocker/geospatial:4.4.1 ./deploy/docker/build_and_run.sh
```

Bare-metal provisioning (run as root/sudo on the target Ubuntu 22.04 instance):

```bash
sudo APP_REPO_URL=https://github.com/YOUR_ORG/YOUR_APP.git APP_BRANCH=main ./deploy/provision_baremetal.sh
```

There's no CI, test suite, or linter in this repo — verifying a change means actually running one of the two workflows above (or reasoning carefully through the shell script / Dockerfile logic, since a real run requires Docker or a live Jetstream2 instance).

## Architecture

Two independent, parallel deployment workflows for the same goal (one Shiny app reachable on port 80 of one instance), documented in full in `docs/deployment.md`:

- **Docker** (`deploy/docker/`) — the recommended default. `build_and_run.sh` copies a target project into a temp build context alongside `Dockerfile`, `install_deps.R`, and `shiny-server.conf`, builds a self-contained image, and runs it with `-p 80:3838`. No Nginx needed — Docker's port mapping handles the privileged bind.
- **Bare-metal** (`deploy/provision_baremetal.sh`) — installs R (from CRAN's apt repo, not Ubuntu's stale default), GDAL/GEOS/PROJ/UDUNITS (from `ubuntugis-unstable`, needed for `sf`/`terra`/`raster`), and Shiny Server directly on the instance, then Nginx reverse-proxies 80 → 3838 (Shiny/R never binds a privileged port directly).

Both workflows share the same dependency-installation logic (`deploy/docker/install_deps.R`, invoked by both `Dockerfile` and `provision_baremetal.sh`) and the same design principle: **nothing about a specific target project is hardcoded**. Key mechanisms that make this work, and that any change should preserve:

- **R packages are auto-detected, not hardcoded.** `install_deps.R` restores `renv.lock` if the project ships one; otherwise it statically scans `.R`/`.Rmd` files via `renv::dependencies()` (works even if the project never used `renv`) and installs whatever's missing. It fails loudly (non-zero exit) if any required package is still missing afterward — `install.packages()`/`renv::restore()` normally exit 0 even on partial failure, which would otherwise let `docker build` report success on a broken image. Preserve this fail-loud check in any edit to that script.
- **System libraries are layered, not project-specific.** The Dockerfile always installs a baseline of compile-time headers (`libuv`, `zlib`, font-rendering libs, etc.) that `shiny`/`httpuv` need regardless of project. Beyond that: a `BASE_IMAGE` build-arg override (default `rocker/r-ver:4.4.1`) for projects needing a heavier pre-built environment (`rocker/geospatial`, `rocker/shiny-verse`), and an optional project-supplied `apt.txt` (one package per line) for anything else. Don't add project-specific system packages to the Dockerfile itself — they belong in one of these two extension points.
- **`deploy/docker/app/` is a gitignored drop-in slot**, not a place to commit code — only its `README.md` is tracked (see `.gitignore`). Don't add real app code there expecting it to persist/ship.
- **Entry point convention is Shiny's own** (`app.R`, or `ui.R`/`server.R`) — no per-project Shiny Server config is needed since both workflows serve a single app at `/`.

When changing pinned versions (Shiny Server, R/`rocker/r-ver`), update `provision_baremetal.sh` and the `Dockerfile`'s `ARG`/`FROM` lines together so both workflows stay comparable — see "Choosing package versions" in `docs/deployment.md`.

## Design constraints to keep in mind

- One instance = one app for both workflows; no multi-tenant/multi-app support is in scope.
- No TLS currently in either workflow (no domain to challenge against) — see "Open items" in `docs/deployment.md` before adding HTTPS support.
- Bare-metal app updates are a full `rm -rf` + re-clone, not a `git pull` — intentional, not a bug to "fix" into incremental sync.
