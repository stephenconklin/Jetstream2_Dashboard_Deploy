# Deploying a dashboard/app to Jetstream2

A single Docker-based workflow for running an app on a Jetstream2 instance, generic across **R Shiny**, **Plotly Dash**, **Python Shiny**, and **Streamlit**. Assumes **one instance per project/researcher** — no multi-tenant package conflicts to manage.

The app is reachable on port 80 at the instance's fixed IP. On an instance provisioned with [`bootstrap.sh`](#provisioning-a-fresh-instance), nginx serves that port and the container binds loopback only; without it, the container publishes port 80 directly, exactly as this tool has always done.

---

## Prerequisites

- Jetstream2 instance running **Ubuntu 22.04 (jammy) or 24.04 (noble)**, launched via Exosphere. Both are tested; the GUI targets Python 3.10 syntax so it runs on either (24.04 ships 3.12).
- A fixed/floating IP assigned to the instance.
- Security group allowing inbound **80/tcp** and **22/tcp** — plus **443/tcp** if you plan to use TLS.
- SSH access as a sudo-capable user (Jetstream2's default `exouser`).
- Docker preinstalled (Jetstream2's standard Ubuntu image ships with it); `bootstrap.sh` installs it if not. Deploying an app needs no `sudo`, assuming `exouser` is in the `docker` group, which is Jetstream2's default — only host provisioning does.

---

## Two ways to use this

**The desktop application** — for researchers. On an instance built from the prepared image, open **Deploy My Dashboard** from the desktop. It walks through choosing your project, getting your data onto the server, publishing, and managing the result, without a terminal. See [The desktop application](#the-desktop-application) below.

**The command line** — everything the application does, it does by running `build_and_run.sh`. If you're comfortable in a shell, use it directly; the two are interchangeable and nothing is hidden from you.

Either way, your project and data have to reach the instance first: see [getting your files onto the instance](getting-your-files-onto-the-instance.md).

---

## Provisioning a fresh instance

`bootstrap.sh` sets up the **host**; `build_and_run.sh` deploys the **app**. Neither replaces the other — you run bootstrap once per instance, and `build_and_run.sh` every time your code changes.

```bash
git clone https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy.git
cd Jetstream2_Dashboard_Deploy

cp deploy/deploy.env.example deploy/deploy.env   # optional — defaults work as-is
${EDITOR:-nano} deploy/deploy.env

sudo ./deploy/bootstrap.sh                       # provision the host
sudo ./deploy/bootstrap.sh /path/to/my/project   # ...and deploy in one go
```

It installs Docker (if missing), a swapfile, nginx, TLS if you have a DNS name, and the autoheal sidecar — then writes `/etc/dashboard-deploy/proxy.env`, which is what tells `build_and_run.sh` to publish behind the proxy.

It also **warns when `/` has under 15GB free**, with the prune commands to fix it. That's a rule of thumb rather than a hard requirement — an R geospatial image is roughly 6–8GB on top of a ~4.5GB `rocker/geospatial` base, plus a build cache that grows with every rebuild, while the Python frameworks need far less — so it's a warning, never a refusal to provision. It's reported here because running out of disk *mid-build* is one of the least legible failures this tool can produce: it surfaces as a compile or extraction error hundreds of lines into a build log, naming a file rather than the disk. See [Reclaiming disk space](#reclaiming-disk-space).

The script is **idempotent**: re-running it is the normal way to apply a change from `deploy/deploy.env`. Every step detects existing state and skips.

| Command | Effect |
|---|---|
| `sudo ./deploy/bootstrap.sh` | Full provision. Safe to re-run. |
| `sudo ./deploy/bootstrap.sh <project>` | Provision, then build and deploy that project |
| `sudo ./deploy/bootstrap.sh --check` | Read-only status snapshot; changes nothing |
| `sudo ./deploy/bootstrap.sh --remove-proxy` | Roll back to publishing the container directly on port 80 |

**It does not provision your data.** Research datasets belong on an attached Jetstream2 volume, not in a git clone or a Docker image. Attach and mount the volume first — see [getting your files onto the instance](getting-your-files-onto-the-instance.md) and [Reboot persistence](#reboot-persistence).

### Running it on an instance that already serves a dashboard

nginx needs port 80, and an existing deployment is holding it. Everything fallible happens **before** anything is taken down — the package install, rendering the config, and `nginx -t` all run while the old dashboard is still serving, so a bad config or a failed download stops the script with the site still up. Only then does the `Cutover` step remove the container and start nginx.

Pass the project directory so it re-publishes in the same run:

```bash
sudo ./deploy/bootstrap.sh /path/to/my/project
```

Downtime is then the rebuild, typically a couple of minutes since Docker's layer cache is warm. Without a project directory, bootstrap warns, asks for confirmation, and leaves the site down until you run `build_and_run.sh` yourself. `--yes` skips the prompt for unattended runs.

### Rolling back

```bash
sudo ./deploy/bootstrap.sh --remove-proxy
./deploy/build_and_run.sh /path/to/my/project   # re-publish onto port 80
```

Removing the proxy deletes the state file and stops nginx, but nothing rebinds a *running* container in place — the re-publish is what moves it back onto port 80.

---

## The nginx front end

Once bootstrap has run, the app container binds **127.0.0.1 only** and nginx is the sole public listener:

```
internet ──→ nginx (host, :80 / :443, TLS, rate limiting, gzip, maintenance page)
           → 127.0.0.1:8080 → dashboard container (Shiny Server / gunicorn / streamlit / shiny run)
                               ├─ health check → autoheal sidecar
                               └─ data bind-mounted read-write from DATA_DIR
```

Verify the app is not publicly exposed after any change:

```bash
sudo ss -tlnp | grep -E ':80|:8080'
# expect nginx on 0.0.0.0:80 and docker-proxy on 127.0.0.1:8080 ONLY.
# Anything on 0.0.0.0:8080 means the app server is facing the internet directly.
```

**Why bother**, when the container could just publish port 80 itself:

- Every one of these frameworks serves from a small fixed pool of workers or threads, so a single slow client can hold one for an entire conversation. nginx buffers each complete request before contacting the app, so a slow client costs an nginx connection instead of an app worker.
- It is where TLS, rate limiting, gzip, upload limits and a real maintenance page can live without any of it becoming the app's problem.

**Two settings are load-bearing and should not be "tidied up"** (both are explained at length in `deploy/nginx/dashboard.conf.template`):

- WebSockets. R Shiny, Python Shiny and Streamlit are useless without them, so `Connection` is set from a `map` rather than hardcoded, and `proxy_read_timeout` is long — a Shiny socket sits idle whenever nobody is clicking, and a short timeout tears it down mid-session as a "Disconnected from server" with nothing in the app's own log to explain it.
- `proxy_buffering off`. These frameworks stream responses; buffering them makes the UI appear to freeze until the transfer finishes. Request buffering stays *on*, which is the half that protects the app from slow clients.

Tune the rest — upload size, rate limit, connection cap, timeout — in `deploy/deploy.env` and re-run bootstrap. Edit the template, never `/etc/nginx/sites-available/dashboard`; the next bootstrap run overwrites the installed copy.

### The `/_deploy/` prefix is reserved

`/_deploy/health` (nginx's own liveness, answered without touching the app) and `/_deploy/unavailable.html` (the maintenance page) are served by nginx and never proxied. An app that wants to serve its own content at those paths cannot.

### TLS

Let's Encrypt **cannot issue a certificate for a bare IP address**, so TLS needs a DNS name pointed at the instance's floating IP:

```ini
SERVER_NAME="dashboard.example.org"
CERTBOT_EMAIL="you@example.org"
```

With `SERVER_NAME` empty — the default, and the usual Jetstream2 case — bootstrap warns and serves plain HTTP; everything else works. Add the name later and re-run bootstrap; nothing else needs changing.

Because bootstrap re-renders the site config from the template on every run, it also **re-installs an existing certificate** into the fresh config rather than skipping it. Without that, a second bootstrap run would silently drop the instance back to plain HTTP while reporting success.

---

## Deploying your app

1. Clone this repo into your home directory on the instance:

   ```bash
   git clone https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy.git
   cd Jetstream2_Dashboard_Deploy
   ```

2. Get your project into [`deploy/app/`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/app/README.md) — this folder is gitignored (it's a drop-in slot, not something that ships in git), so a fresh clone always starts with it empty.

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

   If you're triaging many candidate projects and just want to know what the script would do to each — detected framework, entry point, base image, whether the dependency file/`data/`/`apt.txt` are present — without actually building anything, add `--dry-run`. It is strictly read-only: it never starts a container, never writes into the project directory, and reports a missing `requirements.txt` as part of the summary rather than failing on it:

   ```bash
   ./deploy/build_and_run.sh --dry-run /path/to/project
   ```

   Adding `--porcelain` (only valid with `--dry-run`) prints the same findings as stable `key=value` lines instead of prose — this is what the GUI consumes, and it's useful for scripting a survey of many projects:

   ```console
   $ ./deploy/build_and_run.sh --dry-run --porcelain /path/to/project
   project_dir=/path/to/project
   framework=r-shiny
   entry_file=app.R
   entry_point_desc=app.R
   base_image=rocker/geospatial:4.4.1
   deps_state=will-generate-renv
   uses_geospatial=1
   has_data_dir=1
   has_apt_txt=0
   container_port=3838
   data_mount_target=/srv/shiny-server/data
   proxy_enabled=1
   app_bind_addr=127.0.0.1
   app_host_port=8080
   server_name=
   ```

   `deps_state` is one of `present`, `will-generate-renv`, `will-generate-from-uv`, or `missing`. Keys may be added in future versions but existing ones won't be renamed, and warnings stay on stderr so capturing stdout gives a clean stream.

4. Visit `http://<instance-fixed-ip>/` in a browser.

**The optional second argument** is the image/container name (default `dashboard-app`). Docker requires it to be lowercase letters, digits, and `.` `_` `-` separators, starting and ending with a letter or digit — `build_and_run.sh` validates this before doing any work and suggests a corrected name, rather than letting `docker build` reject the tag several steps later.

### Environment variables

All optional; each is described in more detail in the relevant section below.

| Variable | Default | Purpose |
|---|---|---|
| `FRAMEWORK` | auto-detected | Force `r-shiny`\|`dash`\|`python-shiny`\|`streamlit`, bypassing detection. Validated against that set. |
| `BASE_IMAGE` | per framework | Swap the base image (R: `rocker/r-ver:4.4.1`, auto-upgraded to `rocker/geospatial:4.4.1`; Python: `python:3.11-slim`). |
| `DATA_DIR` | prompted if the project has `data/` | Host path bind-mounted into the container and exposed as a `DATA_DIR` env var inside it. |
| `BUILD_PLATFORM` | auto (`linux/amd64` for R Shiny on non-amd64 hosts) | `docker build --platform` target. |
| `CONTAINER_PORT` | per framework (3838/8050/8000/8501) | The port the app listens on *inside* the container, if a project's server is configured off-default. The host side is decided separately — see below. |
| `CONTAINER_NAME` | `dashboard-app` | Which container `manage.sh` operates on. `build_and_run.sh` takes the same thing as its optional second argument instead. |
| `DASHBOARD_PROXY_ENV` | `/etc/dashboard-deploy/proxy.env` | Path to the proxy state file. Exists so the whole nginx path can be exercised without root; you shouldn't need it in production. |

**The host side of the port mapping is not an environment variable** — it comes from the proxy state file `bootstrap.sh` writes. With nginx in front the container publishes `127.0.0.1:8080` (`APP_HOST_PORT` in `deploy/deploy.env`); without it, `0.0.0.0:80`. See [The nginx front end](#the-nginx-front-end).

**How the genericization works:**

- **Framework is auto-detected from the project's code, with a `FRAMEWORK=` override.** `build_and_run.sh` greps a project's `.R`/`.Rmd`/`.py` files for framework-specific signals — see [`deploy/lib/detect_framework.sh`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/lib/detect_framework.sh) for the exact patterns. This is content-based, not filename-based: `app.py` alone is ambiguous across Dash/Python Shiny/Streamlit (and plain Flask), so detection always inspects imports (`import dash`, `from shiny import App`, `import streamlit`), with Streamlit's `streamlit_app.py` filename only as a secondary signal. If detection finds conflicting signals in different files, or nothing at all, it fails loudly with an actionable message rather than guessing — set `FRAMEWORK=r-shiny|dash|python-shiny|streamlit` to force a choice and bypass detection entirely.
- **One Dockerfile per framework** (`deploy/docker/Dockerfile.r-shiny`, `.dash`, `.python-shiny`, `.streamlit`), selected via `docker build -f` once the framework is known. Each keeps its own build steps simple rather than one Dockerfile branching internally across 4 different ecosystems.
- **Base image is auto-detected for R Shiny, with a swappable override; fixed for the 3 Python frameworks.** For R Shiny, `build_and_run.sh` scans the project's `.R`/`.Rmd` files for `library()`/`require()`/`::` usage of `sf`, `terra`, `raster`, `stars`, `rgdal`, or `rgeos`, and — if the project ships a `renv.lock` — also checks its resolved package list directly (catching cases where a geospatial package rides in transitively, e.g. `leaflet` `Imports` `sf`, invisible to a source-file scan of code that only calls `library(leaflet)`). It picks `rocker/geospatial:4.4.1` automatically when either check finds one — otherwise it falls back to `rocker/r-ver:4.4.1` (bare R). This is still a best-effort heuristic, not a real dependency graph, so set `BASE_IMAGE` explicitly to skip detection — e.g. `BASE_IMAGE=rocker/shiny-verse ./build_and_run.sh` for a tidyverse-heavy project the scan wouldn't otherwise flag. Dash/Python Shiny/Streamlit default to `python:3.11-slim`, also overridable via `BASE_IMAGE`.
  - **Version-drift warning for R geospatial projects without a lockfile.** If the same scan detects geospatial R packages but the project has no `renv.lock`, `build_and_run.sh` prints a warning before building: without a lockfile, `install_deps.R` always installs whatever's newest on CRAN, and a new release of `sf`/`terra`/etc. can require a newer GDAL/GEOS/PROJ than the fixed base image ships — breaking a build that worked previously, with no code change on your end. This can't be predicted reliably ahead of time (only actually compiling proves it), so the warning is just a nudge, not a guarantee. See "Pinning R package versions to avoid CRAN version drift" below.
- **A baseline of common compile-time headers is always installed** in `Dockerfile.r-shiny` (`libuv`, `zlib`, `openssl`, `libcurl`, `libxml2`, `fontconfig`/`freetype`/`harfbuzz`/`fribidi`, `png`/`jpeg`). These aren't optional because `shiny` itself won't install without them — its dependency `httpuv` needs `libuv`/`zlib` to compile, and common plotting packages need the font-rendering libs. Anything beyond this baseline (GDAL, Java, ImageMagick, …) is either covered by a `BASE_IMAGE` override or the project's `apt.txt`. The 3 Python Dockerfiles rely on `python:3.11-slim` + pip wheels for the common case, with `apt.txt` as the same escape hatch.
- **R packages are auto-detected, not hardcoded; Python's dependency file is required, not optional.** [`install_deps.R`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/docker/install_deps.R) (R Shiny only) runs at build time: if the project ships an `renv.lock`, it restores those exact versions; otherwise it statically scans the project's `.R`/`.Rmd` files for `library()`/`require()` calls (via `renv::dependencies()`, which doesn't require the project to have ever used `renv`) and installs whatever the base image doesn't already provide. If any required package is still missing afterward, the script fails loudly — `install.packages()`/`renv::restore()` otherwise print an error but exit 0, which would let `docker build` report success on a broken image. **Python has no equivalent fallback**: there's no reliable way to infer a PyPI package name from an import statement (e.g. `import cv2` comes from the package `opencv-python`, not `cv2`), so `requirements.txt` is required for Dash/Python Shiny/Streamlit — `build_and_run.sh` fails with an actionable message (and the reasoning above) if it's missing, rather than attempting any auto-scan. One exception: a project managed with `uv` (`pyproject.toml` + `uv.lock`, no `requirements.txt`) gets one generated automatically — see "A missing `requirements.txt` is generated automatically for uv projects" below.
- **A missing `requirements.txt` is generated automatically for uv projects, before the real `docker build`.** If a Dash/Python Shiny/Streamlit project has no `requirements.txt` but does have a `uv.lock`, `generate_requirements_from_uv()` (in [`common.sh`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/lib/common.sh)) runs `uv export --no-hashes --frozen -o requirements.txt` against the project directory via `docker run`, using astral's official `ghcr.io/astral-sh/uv` image rather than `BASE_IMAGE`. Unlike the R `renv.lock` case, this doesn't need `BASE_IMAGE`'s system libraries or a throwaway install — `uv.lock` is already a fully-resolved, pinned dependency set, so `uv export` just reformats it (`--frozen` skips checking the lock is current against `pyproject.toml`, so no network resolution happens). If this fails (e.g. `pyproject.toml` is missing, which `uv export` needs alongside the lockfile), the actionable message tells you to run the same `uv export` command yourself, or write `requirements.txt` by hand.
- **A missing `renv.lock` (R Shiny only) is generated automatically, before the real `docker build`.** If the project has no `renv.lock`, `build_and_run.sh` builds `Dockerfile.r-shiny`'s `deps-base` stage (the apt/compile-header environment the real build will use) and runs [`generate_lock.R`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/docker/generate_lock.R) inside it via `docker run`: it scans dependencies the same way `install_deps.R` does, installs them into a throwaway library, and `renv::snapshot()`s the result into the project directory — without leaving any `renv/` scaffold or `.Rprofile` behind, just the lockfile. The real build then finds that lockfile and restores from it via `install_deps.R`, so every build is reproducible by default, not only ones where you ran the manual pinning workflow yourself. This roughly doubles R Shiny build time when no lockfile is present (dependencies get installed once to generate the lock, once more via `renv::restore()` in the real build) — the tradeoff for reproducibility becoming the default instead of opt-in. It does **not** resolve a genuine compile failure (e.g. a CRAN-latest package needing a newer system library than the image ships) — that still surfaces as a failure of this preflight step, just earlier and with cleaner output than a `docker build` failure buried deep in log output. See "Pinning R package versions to avoid CRAN version drift" below for what to do when that happens.
- **Repos always resolve against live CRAN, not a frozen snapshot** (R Shiny only). Many R base images (`rocker/geospatial` included) point the default `"CRAN"` repo at a Posit Package Manager snapshot frozen on the date the image was built — and a `renv.lock` itself also embeds the exact repository URLs active when it was written (its `"R"$"Repositories"` section), which `renv::restore()` prefers over the session's `options("repos")`. `install_deps.R` sets `options(renv.config.repos.override = "https://cloud.r-project.org")` before installing anything, which forces `renv::restore()` to ignore both frozen sources and resolve every package against the real, rolling CRAN mirror instead. Without this, a `renv.lock`-pinned package version released after either snapshot date would 404 indefinitely — plain `options(repos = ...)` alone does *not* fix this, since `renv::restore()` doesn't consult it when the lockfile has its own recorded repository URLs.
- **Extra system libraries are opt-in, for every framework.** An optional `apt.txt` in the project directory (one package per line) covers anything beyond the baseline and `BASE_IMAGE` — e.g. `default-jdk` for `rJava`, `libgdal-dev` for a Python `geopandas` dependency. Empty or absent is fine. All 4 Dockerfiles read it through `apt_retry.sh --from-file`, which tolerates the two things that most often break a hand-written `apt.txt`: **CRLF line endings** (a file edited on Windows otherwise fails with `Unable to locate package curl` for a correctly-spelled `curl`, naming the package you typed and giving no hint that the line ending is at fault) and **`#` comment lines** (otherwise passed to apt as literal package names `#`, `a`, `comment`, …). Blank lines are ignored too.
- **Entry point convention is each framework's own, detected beyond the basic case.** R Shiny: `app.R`, or a `ui.R`/`server.R` pair, or an R Markdown Shiny document (`runtime: shiny` in its YAML front matter, e.g. a flexdashboard) — a golem-packaged app that only ships `inst/app.R` gets a specific error telling you to add a root-level shim, rather than a generic "nothing found." Dash/Python Shiny: `app.py`. Streamlit: `streamlit_app.py` (or `app.py`). No per-project server config is needed since the tool always serves a single app at `/`.
- **The project's code is baked into the image** at build time (not bind-mounted), so the resulting image is self-contained and versioned.
- **The build context is filtered, not a straight copy of the project.** `build_and_run.sh` assembles a temp build context with `tar` and skips `data/`, `.git`, `.venv`/`venv`, `.env`, `__pycache__`, `node_modules`, `.Rproj.user` and `.DS_Store`, writing a matching `.dockerignore` alongside as a second line of defence. Two distinct reasons: **size** — these projects routinely carry multi-GB datasets, and copying one into `/tmp` just to delete it (`data/` is bind-mounted at runtime, never baked in) both fills the disk and stalls the upload of the context to the Docker daemon; and **hygiene** — `COPY app/ .` would otherwise bake your `.git` history and any stray `.env` into the image layers, where they'd travel with the image. If your project needs one of these paths at runtime, it belongs under `DATA_DIR`, not in the image.
- **A `data/` folder in the project is a convenience, not the trigger.** `DATA_DIR` is mounted whenever it is set, whether or not the project contains a `data/` directory. This matters because the recommended arrangement — keeping a large dataset on a storage volume instead of inside the project — *removes* the `data/` folder that the dry-run summary reports on. A project set up correctly can therefore report `data/ directory: not in the project` and still need, and get, a mount. What `has_data_dir` really means is "this project will definitely break without a data mount", not "this project is the only kind that can have one".
- **Data is bind-mounted AND passed as a container env var, never baked into the image.** If the project has a `data/` directory, `build_and_run.sh` bind-mounts a host path over a framework-specific target (`/srv/shiny-server/data` for R Shiny, `/app/data` for the 3 Python frameworks) at runtime instead of copying its contents into the image, and also sets a `DATA_DIR` env var inside the container pointing at that same path — set `DATA_DIR=/path/to/data ./build_and_run.sh` to specify the host path non-interactively, or leave `DATA_DIR` unset and the script will prompt for it (with a nudge toward the typical Jetstream2 storage volume location, `/media/volume/<volume-name>/...`). Either way, updating the data only needs a `docker restart`, not a rebuild. If the project has no `data/` directory, nothing is prompted or mounted.
  - **What this requires of the app's code:** an R Shiny app must reference files with a project-root-relative path — e.g. `read_csv("data/wq_baltimore.csv")` — since that's what resolves to Shiny Server's `app_dir` (`/srv/shiny-server`) and where the mount lands. A Python app (Dash/Python Shiny/Streamlit) can instead just read `os.environ["DATA_DIR"]` directly — more portable, since it doesn't hardcode a path convention. An app that already has its own env var name for this (e.g. a `VI_DATACUBE_ROOT`-style variable) can bridge with a one-line shim at the top of its entry file: `os.environ.setdefault("VI_DATACUBE_ROOT", os.environ["DATA_DIR"])`.
- **Each framework has its own internal container port**, looked up in one place (`container_port_for_framework()` in [`deploy/lib/common.sh`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/lib/common.sh)): 3838 for Shiny Server, 8050 for Dash (gunicorn), 8000 for Python Shiny (`shiny run`), 8501 for Streamlit. **The host side is separate**, and comes from `resolve_app_bind()` in [`proxy.sh`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/lib/proxy.sh): `-p 127.0.0.1:8080:<port>` behind nginx, or `-p 0.0.0.0:80:<port>` without it. Keeping the two apart is what lets nginx sit in between without any Dockerfile knowing it exists — and, without nginx, Docker's own port mapping still handles the privileged bind, so port 80 works with no root and no proxy.
- **Network flakiness is retried, not treated as fatal.** Deploying many different projects means hitting more transient apt/pip/CRAN mirror hiccups over time, so several layers retry before giving up: `apt_retry.sh` (shared by all 4 Dockerfiles) wraps every `apt-get install` with up to 3 attempts (10s backoff), `install_deps.R` retries `renv::restore()`/`install.packages()` up to 3 times (checking what's actually still missing afterward, since neither throws an R error on partial failure), and `build_and_run.sh` itself retries a failed `docker build` up to 3 times (10s backoff) in case the flakiness happens outside those inner retry windows (e.g. pulling `BASE_IMAGE`).
- **Some Jetstream2 instances block outbound port 80**, which breaks apt entirely (not just flakily) since Ubuntu/Debian's default sources are `http://` mirrors — no amount of retrying fixes a blocked port. `apt_retry.sh` rewrites `/etc/apt/sources.list` and any `/etc/apt/sources.list.d/*.list`/`*.sources` files from `http://` to `https://` before each install attempt, so builds work regardless of the instance's egress rules for port 80. If you hit `Connection failed` / connection timeouts during an apt step, you can confirm this is the cause by running `curl -v http://archive.ubuntu.com/ubuntu/ --max-time 10` vs the same with `https://` on the instance directly — if only the `https://` one succeeds, this is why.
- **A post-run smoke test catches startup crashes a successful build can't see.** A clean `docker build` + `docker run -d` only proves the image is valid and the container started — not that the app process inside stayed up. After starting the container, `build_and_run.sh` polls the app **directly** — on whichever host port it actually published, bypassing nginx — for up to `HEALTH_START_PERIOD` (300s, the same window the Docker health check gets; see [Container health checks and autoheal](#container-health-checks-and-autoheal)). If the app never responds (e.g. a missing dependency or a bad entry point killed it seconds after startup), it prints the last 50 lines of `docker logs` and exits non-zero instead of reporting success. The long window doesn't make a genuine crash slower to report: the loop watches the container's restart count and bails as soon as it rises. Requires `curl` on the host — if it's missing, the smoke test is skipped with a warning rather than treated as a hard dependency.
  - **It's a liveness check, not a correctness check.** It cannot catch an error *inside* an app that still serves HTTP: Streamlit and Shiny both catch script-level exceptions and render them in the browser, so a dashboard that throws on a missing data file returns 200 and is reported as deployed — accurately, since it *is* reachable; it just shows a traceback to whoever opens it. Always load the page once after a deploy. The smoke test's job is to stop you from walking away from a container that died on startup, not to verify the dashboard works.
- **Python builds are NOT pinned to `linux/amd64`, which matters when testing on an Apple Silicon Mac.** They build natively on whatever the host is, and pip resolves wheels per-architecture — so a local build can succeed or fail differently from Jetstream2. A real example: `pandas==0.24.2` has x86_64 wheels but no arm64 ones, so it installs instantly on the instance and tries (and fails) to compile from source on an ARM laptop. Native builds are kept as the default because they're much faster and modern packages behave identically on both; set `BUILD_PLATFORM=linux/amd64` when you specifically need to reproduce what the instance will do.
- **R Shiny builds are pinned to `linux/amd64` on non-amd64 hosts.** Posit publishes Shiny Server as an amd64-only `.deb`, so `Dockerfile.r-shiny` can't build natively on arm64 — on an Apple Silicon Mac, `gdebi` refuses the package several minutes into the build with an error that never mentions architecture. `resolve_build_platform()` (in [`common.sh`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/lib/common.sh)) detects a non-amd64 Docker host and adds `--platform linux/amd64`, which builds correctly under emulation, just slowly. Jetstream2 instances are x86_64 so this never applies in production — it exists so a change can actually be smoke-tested locally before deploying. Set `BUILD_PLATFORM` to override. The 3 Python frameworks build natively on either architecture and are unaffected.
- **The app process is PID 1, so `docker stop`/`docker restart` shut it down gracefully.** Each Dockerfile's `CMD` uses exec form with `exec`, which replaces the shell rather than leaving `/bin/sh` as PID 1. This matters because `sh` does not forward signals: with a plain shell-form `CMD`, `docker stop` would sit through its full 10-second timeout and then `SIGKILL` the app, every time, with no chance for it to close connections or flush state. If you add or change a `CMD`, keep the `["sh", "-c", "exec …"]` shape — the `sh -c` wrapper is what expands `$ENTRY_MODULE`/`$PORT` at runtime, and the `exec` is what makes signals work.
- Container always runs with `--restart unless-stopped`. Note this means a container whose app crashes on startup restarts in a loop — `docker stop <name>` breaks the loop while you investigate with `docker logs`.

**To update the app after a code change:** re-run `build_and_run.sh`. It rebuilds the image (Docker layer caching keeps this fast unless the system/package layers changed) and replaces the running container.

**To swap in a completely different app on the same instance:** point `build_and_run.sh` at the new project instead — e.g. `./deploy/build_and_run.sh /path/to/other-project [image-name]`. The default image/container name is `dashboard-app` when you don't pass one, but you don't need to keep it consistent across deploys: `run_container()` in `common.sh` runs `docker rm -f <container-name>` for the new name, then also removes *any other* container currently bound to the host ports this tool uses — **both** port 80 and the configured `APP_HOST_PORT` — regardless of its name. Both, because adopting nginx moves the app to a loopback port while the container from the previous direct deploy is still sitting on 80, where it would block nginx from ever binding. The lookup reads each container's `.HostConfig.PortBindings` rather than using `docker ps --filter publish=`, whose meaning isn't reliably the *host* port across Docker versions — too narrow and a stale container keeps the port; too broad and `docker rm -f` could destroy an unrelated container, which on a desktop instance can be the Guacamole server the researcher is connected through. This cleanly stops and removes whatever's currently running — no manual cleanup needed — and the old image tag just gets overwritten rather than accumulating on disk.

This tool is scoped to one app at a time per instance (see "Assumes one instance per project/researcher" at the top of this doc) — it doesn't support two apps running simultaneously: every container binds the same host port, so the port-based cleanup above is what prevents a differently-named second deploy from failing with "port is already allocated" or leaving the old container squatting on it. If you want two dashboards reachable at once, provision a second Jetstream2 instance rather than trying to run both here.

**To update data when using `DATA_DIR`:** just update the files at that host path and `docker restart <container-name>` — no rebuild needed, since the data is bind-mounted rather than baked in.

**Known limitations:**
- TLS requires a DNS name — Let's Encrypt cannot issue for a bare IP. See [TLS](#tls).
- R dependency auto-detection is static analysis — it won't catch packages loaded dynamically (e.g. via a variable passed to `library()`), so an unusual project may occasionally need an explicit `renv.lock` instead of relying on the scan.
- Framework detection is a regex/content-based heuristic, not a real dependency or AST analysis — it can occasionally get an unusual project wrong or find a genuine ambiguity, which is exactly what the `FRAMEWORK=` override exists for.

---

## Health and diagnosis

`manage.sh status` answers *is it up?*. `manage.sh health` answers *which layer is broken?* — a question that only appears once nginx is involved, because from a browser an app failure and a proxy failure look identical and need completely different fixes.

```bash
./deploy/manage.sh health              # for people
./deploy/manage.sh health --porcelain  # stable key=value, for the GUI
```

Everything is probed live. There is no sampler daemon and no log to go stale — the trade is that this tells you about the problem happening *now*, not one that has already passed. `docker logs` remains the record of what happened earlier.

The verdict is one of:

| Verdict | Meaning |
|---|---|
| `ok` | Reachable and answering |
| `not-deployed` | No container exists yet |
| `stopped` | The container exists but isn't running |
| `app-not-responding` | Container running, app inside it silent — check `manage.sh logs` |
| `proxy-down` | The app is fine; nginx isn't serving |
| `proxy-cannot-reach-app` | Both are up but nginx can't reach the app — check `/var/log/nginx/dashboard.error.log` |
| `unhealthy` | The app answers, but its Docker health check is failing |

> **`ok` means reachable, not correct.** Shiny and Streamlit catch script-level exceptions and render them *as a page*, answering 200 the whole time. Nothing short of opening the dashboard in a browser tells you it actually works. The same caveat applies to the post-deploy smoke test.

Alongside the verdict it reports the container's state, Docker health, restart count and uptime; its memory and CPU; free space on `/`; whether autoheal is running; and the three HTTP probes the verdict is derived from — the app directly, nginx's own `/_deploy/health`, and the public path. The three probes are the useful part when the verdict alone isn't enough:

```console
$ ./deploy/manage.sh health
Verdict:        ok — The dashboard is up and reachable.
Serving:        nginx on port 80  ->  app on 127.0.0.1:8080
  app direct    HTTP 200  (http://127.0.0.1:8080/)
  public path   HTTP 200  (http://127.0.0.1/)
```

`app direct` non-200 with `public path` non-200 is an app problem; `app direct` 200 with `public path` failing is a proxy problem. `--porcelain` emits every one of these as `key=value` (`verdict`, `app_http`, `public_http`, `nginx_http`, `nginx_service`, `proxy_enabled`, `app_bind`, `autoheal`, `restarts`, `mem_usage`, `cpu_pct`, `root_disk`, `url`, `detail`), which is what the GUI reads — it renders `verdict` through a lookup table and never parses the prose.

### Container health checks and autoheal

Every container `build_and_run.sh` starts gets a Docker health check — an HTTP GET of `/` on the framework's own port, supplied at run time rather than baked into the Dockerfiles (the port is only known at deploy time, and three of the four base images ship neither `curl` nor `wget`).

It is a **liveness** check for the same reason as above, and it deliberately treats any status below 500 as alive: an app serving its real UI from a sub-path is unusual but legitimate, and restarting it forever over a 404 would be worse than not checking.

`--restart unless-stopped` only reacts to the app process *exiting*. The failure worth catching is the one where it doesn't — alive, but no longer serving. Docker does not act on health status by itself, so bootstrap starts an **autoheal** sidecar that watches for `health=unhealthy` on containers labelled `autoheal=true` and restarts them, turning an outage that lasts until a human notices into one that lasts a few minutes. Disable it with `ENABLE_AUTOHEAL="no"`.

The start period is **300s**, pinned to `app_init_timeout` in `deploy/docker/shiny-server.conf` — the longest startup allowance any of the four frameworks grants itself, because a geospatial Shiny worker attaching sf/terra/GDAL/PROJ genuinely takes minutes to report "Listening on". A start period shorter than that allowance marks a healthy app unhealthy while it is still booting, which autoheal then "fixes" by restarting it, forever. **Raise both together or neither** — the constant is `HEALTH_START_PERIOD` in `deploy/lib/proxy.sh`.

The post-deploy smoke test uses the same window, for the same reason: a flat 60s wait reports a slow-but-fine app as a failed deploy, and when `bootstrap.sh` is driving that aborts the whole provision. A long window doesn't make real failures slower to find, though — the loop watches the container's restart count and bails immediately if the app crashed and was picked back up.

---

## Command reference

Everything below assumes the default image/container name `dashboard-app`; substitute your own if you passed `[image-name]` to `build_and_run.sh`. Run these from the repo root.

### The deployed dashboard

[`manage.sh`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/manage.sh) is a thin wrapper over `docker` — it exists so the GUI doesn't have to hardcode the container name, the host port and its own copy of the public-IP lookup. The plain `docker` equivalents still work and are listed alongside.

| Command | What it does |
|---|---|
| `./deploy/manage.sh status` | Is it deployed, running, and answering? Plus the URL, and which project/data folder it was published from. |
| `./deploy/manage.sh health` | *Which layer* is broken — see [Health and diagnosis](#health-and-diagnosis). Start here when the page won't load. |
| `./deploy/manage.sh url` | Print the public URL (fails if the dashboard isn't running). |
| `./deploy/manage.sh logs [N]` | Last N lines (default 200) of the app's own log, stdout **and** stderr. |
| `./deploy/manage.sh restart` | Restart the container without rebuilding. |
| `./deploy/manage.sh stop` | Stop it, and say plainly that it stays stopped across reboots. |
| `./deploy/manage.sh disk` | Free space, what Docker is using, and how much of it is reclaimable. |
| `./deploy/manage.sh cleanup` | Reclaim it — see [Reclaiming disk space](#reclaiming-disk-space). |
| `./deploy/manage.sh report [path]` | Write one diagnostic file to attach when asking for help. |

`status`, `health`, `disk` and `cleanup` all accept `--porcelain` for stable `key=value` output.

`report` bundles the health verdict, the disk figures, `docker ps -a`, the proxy state file, nginx's recent error log and the last 200 lines of the app's own log into a single timestamped file under `~/dashboard-deploy-logs/`. It collects nothing a researcher couldn't read themselves in the GUI — it exists because the alternative is asking someone on a remote desktop to run six commands and paste the output back.

```bash
# The same things by hand
docker ps                                  # what's running
docker ps -a                               # ...including stopped containers
docker logs dashboard-app                   # app logs
docker logs -f --tail 100 dashboard-app     # follow live
docker stats --no-stream dashboard-app      # memory / CPU right now
docker restart dashboard-app                # restart (also: stop / start)
docker rm -f dashboard-app                  # remove (build_and_run.sh does this for you)
docker exec -it dashboard-app bash          # shell inside the container
```

Two things worth knowing. `manage.sh logs` redirects stderr into stdout deliberately: gunicorn, Shiny Server and Streamlit all log to **stderr**, so anything capturing stdout alone gets an empty log and looks broken. And `docker stop` persists — `--restart unless-stopped` means a manually stopped container stays down across a reboot until you `docker start` it.

### The host and the proxy

```bash
sudo ./deploy/bootstrap.sh --check      # read-only snapshot: docker, nginx, swap, disk,
                                        # proxy state, listening sockets, then manage.sh health

# Is the app exposed to the internet, or only reachable through nginx?
sudo ss -tlnp | grep -E ':80|:8080'
# Expect nginx on 0.0.0.0:80 and docker-proxy on 127.0.0.1:8080 ONLY.
# Anything on 0.0.0.0:8080 means the app server is facing the internet directly.

# What the tooling thinks the topology is
cat /etc/dashboard-deploy/proxy.env

# nginx
sudo nginx -t                           # validate config before touching anything
sudo systemctl reload nginx             # apply a config change with no dropped connections
sudo systemctl restart nginx            # full restart
systemctl status nginx
sudo tail -f /var/log/nginx/dashboard.error.log    # proxy-side errors
sudo tail -f /var/log/nginx/dashboard.access.log   # who is hitting it
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/_deploy/health   # nginx alone, app not involved

# The autoheal sidecar (restarts a container Docker has marked unhealthy)
docker logs dashboard-autoheal
docker inspect -f '{{.State.Health.Status}}' dashboard-app   # what autoheal is reacting to

# Certificates, when a DNS name is configured
sudo certbot certificates
sudo certbot renew --dry-run
```

Never edit `/etc/nginx/sites-available/dashboard` directly — bootstrap re-renders it from [`deploy/nginx/dashboard.conf.template`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/nginx/dashboard.conf.template) on every run. Change the template or `deploy/deploy.env`, then re-run bootstrap.

### Reclaiming disk space

Every rebuild leaves the previous image's now-untagged layers behind, and Docker's build cache grows over time — on a small Jetstream2 volume this can fill the disk.

The safe subset of the commands below is wrapped up as two verbs, which is also what the desktop application's **Free up space** button runs:

```bash
./deploy/manage.sh disk       # where the space has gone, and how much is reclaimable
./deploy/manage.sh cleanup    # reclaim it
```

`cleanup` runs `docker image prune -f` (dangling layers only) and `docker builder prune -f` (the build cache). It deliberately does **not** use the `-a` variants or `docker container prune`: `-a` would remove the tagged dashboard image and the autoheal sidecar's image, turning "free up space" into "the next publish is a full rebuild and autoheal has to be re-pulled", and `container prune` would delete a *stopped* dashboard container — which is exactly the state someone is in right after pressing Stop, expecting to start it again. The threshold behind the low-disk warning lives in [`deploy/lib/disk.sh`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/lib/disk.sh) (`LOW_DISK_GB`), shared with `bootstrap.sh` so the figure warned about at provision time and the one the GUI shows later cannot drift apart.

For anything more aggressive, the underlying commands:

```bash
# How much is free on / — bootstrap warns below 15GB
df -h /

# See how much space Docker is using, broken down by category
docker system df

# Which images are the largest, newest first
docker images --format '{{.Size}}\t{{.Repository}}:{{.Tag}}\t{{.CreatedSince}}'

# Remove dangling images (untagged layers left over from rebuilds) — safe, does not touch running containers
docker image prune

# Remove ALL unused images (not just dangling ones — anything not referenced by a running container)
docker image prune -a

# Remove build cache
docker builder prune

# Nuclear option: remove all stopped containers, unused networks, dangling images, and build cache in one go
docker system prune

# Same as above, but also removes unused (non-dangling) images — most aggressive single command
docker system prune -a
```

`docker image prune -a` / `docker system prune -a` are generally safe here since this tool only ever runs one app at a time (see "Assumes one instance per project/researcher" above), but double-check `docker ps -a` first if you have other unrelated containers/images on the same instance. Two specific cautions on a researcher instance: **the autoheal sidecar is a running container**, so `prune -a` leaves it alone — but stop-and-prune sequences can catch it, and `sudo ./deploy/bootstrap.sh` puts it back. And the stale `dashboard-app` image is usually the single largest item and is safe to remove, at the cost of a full (not layer-cached) rebuild on the next publish.

A pruned build cache costs build time, not correctness. If disk is tight during a build specifically, `docker builder prune -f` is the one to reach for first — it's the item that grows without bound across rebuilds.

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

**`terra` is pinned automatically for this known case.** Both `generate_lock.R` (the auto-lockfile preflight) and `install_deps.R`'s no-lockfile fallback check the installed `gdal-config --version` before installing anything; if it's older than `3.8.0` (the GDAL version that added the 3-argument `GDALMDArray::AsClassicDataset()` overload `terra`'s C++ source calls), they pin `terra` to `1.8-5` — a version confirmed to compile against `rocker/geospatial:4.4.1`'s GDAL 3.4.1 — instead of installing whatever's newest on CRAN. This only helps when a project has *no* `renv.lock` of its own (letting this repo's own scan-and-install pick the version); a project that ships its own `renv.lock` pinning a newer, incompatible `terra` will still hit the compile failure, since a project-supplied lockfile is restored exactly as written — `install_deps.R` never overrides a version the project explicitly pinned. For that case, `install_deps.R` instead prints an upfront warning (comparing the lockfile's pinned `terra` version against the same GDAL threshold) before attempting `renv::restore()`, so the likely failure is obvious immediately rather than only after 3 retries' worth of waiting. If `BASE_IMAGE` is ever bumped to a `rocker/geospatial` tag shipping GDAL >= 3.8, both the auto-pin and the warning become no-ops automatically (the version check short-circuits) and the `KNOWN_COMPATIBLE_VERSIONS` table in both scripts can eventually be removed.

For every other case — a different package, a different system library, or a project-supplied lockfile that pins an incompatible version itself — pin an older, compatible version by hand and get a working build:

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

Run this inside whatever environment (virtualenv, conda env, or the same base image used for deployment) actually has the app working, so the pinned versions are ones you've confirmed work together.

### When an old project's pins no longer build

A common case with published demo and paper-companion repositories, whose `requirements.txt` was written years ago and pins only *direct* dependencies. Two distinct failures usually appear together, and fixing the first just reveals the second:

1. **A pinned package won't compile against the base image's Python.** e.g. `pandas==0.24.2` fails on `python:3.11-slim` with `fatal error: longintrepr.h: No such file or directory` — CPython made that header private in 3.11. No setuptools version fixes this. But such packages usually *do* have prebuilt wheels for the Python they were released against, so pointing at an older base image avoids compiling entirely: `BASE_IMAGE=python:3.7-slim`.
2. **Unpinned transitive dependencies have moved on.** `dash==1.12.0` doesn't constrain Flask or Werkzeug, so pip installs current versions and the app dies at *import*, not at build:
   `ImportError: cannot import name 'get_current_traceback' from 'werkzeug.debug.tbtools'`
   The fix is to pin what the original author relied on but never declared:

   ```
   werkzeug<2.1
   flask<2.2
   itsdangerous<2.1
   jinja2<3.1
   ```

Worth being explicit about the tradeoff: an end-of-life Python receives no security updates. It's a reasonable way to get an old dashboard running and evaluate it; it isn't a good long-term home for something publicly reachable. The durable fix is updating the pins, which for a Dash app of this vintage also means porting `import dash_core_components as dcc` to the modern `from dash import dcc`. Unlike R's geospatial packages, the 3 Python frameworks and their typical dependencies are mostly pure-Python or ship prebuilt wheels, so version drift against the base image's system libraries is a much rarer problem here — but a project depending on something that compiles from source (e.g. certain `geopandas`/GDAL-adjacent packages) can hit the same class of issue, and the same "pin it explicitly" fix applies.

---

## The desktop application

A Tkinter front end for everything above, aimed at researchers who'd rather not use a terminal. It is a **thin layer**: every action shells out to `build_and_run.sh` or `manage.sh`, so the two paths cannot drift apart, and any error you see is the script's own message rather than a paraphrase.

Start it from the desktop icon, or by hand:

```bash
./deploy/gui/launch_gui.sh
```

Four tabs, read left to right:

1. **Your app** — point it at a folder already on the server, clone a Git address, or unpack a `.zip`. It immediately reports the framework it detected and the entry point it found.
2. **Your data** — choose where your data lives (attached storage volumes are listed first, with free space), pick a transfer route, and verify what arrived. It always shows the host-path → container-path mapping, which is the detail people most often get wrong.
3. **Publish** — a plain-English readiness summary, then the build with live output. The button stays disabled until the project is actually deployable.
4. **Manage** — a live status panel, storage, the app's own logs, and the buttons: open, restart/start, stop, republish.

The Manage tab is the monitoring half of this tool, and everything on it comes from `manage.sh`:

- **It keeps checking on its own**, every 30 seconds, so a dashboard that recovers (or stops responding) is visible without pressing anything. The poll is skipped whenever the tab isn't the one on screen — those probes cost real time against a wedged app, and there's no reason to spend it on a tab nobody is looking at. Turn it off with **Keep checking automatically**; the timestamp beside it says when the reading is from.
- **The verdict is in plain language**, translated from `manage.sh health`'s enum through a lookup table (`HEALTH_HEADLINES` in `backend.py`) rather than by parsing prose, with the raw HTTP codes still shown underneath — those are the single most useful thing to quote when asking for help.
- **Storage is shown with the action next to it.** Free space, the size of the dashboard's own image, and how much is reclaimable; below `LOW_DISK_GB` it says what a shortage will actually cost (a build that fails partway with a confusing error) rather than just printing a number. **Free up space** runs `manage.sh cleanup` on a worker thread — see [Reclaiming disk space](#reclaiming-disk-space) for exactly what that does and doesn't remove.
- **Save a report to send for help** writes the `manage.sh report` bundle and offers to open the folder. **Save to a file…** does the same for the app's log alone.

**It reopens on whatever is currently published.** Closing and reopening the window used to lose the project folder and data folder, even while a dashboard of yours was serving — the application appeared to have forgotten something the instance plainly still knew. Every deploy now records where it came from as labels on the container itself (`dashboard.project_dir`, `dashboard.data_dir`, `dashboard.framework`, `dashboard.deployed_at`), which `manage.sh status` reports and the GUI restores tabs 1–3 from at startup.

The container is the source of truth rather than a state file, deliberately: it describes what is *actually serving*, so it cannot drift, it survives reboots, it is replaced atomically by the next deploy, and a deploy done from a terminal shows up in the GUI exactly like one done from the application. Three consequences worth knowing:

- A container deployed **before** this existed carries no labels, so the GUI restores nothing and behaves exactly as it did previously. Re-publishing once fixes it.
- The labels record where the app was **built from**, not a copy of what was in that folder. Edit the folder afterwards and the two genuinely differ, which is why tab 1 says *currently published* rather than *selected* and spells out that publishing again picks up the changes.
- If the folder has since been **deleted or moved**, tab 1 says so instead of restoring. The dashboard keeps running regardless — its code was copied into the image at build time.

Three further behaviours worth knowing about:

- **A build survives losing the desktop session.** Builds run detached and write to `~/dashboard-deploy-logs/`; the window only tails that file. If your remote-desktop connection drops mid-build — or you close the window — the build carries on, and reopening the application reattaches to it. Every publish leaves a timestamped log, which is the most useful thing to send if you need help.
- **It never claims your dashboard is correct.** The post-publish message says the app is *live* and asks you to open it, because the underlying check only proves the app is answering. Shiny and Streamlit render their own errors in the browser and still return HTTP 200 — see the smoke-test note above.
- **It can make your data volume survive a reboot.** If your data is on a volume that isn't in `/etc/fstab`, the data tab offers to add it, showing the exact line first and asking for an administrator password via the system's own dialog. See [Reboot persistence](#reboot-persistence).

### Reboot persistence

A volume mounted by hand does **not** come back after a reboot. When that happens, Docker silently creates an empty directory at the expected path and mounts that instead, so the dashboard restarts with no data — and because the smoke test only proves liveness, the deploy still reports success.

[`deploy/lib/persist_mount.sh`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/lib/persist_mount.sh) fixes this by adding an `/etc/fstab` entry. It runs as root (via `pkexec`), and is written defensively because a bad fstab can leave an instance unbootable at an emergency console a remote-desktop user cannot reach:

- `nofail`, so a detached volume never blocks boot, plus `x-systemd.device-timeout=10s`, since `nofail` alone still lets systemd wait 90 seconds for a missing device.
- The existing file is backed up, then the result is validated with `findmnt --verify` and `mount -a`; if either complains, the backup is restored automatically.
- `systemctl daemon-reload` before mounting, because systemd caches mount units generated from fstab — skipping it produces the classic "worked when I tested it, did nothing after reboot".
- Idempotent: an entry for the same UUID *or* mountpoint is reported and left alone, so pressing the button twice cannot create a duplicate.

To do it manually instead:

```bash
sudo /usr/local/libexec/persist_mount.sh <uuid> /media/volume/<name> ext4
# check without changing anything (no root needed):
./deploy/lib/persist_mount.sh --check <uuid> /media/volume/<name>
```

Afterwards, the only test that really counts is rebooting and confirming the data is still there.

### Building the researcher image

[`deploy/desktop/setup_image.sh`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/deploy/desktop/setup_image.sh) prepares an instance to be saved as the image researchers clone. Run it once on a fresh instance, then create the image in Exosphere:

```bash
sudo ./deploy/desktop/setup_image.sh
```

It installs `python3-tk` (**not** part of `python3` on Ubuntu — without it the desktop icon silently does nothing), `policykit-1`, `zenity`, `xdg-utils` and the transfer tools; clones this repo; installs the desktop launcher to both the applications menu and `~/Desktop` with the executable bit *and* GNOME's "trusted" flag; installs `persist_mount.sh` to `/usr/local/libexec`; adds an SSH login banner; and pre-pulls all three base images. That last one matters: `rocker/geospatial` is several GB, and pulling it during a researcher's first publish looks like a ten-minute hang.

It's idempotent, so re-run it to refresh an existing image.

---

## Developing on this repo

The deployment tooling is itself shell scripts, so there's a shellcheck pass over them:

```bash
./deploy/lint.sh
```

To have it run automatically before each commit (tracked in `.githooks/` rather than `.git/hooks/`, so it's version-controlled — one-time opt-in per clone):

```bash
git config core.hooksPath .githooks
```

The hook only fires when a commit actually touches a `.sh` file, skips with a warning if shellcheck isn't installed, and can be bypassed with `git commit --no-verify`. Install shellcheck with `brew install shellcheck` (macOS) or `sudo apt-get install shellcheck` (Ubuntu).

This is a lint, not a test: it catches quoting/expansion defects, not whether an image builds or an app starts. For that, run one of the bundled examples through `build_and_run.sh` (see "Deploying your app" above) — and note that R Shiny builds on a non-amd64 machine go through emulation, so they're slow but they do work.

---

## Open items / possible future work

- A curated list of known-good `BASE_IMAGE` overrides per framework for common heavier dependencies (e.g. a GDAL-ready Python image for geospatial Dash/Streamlit apps, analogous to `rocker/geospatial` for R).
