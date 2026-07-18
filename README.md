# Jetstream2 RShiny Deploy

Deployment tooling for running an R Shiny app on a [Jetstream2](https://jetstream-cloud.org/) instance. Point it at any R Shiny project and get it reachable in a browser on port 80 — no manual GDAL/GEOS wrangling, no hand-written package lists.

Two workflows, both covered in detail in [`docs/deployment.md`](docs/deployment.md):

- **Docker** (recommended default) — builds a self-contained image with the app baked in. R package dependencies are auto-detected from the app's code, no Dockerfile edits needed per project.
- **Bare-metal** — provisions Shiny Server + Nginx directly on the instance, for researchers who want to `git pull`/edit the app in place.

## Quick start (Docker)

```bash
git clone https://github.com/stephenconklin/Jetstream2_RShiny_Deploy.git
cd Jetstream2_RShiny_Deploy

# Try it with the bundled self-test app first:
cp -r examples/hello-world/* deploy/docker/app/
./deploy/docker/build_and_run.sh

# Then deploy a real project the same way:
cp -r /path/to/your/shiny/project/* deploy/docker/app/
./deploy/docker/build_and_run.sh
```

Visit `http://<instance-fixed-ip>/` in a browser.

## What's in here

```
deploy/
├── provision_baremetal.sh   # bare-metal: Shiny Server + Nginx on Ubuntu 22.04
└── docker/
    ├── Dockerfile           # generic single-app Shiny image
    ├── install_deps.R       # auto-detects and installs the app's R packages
    ├── build_and_run.sh     # build + run, for any dropped-in Shiny project
    └── app/                 # drop-in slot for the project to deploy (gitignored)
examples/
└── hello-world/             # minimal self-test app (classic Shiny "Old Faithful" example)
docs/
└── deployment.md            # full walkthrough of both workflows
```

See [`docs/deployment.md`](docs/deployment.md) for prerequisites, step-by-step instructions, and the reasoning behind each design choice.

## License

MIT — see [LICENSE](LICENSE).
