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
- **Base image is swappable.** `Dockerfile` takes `BASE_IMAGE` as a build arg (default `rocker/r-ver:4.4.1`, bare R). A project needing heavier system libraries pre-built can override it, e.g. `BASE_IMAGE=rocker/geospatial:4.4.1 ./build_and_run.sh` for `sf`/`terra`/`raster`-based apps, or `rocker/shiny-verse` for tidyverse-heavy ones.
- **A baseline of common compile-time headers is always installed** (`libuv`, `zlib`, `openssl`, `libcurl`, `libxml2`, `fontconfig`/`freetype`/`harfbuzz`/`fribidi`, `png`/`jpeg`). These aren't optional because `shiny` itself won't install without them — its dependency `httpuv` needs `libuv`/`zlib` to compile, and common plotting packages need the font-rendering libs. Anything beyond this baseline (GDAL, Java, ImageMagick, …) is either covered by a `BASE_IMAGE` override or the project's `apt.txt`.
- **R packages are auto-detected, not hardcoded.** [`install_deps.R`](../deploy/docker/install_deps.R) runs at build time: if the project ships an `renv.lock`, it restores those exact versions; otherwise it statically scans the project's `.R`/`.Rmd` files for `library()`/`require()` calls (via `renv::dependencies()`, which doesn't require the project to have ever used `renv`) and installs whatever the base image doesn't already provide. If any required package is still missing afterward, the script fails loudly — `install.packages()`/`renv::restore()` otherwise print an error but exit 0, which would let `docker build` report success on a broken image.
- **Extra system libraries are opt-in.** An optional `apt.txt` in the project directory (one package per line) covers anything beyond the baseline and `BASE_IMAGE` — e.g. `default-jdk` for `rJava`, `imagemagick` for `magick`. Empty or absent is fine.
- **Entry point needs no configuration.** Shiny Server serves whatever directory it's pointed at using the same convention `shiny::runApp()` does — `app.R`, or a `ui.R`/`server.R` pair — so no project-specific config is needed there either.
- **The project is baked into the image** at build time (not bind-mounted), so the resulting image is self-contained and versioned.
- Container runs with `--restart unless-stopped` and `-p 80:3838` — Docker's port mapping handles the privileged bind, so no Nginx is needed in this workflow.

**To update the app after a code change:** re-run `build_and_run.sh`. It rebuilds the image (Docker layer caching keeps this fast unless the system/package layers changed) and replaces the running container.

**Known limitation:** same as bare-metal — no TLS, since there's no domain to challenge against yet. Also, dependency auto-detection is static analysis — it won't catch packages loaded dynamically (e.g. via a variable passed to `library()`), so an unusual project may occasionally need an explicit `renv.lock` instead of relying on the scan.

---

## Choosing package versions

Both workflows currently pin:
- Shiny Server `1.5.22.1017` — check [posit.co/download/shiny-server](https://posit.co/download/shiny-server) for the current release before provisioning new instances.
- `rocker/r-ver:4.4.1` (Docker default) — check [rocker-project.org](https://rocker-project.org) for the R version to standardize on, or the R version your BASE_IMAGE override ships.

Update the version strings at the top of `provision_baremetal.sh` and in the `Dockerfile`'s `FROM`/`ARG` lines together, so both workflows stay on comparable R/package versions.

---

## Open items / possible future work

- TLS once a domain is available (Nginx + certbot for bare-metal; Nginx sidecar or Caddy for Docker).
- Snapshotting the bare-metal instance into a reusable Jetstream2 image once the provisioning script has been validated on real hardware, so future researchers can launch from the image instead of re-running the script.
- A geospatial-specific bare-metal Dockerfile equivalent, if the auto-detected R package installs on bare-metal (currently left to the app itself) turn out to need the same system-library pinning treatment as Docker's `apt.txt` mechanism.
