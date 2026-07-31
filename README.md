# Jetstream2 Dashboard Deploy

Deployment tooling that helps scientific researchers get their data dashboards out of a laptop/notebook and onto a publicly accessible web server on [Jetstream2](https://jetstream-cloud.org/) — no DevOps background required. Point it at any **R Shiny**, **Plotly Dash**, **Python Shiny**, or **Streamlit** project and get it reachable in a browser on port 80, with no manual GDAL/GEOS wrangling, no hand-written package lists (where the framework allows it), and no figuring out which Dockerfile or run command to use.

A single script, [`deploy/build_and_run.sh`](deploy/build_and_run.sh), auto-detects which of the four frameworks a dropped-in project is (from its code, not just filenames), builds a self-contained Docker image, and runs it. A companion script, [`deploy/bootstrap.sh`](deploy/bootstrap.sh), provisions a bare instance to host it — Docker, swap, an nginx reverse proxy, TLS, and automatic restart of a wedged dashboard. There's also a **desktop application** for researchers who'd rather not use a terminal at all. This README covers the basics; full details, design rationale, and the auto-detection story are in [`docs/deployment.md`](docs/deployment.md).

## Quick start

Set the instance up once, then deploy as often as you like:

```bash
git clone https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy.git
cd Jetstream2_Dashboard_Deploy

# One-time: provision the host (Docker, nginx, swap, TLS, health monitoring)
sudo ./deploy/bootstrap.sh

# Try it with a bundled self-test app first (one per framework):
cp -r examples/r-shiny-hello-world/* deploy/app/
./deploy/build_and_run.sh

# Then deploy a real project the same way — any of the 4 frameworks:
cp -r /path/to/your/project/* deploy/app/
./deploy/build_and_run.sh
```

Visit `http://<instance-fixed-ip>/` in a browser.

`bootstrap.sh` is optional — skip it and the container publishes port 80 directly, exactly as this tool has always worked. Run it and nginx serves port 80 while the app binds loopback only, which is what makes TLS, rate limiting, upload limits and a proper maintenance page possible. It can also do both halves at once:

```bash
sudo ./deploy/bootstrap.sh /path/to/your/project
```

## Or use the desktop application

On a Jetstream2 instance built from the prepared image, researchers can open **Deploy My Dashboard** from the desktop instead. Four steps — your app, your data, publish, manage — with no terminal required:

```bash
./deploy/gui/launch_gui.sh    # or just click the desktop icon
```

It's a thin front end over the same `build_and_run.sh`, so nothing is hidden and the two paths can't drift apart. Builds keep running even if the remote-desktop session drops. See [the desktop application](docs/deployment.md#the-desktop-application).

New to moving files onto a cloud instance? [Getting your files onto the instance](docs/getting-your-files-onto-the-instance.md) covers Git, drag-and-drop, rsync, cloud storage, and Globus.

## What's in here

```
deploy/
├── build_and_run.sh         # the one script: detects framework, builds, runs, smoke-tests
├── bootstrap.sh             # root-only: provision the host (Docker, nginx, TLS, swap, autoheal)
├── deploy.env.example       # template for bootstrap's host-specific settings
├── manage.sh                # status / health / logs / restart / stop for a deployed app
├── lint.sh                  # shellcheck + python syntax check
├── lib/
│   ├── common.sh            # shared build/run/retry/smoke-test/data-dir logic
│   ├── detect_framework.sh  # framework auto-detection
│   ├── proxy.sh             # where the container binds, and how it's health-checked
│   └── persist_mount.sh     # root-only: make a data volume survive reboot
├── nginx/
│   ├── dashboard.conf.template  # the reverse proxy config (WebSockets, rate limits, gzip)
│   └── unavailable.html         # shown instead of a bare 502 while the app is down
├── docker/
│   ├── Dockerfile.r-shiny        # R Shiny (Shiny Server)
│   ├── Dockerfile.dash           # Plotly Dash (gunicorn)
│   ├── Dockerfile.python-shiny   # Python Shiny (shiny run)
│   ├── Dockerfile.streamlit      # Streamlit
│   ├── apt_retry.sh              # shared retry-wrapped apt-get helper
│   ├── install_deps.R            # R-Shiny-only: auto-installs the app's R packages
│   ├── generate_lock.R           # R-Shiny-only: generates a missing renv.lock pre-build
│   └── shiny-server.conf         # R-Shiny-only Shiny Server config
├── gui/                     # the desktop application (Tkinter, stdlib only)
│   ├── launch_gui.sh        #   preflight checks, then starts it
│   ├── backend.py           #   the only module that runs shell commands
│   ├── runner.py            #   streams a long build without freezing the UI
│   ├── ui.py                #   the four tabs
│   ├── volumes.py           #   finds attached storage volumes
│   └── transfer.py          #   the four ways to get data here
├── desktop/                 # launcher icon + image build script
└── app/                     # drop-in slot for the project to deploy (gitignored)
examples/
├── r-shiny-hello-world/       # R Shiny self-test app
├── dash-hello-world/          # Plotly Dash self-test app
├── python-shiny-hello-world/  # Python Shiny self-test app
└── streamlit-hello-world/     # Streamlit self-test app
docs/
├── deployment.md             # full walkthrough, prerequisites, and design rationale
└── getting-your-files-onto-the-instance.md   # git, rsync, cloud storage, Globus
.githooks/
└── pre-commit                # runs deploy/lint.sh before each commit (opt-in)
```

See [`docs/deployment.md`](docs/deployment.md) for prerequisites, step-by-step instructions, and the reasoning behind each design choice.

## Managing the running app

`build_and_run.sh` names both the image and the container `dashboard-app` by default (or whatever `[image-name]` you passed it). To swap in a different project, just re-run `./deploy/build_and_run.sh` — no need to stop or remove anything first.

```bash
./deploy/manage.sh health    # what's working, and which layer isn't
docker ps                    # check what's running
docker logs -f dashboard-app # view / follow app logs
docker restart dashboard-app # restart without rebuilding
```

`manage.sh health` is the one to reach for when the dashboard doesn't load: with nginx in front, an app failure and a proxy failure look identical from a browser but need different fixes, and it says which you have. Note that a healthy verdict means *reachable*, not *correct* — Shiny and Streamlit render their own errors as a page and still answer 200.

See [`docs/deployment.md`](docs/deployment.md#health-and-diagnosis) for the full command reference, including reclaiming disk space from old images.

## License

MIT — see [LICENSE](LICENSE).
