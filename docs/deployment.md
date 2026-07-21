# Deploying an R Shiny app to Jetstream2

Two workflows for running an R Shiny app on a Jetstream2 instance. Both assume **one instance per project/researcher** — no multi-tenant package conflicts to manage, and the app is reachable directly on port 80 at the instance's fixed IP.

| | Bare-metal | Docker |
|---|---|---|
| Script | [`deploy/provision_baremetal.sh`](../deploy/provision_baremetal.sh) | [`deploy/docker/build_and_run.sh`](../deploy/docker/build_and_run.sh) |
| Port 80 handled by | Nginx reverse-proxying to Shiny Server (3838) | Docker's `-p 80:3838` port mapping |
| Update the app | Re-run the provisioning script (re-clones the app repo) | Re-run `build_and_run.sh` (rebuilds the image) |
| Rebuild environment from scratch | Full re-provision | `docker build` — base image layers are cached |
| Best for | Researchers who want to `git pull`/edit the app directly on the instance | Reproducible, versioned deploys; easiest to redo identically later |

Pick Docker by default unless there's a specific reason to want the app editable in place on the instance (e.g. active development directly on the server).

---

## Prerequisites (both workflows)

- Jetstream2 instance running **Ubuntu 22.04 (jammy)**, launched via Exosphere.
- A fixed/floating IP assigned to the instance.
- Security group allowing inbound **80/tcp** and **22/tcp**.
- SSH access as a sudo-capable user (Jetstream2's default `exouser`).

---

## Workflow 1: Bare-metal (Shiny Server + Nginx)

1. SSH into the instance.
2. Clone this repo (or copy just the `deploy/` directory) onto the instance.
3. Run the provisioning script, pointing it at the app repo to deploy:

   ```bash
   sudo APP_REPO_URL=https://github.com/YOUR_ORG/YOUR_APP.git \
        APP_BRANCH=main \
        ./deploy/provision_baremetal.sh
   ```

4. Visit `http://<instance-fixed-ip>/` in a browser.

**What it sets up:**
- R from the CRAN apt repo (not Ubuntu's default, which lags releases behind).
- GDAL/GEOS/PROJ/UDUNITS from `ubuntugis-unstable` — these are what actually cause `sf`/`terra`/`raster` install failures on a stock Ubuntu image, so pinning current versions here avoids that class of problem for spatial apps entirely.
- Shiny Server (systemd service, port 3838) serving the single app at `/srv/shiny-server`.
- Nginx reverse-proxying port 80 → 3838. (Shiny/R never binds a privileged port directly — running that process as root would be a real exposure.)
- `ufw` allowing 80/tcp and SSH, as defense in depth alongside the Jetstream2 security group.

**To update the app after a code change:** re-run the script. It does a full `rm -rf` + re-clone of `/srv/shiny-server`, not a `git pull` — simple and fine for a single-researcher instance, but note it's a full wipe each time, not an incremental sync.

**Known limitation:** no TLS. Let's Encrypt's standard challenge needs a resolvable hostname, not just a fixed IP — if a domain gets pointed at the instance later, add certbot + an HTTPS server block to the Nginx config.

**R packages:** installed the same way as the Docker workflow — after cloning the app, [`install_deps.R`](../deploy/docker/install_deps.R) (shared between both workflows) restores its `renv.lock` if present, or scans the app's code for `library()`/`require()` calls and installs whatever's missing.

---

## Workflow 2: Docker

Jetstream2's standard Ubuntu image ships with Docker preinstalled, so no install step is needed. This workflow is **generic** — it works for any R Shiny project, not tied to one particular app.

1. Clone this repo into your home directory on the instance (no `sudo`/root needed for anything in this workflow, assuming `exouser` is in the `docker` group, which is Jetstream2's default):

   ```bash
   git clone https://github.com/stephenconklin/Jetstream2_RShiny_Deploy.git
   cd Jetstream2_RShiny_Deploy
   ```

2. Get the Shiny project into [`deploy/docker/app/`](../deploy/docker/app/README.md) — this folder is gitignored (it's a drop-in slot, not something that ships in git), so a fresh clone always starts with it empty.

   - **To smoke-test the tooling itself** before pointing it at a real project, copy in the bundled example:

     ```bash
     cp -r examples/hello-world/* deploy/docker/app/
     ```

   - **To deploy a real project**, either copy/`git clone` it into `deploy/docker/app/`, or skip this step and pass its path directly to `build_and_run.sh` in the next step (it copies the project into a temporary build context on its own, without needing anything placed under `deploy/docker/app/`).

3. From the repo root:

   ```bash
   ./deploy/docker/build_and_run.sh                         # deploys deploy/docker/app/
   # or
   ./deploy/docker/build_and_run.sh /path/to/other/project  # deploys a project elsewhere
   ```

4. Visit `http://<instance-fixed-ip>/` in a browser.

**How the genericization works:**
- **Base image is auto-detected, with a swappable override.** `build_and_run.sh` scans the project's `.R`/`.Rmd` files for `library()`/`require()`/`::` usage of `sf`, `terra`, `raster`, `stars`, `rgdal`, or `rgeos`, and picks `rocker/geospatial:4.4.1` automatically when it finds one — otherwise it falls back to `rocker/r-ver:4.4.1` (bare R). This is a best-effort heuristic (a regex over source files, not a real dependency graph), so set `BASE_IMAGE` explicitly to skip detection — e.g. `BASE_IMAGE=rocker/shiny-verse ./build_and_run.sh` for a tidyverse-heavy project the scan wouldn't otherwise flag, or to force a specific geospatial image version.
  - **Version-drift warning for geospatial projects without a lockfile.** If the same scan detects geospatial packages but the project has no `renv.lock`, `build_and_run.sh` prints a warning before building: without a lockfile, `install_deps.R` always installs whatever's newest on CRAN, and a new release of `sf`/`terra`/etc. can require a newer GDAL/GEOS/PROJ than the fixed base image ships — breaking a build that worked previously, with no code change on your end. This can't be predicted reliably ahead of time (only actually compiling proves it), so the warning is just a nudge, not a guarantee. See "Pinning R package versions to avoid CRAN version drift" below.
- **A baseline of common compile-time headers is always installed** (`libuv`, `zlib`, `openssl`, `libcurl`, `libxml2`, `fontconfig`/`freetype`/`harfbuzz`/`fribidi`, `png`/`jpeg`). These aren't optional because `shiny` itself won't install without them — its dependency `httpuv` needs `libuv`/`zlib` to compile, and common plotting packages need the font-rendering libs. Anything beyond this baseline (GDAL, Java, ImageMagick, …) is either covered by a `BASE_IMAGE` override or the project's `apt.txt`.
- **R packages are auto-detected, not hardcoded.** [`install_deps.R`](../deploy/docker/install_deps.R) runs at build time: if the project ships an `renv.lock`, it restores those exact versions; otherwise it statically scans the project's `.R`/`.Rmd` files for `library()`/`require()` calls (via `renv::dependencies()`, which doesn't require the project to have ever used `renv`) and installs whatever the base image doesn't already provide. If any required package is still missing afterward, the script fails loudly — `install.packages()`/`renv::restore()` otherwise print an error but exit 0, which would let `docker build` report success on a broken image.
- **Repos always resolve against live CRAN, not a frozen snapshot.** Many R base images (`rocker/geospatial` included) point the default `"CRAN"` repo at a Posit Package Manager snapshot frozen on the date the image was built — and a `renv.lock` itself also embeds the exact repository URLs active when it was written (its `"R"$"Repositories"` section), which `renv::restore()` prefers over the session's `options("repos")`. `install_deps.R` sets `options(renv.config.repos.override = "https://cloud.r-project.org")` before installing anything, which forces `renv::restore()` to ignore both frozen sources and resolve every package against the real, rolling CRAN mirror instead. Without this, a `renv.lock`-pinned package version released after either snapshot date would 404 indefinitely — plain `options(repos = ...)` alone does *not* fix this, since `renv::restore()` doesn't consult it when the lockfile has its own recorded repository URLs.
- **Extra system libraries are opt-in.** An optional `apt.txt` in the project directory (one package per line) covers anything beyond the baseline and `BASE_IMAGE` — e.g. `default-jdk` for `rJava`, `imagemagick` for `magick`. Empty or absent is fine.
- **Entry point needs no configuration.** Shiny Server serves whatever directory it's pointed at using the same convention `shiny::runApp()` does — `app.R`, or a `ui.R`/`server.R` pair — so no project-specific config is needed there either.
- **The project's code is baked into the image** at build time (not bind-mounted), so the resulting image is self-contained and versioned.
- **Data is never baked into the image.** If the project has a `data/` directory, `build_and_run.sh` bind-mounts a host path over it at `/srv/shiny-server/data` at runtime instead of copying its contents into the image — set `DATA_DIR=/path/to/data ./build_and_run.sh` to specify it non-interactively, or leave `DATA_DIR` unset and the script will prompt for the path (with a nudge toward the typical Jetstream2 storage volume location, `/media/volume/<volume-name>/...`). Either way, updating the data only needs a `docker restart`, not a rebuild. If the project has no `data/` directory, nothing is prompted or mounted.
  - **What this requires of the app's code:** the data folder must be named `data` at the project's top level, and R code must reference files under it with a project-root-relative path — e.g. `read_csv("data/wq_baltimore.csv")`, not an absolute path or one that assumes a different working directory. This works because Shiny Server's `app_dir` is `/srv/shiny-server` (see `shiny-server.conf`), which is also where the project is copied to (`COPY app/ /srv/shiny-server/`) and where `DATA_DIR` gets bind-mounted (as `/srv/shiny-server/data`) — so a `data/`-relative path in the app's code resolves to the mount either way. No env var or Shiny-side awareness of the mount is needed. A project that reads data via an absolute path or a non-standard folder name won't pick up the bind-mounted data.
- Container runs with `--restart unless-stopped` and `-p 80:3838` — Docker's port mapping handles the privileged bind, so no Nginx is needed in this workflow.

**To update the app after a code change:** re-run `build_and_run.sh`. It rebuilds the image (Docker layer caching keeps this fast unless the system/package layers changed) and replaces the running container.

**To update data when using `DATA_DIR`:** just update the files at that host path and `docker restart <container-name>` — no rebuild needed, since the data is bind-mounted rather than baked in.

**Known limitation:** same as bare-metal — no TLS, since there's no domain to challenge against yet. Also, dependency auto-detection is static analysis — it won't catch packages loaded dynamically (e.g. via a variable passed to `library()`), so an unusual project may occasionally need an explicit `renv.lock` instead of relying on the scan.

---

## Choosing package versions

Both workflows currently pin:
- Shiny Server `1.5.22.1017` — check [posit.co/download/shiny-server](https://posit.co/download/shiny-server) for the current release before provisioning new instances.
- `rocker/r-ver:4.4.1` (Docker default) — check [rocker-project.org](https://rocker-project.org) for the R version to standardize on, or the R version your BASE_IMAGE override ships.

Update the version strings at the top of `provision_baremetal.sh` and in the `Dockerfile`'s `FROM`/`ARG` lines together, so both workflows stay on comparable R/package versions.

---

## Pinning R package versions to avoid CRAN version drift

Without a project-supplied `renv.lock`, `install_deps.R` always installs whatever's newest on CRAN for each required package (see "R packages are auto-detected" above). For geospatial packages (`sf`, `terra`, `raster`, …) that compile C/C++ code against the base image's fixed GDAL/GEOS/PROJ, this means a build that worked last month can fail today simply because CRAN shipped a newer package release that needs a newer system library version than the pinned `BASE_IMAGE` provides — with no change to the project's own code. `build_and_run.sh` warns about this when it detects geospatial packages with no `renv.lock`, but the warning alone doesn't fix anything.

To pin versions and get reproducible builds:

1. Start an interactive R session in the *same* base image the deploy will actually use, so whatever compiles here is guaranteed to compile at deploy time too — a lockfile only records version numbers, not whether they'll build against this image's system libraries:
   ```bash
   docker run --rm -it -v /path/to/project:/app rocker/geospatial:4.4.1 bash
   cd /app && R
   ```
2. In R, scaffold `renv` without snapshotting your global library, then install the project's dependencies (working backward through CRAN's archive for any package that fails to compile — see `https://cran.r-project.org/src/contrib/Archive/<package>/` for the version history):
   ```r
   install.packages("renv")
   renv::init(bare = TRUE)
   # for a package that needs an older, compatible version:
   install.packages(
     "https://cran.r-project.org/src/contrib/Archive/terra/terra_1.8-15.tar.gz",
     repos = NULL, type = "source"
   )
   # then the rest of the project's normal library()'d packages as usual
   ```
3. Once everything loads without error, capture it:
   ```r
   renv::snapshot()
   ```
   This writes `renv.lock` into the project directory (visible on the host too, via the bind mount).
4. Make sure `renv.lock` ships with the deployed project — commit it to the app's own repo if you maintain it, or otherwise just make sure it's present in whatever directory you pass to `build_and_run.sh` (it doesn't need to be tracked by the app's upstream repo; `install_deps.R` only checks whether the file exists on disk at build time).

From then on, `install_deps.R` detects the lockfile and calls `renv::restore()` instead of installing CRAN-latest, so rebuilds are reproducible regardless of what CRAN does in the meantime.

---

## Open items / possible future work

- TLS once a domain is available (Nginx + certbot for bare-metal; Nginx sidecar or Caddy for Docker).
- Snapshotting the bare-metal instance into a reusable Jetstream2 image once the provisioning script has been validated on real hardware, so future researchers can launch from the image instead of re-running the script.
- A geospatial-specific bare-metal Dockerfile equivalent, if the auto-detected R package installs on bare-metal (currently left to the app itself) turn out to need the same system-library pinning treatment as Docker's `apt.txt` mechanism.
