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
    ├── app.R              ← the starting file
    ├── renv.lock          ← the package list (Part 2, step 2)
    ├── R/                 ← optional: helper scripts
    ├── www/               ← optional: images, CSS
    └── data/              ← optional: small data files
    ```

    Any **one** of these three arrangements works:

    | Arrangement | Files |
    |---|---|
    | Single file | `app.R` |
    | Split | `ui.R` **and** `server.R` |
    | R Markdown | any `.Rmd` with `runtime: shiny` in its YAML front matter (this covers **flexdashboard**) |

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

---

## The rules that catch people out

### The starting file must be at the top level

Not in `src/`, not in `app/`, not in `inst/`. The tooling looks in the folder
you point it at, and nowhere below it.

If your project keeps its app in a subfolder, the fix is a **shim** — a tiny
file at the top level that hands off to the real one:

=== "R Shiny"

    A [golem](https://engineering-shiny.org/) package ships its app at
    `inst/app.R`, which won't be found. Add this as `app.R` in the project
    root:

    ```r
    # app.R — shim so the deployment tooling can find this golem app
    pkgload::load_all(export_all = FALSE, helpers = FALSE, attach_testthat = FALSE)
    myPackageName::run_app()
    ```

    The tooling gives you a specific error naming this situation if it sees an
    `inst/app.R` and no root-level entry point, so you'll know if it applies.

=== "Python"

    ```python
    # app.py — shim so the deployment tooling can find the real app
    from src.dashboard.main import app   # noqa: F401
    server = app.server                  # Dash only
    ```

### There must be exactly one framework signal

If the tooling finds Dash signals in one file and Streamlit signals in another,
it **stops and asks** rather than guessing. That's usually a leftover:
an old `app.py` you replaced, a scratch file, an example you copied in.

Delete or rename the file you don't want deployed. (Renaming to
`_old_app.py.bak` is enough — the scan only looks at `.py`, `.R` and `.Rmd`
files.)

If the ambiguity is real and intentional, you can override detection at publish
time — see [Step 3 · Publish](../part3-deploy/step3-publish.md#advanced-options).

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
`.git`, `.venv` / `venv`, `.env`, `__pycache__`, `node_modules`, `.Rproj.user`,
`.DS_Store`, and the `data/` folder (that gets mounted at run time instead).

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

It prints the framework it detected, the entry point it found, and whether your
package list is present. It changes nothing.

The application in Part 3 runs exactly this for you and shows you the result the
moment you select your folder — so if you'd rather not do it here, you'll find
out within seconds there.

---

Next → **[Create your package list](r-packages.md)** — R, or
[Python](python-packages.md).
