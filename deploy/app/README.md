# Drop your project here

Put your project directly in this folder — one of the entry-point
conventions below, plus any `data/` it reads from — then from the repo root
run:

```bash
./deploy/build_and_run.sh
```

The framework is auto-detected from your code. Supported conventions:

- **R Shiny** — `app.R`, or a `ui.R` + `server.R` pair, or an `.Rmd` with
  `runtime: shiny` in its YAML front matter.
- **Plotly Dash** — `app.py` with `import dash` and `server = app.server`.
- **Python Shiny** — `app.py` with `from shiny import App` and a top-level
  `app = App(...)`.
- **Streamlit** — `streamlit_app.py` (or `app.py`) with `import streamlit`.

If detection ever guesses wrong or a project is genuinely ambiguous, force a
choice with `FRAMEWORK=r-shiny|dash|python-shiny|streamlit`.

Optional files you can add alongside your app code:

- `renv.lock` (R Shiny only) — if present, exact package versions are
  restored from it. Otherwise dependencies are auto-detected by scanning
  your code for `library()`/`require()` calls.
- `requirements.txt` (Dash / Python Shiny / Streamlit) — **required** for
  these frameworks; Python has no reliable way to infer package names from
  import statements the way R's static scan does, so this can't be
  optional. Run `pip freeze > requirements.txt` in your working environment.
- `apt.txt` — one system package per line, for anything your project needs
  beyond the base image (e.g. `default-jdk` for `rJava`, `libgdal-dev` for a
  `geopandas`/`sf` dependency).

To deploy a project that lives elsewhere instead of copying it here, pass its
path directly: `./deploy/build_and_run.sh /path/to/project`.

To smoke-test the deploy tooling itself before pointing it at a real project,
copy in one of the bundled examples, e.g.
`cp -r examples/r-shiny-hello-world/* deploy/app/` (or
`dash-hello-world`/`python-shiny-hello-world`/`streamlit-hello-world`).

Everything in this folder except this README is gitignored — it's a working
slot, not something to commit.
