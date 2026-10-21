# Check your file layout

<p class="meta-line">10 minutes.</p>

The tooling works out which framework your project uses by **reading your
code**, not by looking at filenames. That's deliberate — an `app.py` could be
Dash, Python Shiny, Streamlit, or plain Flask, and guessing from the name alone
would be wrong often enough to matter.

Two things need to be true: your app's **starting file** must be at the top
level of your project folder, and it must contain a recognisable **signal**.

---

## What your project folder should look like

=== "R Shiny"

    ```
    my-dashboard/
    ├── app.R              ← the starting file (any name works — see below)
    ├── renv.lock          ← the package list (Part 2, step 2)
    ├── R/                 ← optional: helper scripts
    ├── www/               ← optional: images, CSS
    └── data/              ← optional: small data files
    ```

    Any **one** of these arrangements works:

    | Arrangement | Files |
    |---|---|
    | Single file | `app.R`, **or any other name** — `water_quality.R` is fine, as long as it calls `shinyApp(...)` |
    | Split | `ui.R` **and** `server.R` |
    | R Markdown | any `.Rmd` with `runtime: shiny` in its YAML front matter (this covers **flexdashboard**) |

    **You don't need to rename your file to `app.R`.** The server only
    understands `app.R`, so when your main file has another name, publishing
    adds a one-line `app.R` that runs it, in the published copy only. If
    several files call `shinyApp(...)` (an `app_old.R` alongside the real one,
    say), the application asks you which one is the dashboard.

    The R Markdown form is recognised by the front matter, so it must contain:

    ```yaml
    ---
    title: "My dashboard"
    runtime: shiny          # ← this line is what's detected
    output: flexdashboard::flex_dashboard
    ---
    ```

=== "Plotly Dash"

    ```
    my-dashboard/
    ├── app.py             ← the starting file
    ├── requirements.txt   ← the package list (Part 2, step 2)
    ├── assets/            ← optional: CSS, images (Dash serves these)
    └── data/              ← optional: small data files
    ```

    `app.py` must contain **both**:

    ```python
    import dash                       # or: from dash import Dash

    app = dash.Dash(__name__)
    server = app.server               # ← required
    ```

    The `server = app.server` line is not optional. Dash's development server
    is not used in production; the deployment runs your app under **gunicorn**,
    which needs that object to exist. Without it the build succeeds and the app
    fails to start.

=== "Python Shiny"

    ```
    my-dashboard/
    ├── app.py             ← the starting file
    ├── requirements.txt   ← the package list (Part 2, step 2)
    ├── www/               ← optional: static files
    └── data/              ← optional: small data files
    ```

    `app.py` must contain **both** an import and a top-level `App` object:

    ```python
    from shiny import App, render, ui   # ← the import

    app_ui = ui.page_fluid(...)

    def server(input, output, session):
        ...

    app = App(app_ui, server)           # ← at the top level, not inside a function
    ```

=== "Streamlit"

    ```
    my-dashboard/
    ├── streamlit_app.py   ← the starting file (app.py also works)
    ├── requirements.txt   ← the package list (Part 2, step 2)
    ├── pages/             ← optional: multi-page apps
    ├── .streamlit/        ← optional: config.toml
    └── data/              ← optional: small data files
    ```

    The file must contain:

    ```python
    import streamlit as st
    ```

    `streamlit_app.py` is preferred and checked first; `app.py` also works.
    If you have both, `streamlit_app.py` wins.

!!! tip "Python files can have any name too"

    `app.py` and `streamlit_app.py` are conventions, not requirements: the
    file is found by what's in it. One limit for Dash and Python Shiny: the
    server loads the file as a Python module, so its name may only use
    letters, digits and underscores (`water_quality.py`, not
    `water-quality.py`).

---

## The rules that catch people out

### Where the starting file can be { #the-starting-file-must-be-at-the-top-level }

=== "R Shiny"

    At the top of your project folder, or **one folder down**. Many projects
    keep the app in its own folder beside `data/` and their settings, and run
    it with `shiny::runApp("app")`:

    ```text
    my-project/
    ├── app/
    │   ├── app.R        ← found
    │   └── R/           ← loaded automatically, as on your computer
    ├── data/
    └── config.yml
    ```

    That's found as `app/app.R` and run from inside `app/`, exactly as
    `runApp("app")` runs it, so paths like `"../config.yml"` keep working.
    Nothing is added to your folder: the published copy gets a one-line
    `app.R` at the top that starts the real one.

    A top-level app always wins: the subfolders are only searched when the top
    of the folder has none. These are never treated as apps: `R/`, `renv/`,
    `inst/`, `tests/`, `testthat/`, `www/`, your data folder, `rsconnect/`
    and `packrat/`. Deeper than one folder down, name the file yourself: in
    the application with **Choose another file…** on tab 1, or on the command line
    with `ENTRY_FILE=src/dashboard/app.R`. A file in a subfolder must end with
    its own `shinyApp(...)` call.

    A [golem](https://engineering-shiny.org/) package ships its app at
    `inst/app.R`, which isn't searched, because it needs the package loaded
    first. Add this as `app.R` in the project root:

    ```r
    # app.R — shim so the deployment tooling can find this golem app
    pkgload::load_all(export_all = FALSE, helpers = FALSE, attach_testthat = FALSE)
    myPackageName::run_app()
    ```

    The tooling gives you a specific error naming this situation if it sees an
    `inst/app.R` and no root-level entry point, so you'll know if it applies.

=== "Python"

    At the top of your project folder. Not in `src/` or `app/`: the Python
    servers start in the project folder and import the main file from there.
    If your project keeps its app in a subfolder, add a **shim**, a tiny file
    at the top that hands off to the real one:

    ```python
    # app.py — shim so the deployment tooling can find the real app
    from src.dashboard.main import app   # noqa: F401
    server = app.server                  # Dash only
    ```

### If more than one file could be the app, you'll be asked

If the tooling finds several files that could be your dashboard — two `.R`
files that call `shinyApp()`, or Dash signals in one `.py` file and Streamlit
signals in another — it **asks rather than guessing**. That's usually a
leftover: an old version you replaced, a scratch file, an example you copied
in.

In the application, pick the right one on
[tab 1](../part3-deploy/step1-your-app.md#your-dashboards-main-file). On the
command line, name it with `ENTRY_FILE=water_quality.R`. Or delete or rename
the file you don't want deployed — renaming to `_old_app.py.bak` is enough,
since the scan only looks at `.py`, `.R` and `.Rmd` files.

### Your app must listen on all interfaces, not just localhost

This one is invisible until it fails. Inside a container, `127.0.0.1` means
*inside the container only*, so an app bound there is unreachable from outside
it — the deployment reports that the app never answered.

Mostly you don't have to do anything, because the tooling supplies the correct
options when it starts your app. But if your code **hardcodes** a host or port,
remove it:

=== "R Shiny"

    ```r
    # Remove or guard lines like this — Shiny Server handles it:
    shinyApp(ui, server, options = list(host = "127.0.0.1", port = 3838))

    # This is fine:
    shinyApp(ui, server)
    ```

=== "Plotly Dash"

    ```python
    # This block is ignored in deployment (gunicorn imports `server`
    # instead of running the file), so it can stay for local development:
    if __name__ == "__main__":
        app.run(debug=True)
    ```

=== "Python Shiny / Streamlit"

    ```python
    # Don't call shiny.run_app() or set server.address in .streamlit/config.toml.
    # The deployment starts the server with the right host and port itself.
    ```

---

## Files you should *not* ship

Some things are skipped automatically when your project is packaged up:
`.git`, `.venv` / `venv`, `.env`, `__pycache__`, `node_modules`, `.DS_Store`,
RStudio's leftovers (`.Rproj.user`, `.RData`, `.Rhistory`, `rsconnect/`), an
`renv/library` built for your own computer, and your `data/` folder **if** you
chose to attach your data from a storage volume instead.

An `.Rprofile` that activates `renv` is also switched off in the published
copy: the library it points to isn't on the server, and your packages are
installed into the dashboard directly. The rest of your `.Rprofile` still
applies.

You don't need to delete them — but it's worth knowing they won't be there, so
don't rely on any of them at run time. In particular:

!!! warning "Secrets in `.env` will not be present"

    A `.env` file is deliberately excluded so it can't end up baked into the
    image. If your app needs an API key or a database password, it will not
    find it. See
    [Questions people ask](../help/faq.md#how-do-i-give-my-dashboard-a-secret-api-key).

---

## Check it

You can verify the layout is right without deploying anything, and without
building anything, using the tooling's **dry run**. You'll do this on the
server in Part 3 — but if you have the repository handy on your own machine and
a terminal open, it works there too:

```bash
./deploy/build_and_run.sh --dry-run /path/to/my-dashboard
```

It prints the framework it detected, the main file it found, whether your
package list is present, and anything in your code worth checking (a
`setwd()`, a path on your own computer). It changes nothing.

The application in Part 3 runs exactly this for you and shows you the result the
moment you select your folder — so if you'd rather not do it here, you'll find
out within seconds there.

---

Next → **[Create your package list](r-packages.md)** — R, or
[Python](python-packages.md).
