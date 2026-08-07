# Before you start

Two things have to be in place before Part 1, and one of them can take several
days. Read this page first even if you plan to skip ahead.

---

## 1. A Jetstream2 allocation

Jetstream2 is a national cloud resource funded by the U.S. National Science
Foundation and operated by Indiana University. Access is free to U.S.-based
researchers and educators, but it is *allocated* rather than open — you request
a share of it through **ACCESS**, the NSF's allocation system.

If you don't have one yet:

1. **Register for an ACCESS ID** at
   [access-ci.org](https://access-ci.org/) if you don't already have one.
2. **Request an allocation.** For a dashboard, an *Explore* allocation
   (the smallest tier) is normally plenty and is the quickest to be granted.
3. **Wait.** Explore requests are typically reviewed within a week.

The Jetstream2 documentation walks through this in detail:
[Getting started → Allocations](https://docs.jetstream-cloud.org/alloc/overview/).

!!! question "Already in a lab that uses Jetstream2?"

    Ask your PI to add you to their existing allocation instead — that takes
    minutes rather than days. You'll need to give them your ACCESS ID.

### What an allocation actually buys you

Allocations are measured in **service units (SUs)**, which are roughly
*CPU-cores × hours*. A dashboard server is small and cheap to run:

| Instance size | vCPUs | RAM | SUs per hour | Roughly |
|---|---|---|---|---|
| `m3.small` | 2 | 6 GB | 2 | 1,500 SU/month |
| `m3.medium` | 8 | 30 GB | 8 | 5,800 SU/month |

An Explore allocation of 100,000 SUs runs an `m3.small` continuously for over
five years' worth of hours, or an `m3.medium` for about 14 months. Storage
volumes are charged separately and much more cheaply.

The practical consequence: **shut down instances you aren't using**, but don't
agonise about leaving a dashboard running. That's what it's for.

---

## 2. A working dashboard

The tooling supports four frameworks. It works out which one you're using by
reading your code, so you don't have to tell it.

<div class="grid cards" markdown>

-   **R Shiny**

    An `app.R`, or a `ui.R` + `server.R` pair, or an R Markdown document with
    `runtime: shiny` in its front matter.

-   **Plotly Dash**

    An `app.py` that does `import dash` and exposes `server = app.server`.

-   **Python Shiny**

    An `app.py` with `from shiny import App` and a top-level `app = App(...)`.

-   **Streamlit**

    A `streamlit_app.py` or `app.py` that does `import streamlit`.

</div>

"Working" means: you can start it on your own computer and use it in a browser
without errors. If it doesn't work on your laptop, publishing it will not fix
it — and debugging is far harder once it's inside a container on a remote
server. Get it working locally first.

!!! info "Using something else?"

    Flask, FastAPI, Panel, Voilà, Quarto dashboards and Observable are **not**
    supported by this tooling. You can still run them on a Jetstream2 instance,
    but you'd be doing the Docker and web-server work yourself — start from the
    [Jetstream2 documentation](https://docs.jetstream-cloud.org/) instead of
    this guide.

---

## What you do *not* need

You do not need any of the following, and this guide will not ask you to learn
them:

- **Docker.** The application builds and runs the container for you.
- **A web server.** nginx is already installed and configured on the prepared
  image.
- **A domain name.** Your dashboard gets a numeric IP address, which works
  fine. A domain name is optional and only needed for `https://` — see
  [Share and update your dashboard](part3-deploy/share-your-dashboard.md#can-i-get-https).
- **SSH keys**, unless you specifically want to copy files with `rsync`. The
  web desktop needs only a browser.
- **A terminal.** Everything in Part 3 is done by clicking.

---

## A note on how long this takes

Be realistic about the first time through:

| | |
|---|---|
| Getting an allocation | Hours to a week (do this first) |
| Part 1 — server and volume | 20 minutes |
| Part 2 — preparing your project | 30 minutes for a simple app; an afternoon for an old or complicated one |
| Part 3 — publishing | 15 minutes of clicking, plus the build |
| **The build itself** | Streamlit/Dash/Python Shiny: **5–15 minutes**. R Shiny: **20–45 minutes** the first time, and longer for geospatial projects |

Subsequent publishes of the same project are much faster, because the slow
parts are cached.

---

Ready? → **[Part 1 · Set up your server](part1-instance/index.md)**
