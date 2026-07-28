# Jetstream2 Dashboard Deploy

Deployment tooling that helps scientific researchers get their data dashboards out of a laptop/notebook and onto a publicly accessible web server on [Jetstream2](https://jetstream-cloud.org/) — no DevOps background required. Point it at any **R Shiny**, **Plotly Dash**, **Python Shiny**, or **Streamlit** project and get it reachable in a browser on port 80, with no manual GDAL/GEOS wrangling, no hand-written package lists (where the framework allows it), and no figuring out which Dockerfile or run command to use.

A single script, [`deploy/build_and_run.sh`](deploy/build_and_run.sh), auto-detects which of the four frameworks a dropped-in project is (from its code, not just filenames), builds a self-contained Docker image, and runs it bound to port 80. This README covers the basics; full details, design rationale, and the auto-detection story are in [`docs/deployment.md`](docs/deployment.md).

## Quick start

```bash
git clone https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy.git
cd Jetstream2_Dashboard_Deploy

# Try it with a bundled self-test app first (one per framework):
cp -r examples/r-shiny-hello-world/* deploy/app/
./deploy/build_and_run.sh

# Then deploy a real project the same way — any of the 4 frameworks:
cp -r /path/to/your/project/* deploy/app/
./deploy/build_and_run.sh
```

Visit `http://<instance-fixed-ip>/` in a browser.

## What's in here

```
deploy/
├── build_and_run.sh         # the one script: detects framework, builds, runs, smoke-tests
├── lint.sh                  # shellcheck pass over every shell script here
├── lib/
│   ├── common.sh            # shared build/run/retry/smoke-test/data-dir logic
│   └── detect_framework.sh  # framework auto-detection
├── docker/
│   ├── Dockerfile.r-shiny        # R Shiny (Shiny Server)
│   ├── Dockerfile.dash           # Plotly Dash (gunicorn)
│   ├── Dockerfile.python-shiny   # Python Shiny (shiny run)
│   ├── Dockerfile.streamlit      # Streamlit
│   ├── apt_retry.sh              # shared retry-wrapped apt-get helper
│   ├── install_deps.R            # R-Shiny-only: auto-installs the app's R packages
│   ├── generate_lock.R           # R-Shiny-only: generates a missing renv.lock pre-build
│   └── shiny-server.conf         # R-Shiny-only Shiny Server config
└── app/                     # drop-in slot for the project to deploy (gitignored)
examples/
├── r-shiny-hello-world/       # R Shiny self-test app
├── dash-hello-world/          # Plotly Dash self-test app
├── python-shiny-hello-world/  # Python Shiny self-test app
└── streamlit-hello-world/     # Streamlit self-test app
docs/
└── deployment.md             # full walkthrough, prerequisites, and design rationale
.githooks/
└── pre-commit                # runs deploy/lint.sh before each commit (opt-in)
```

See [`docs/deployment.md`](docs/deployment.md) for prerequisites, step-by-step instructions, and the reasoning behind each design choice.

## Managing the running app

`build_and_run.sh` names both the image and the container `dashboard-app` by default (or whatever `[image-name]` you passed it), always bound to host port 80. To swap in a different project, just re-run `./deploy/build_and_run.sh` — no need to stop or remove anything first.

```bash
docker ps                    # check what's running
docker logs -f dashboard-app # view / follow app logs
docker restart dashboard-app # restart without rebuilding
```

See [`docs/deployment.md`](docs/deployment.md#managing-the-deployed-container) for the full command reference, including reclaiming disk space from old images.

## License

MIT — see [LICENSE](LICENSE).
