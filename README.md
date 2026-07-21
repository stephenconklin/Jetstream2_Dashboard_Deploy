# Jetstream2 Dashboard Deploy

Deployment tooling for running a dashboard/app on a [Jetstream2](https://jetstream-cloud.org/) instance. Point it at any **R Shiny**, **Plotly Dash**, **Python Shiny**, or **Streamlit** project and get it reachable in a browser on port 80 — no manual GDAL/GEOS wrangling, no hand-written package lists (where the framework allows it), no figuring out which Dockerfile or run command to use.

A single script, [`deploy/build_and_run.sh`](deploy/build_and_run.sh), auto-detects which of the four frameworks a dropped-in project is (from its code, not just filenames), builds a self-contained Docker image, and runs it bound to port 80. Full details, design rationale, and the auto-detection story are in [`docs/deployment.md`](docs/deployment.md).

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
│   └── shiny-server.conf         # R-Shiny-only Shiny Server config
└── app/                     # drop-in slot for the project to deploy (gitignored)
examples/
├── r-shiny-hello-world/       # R Shiny self-test app
├── dash-hello-world/          # Plotly Dash self-test app
├── python-shiny-hello-world/  # Python Shiny self-test app
└── streamlit-hello-world/     # Streamlit self-test app
docs/
└── deployment.md             # full walkthrough, prerequisites, and design rationale
```

See [`docs/deployment.md`](docs/deployment.md) for prerequisites, step-by-step instructions, and the reasoning behind each design choice.

## License

MIT — see [LICENSE](LICENSE).
