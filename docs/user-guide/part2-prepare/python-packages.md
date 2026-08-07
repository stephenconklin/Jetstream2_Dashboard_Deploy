# Python: create a `requirements.txt`

<p class="meta-line">10 minutes. Dash, Python Shiny and Streamlit projects — R users go <a href="../r-packages/">here</a>.</p>

A `requirements.txt` lists every Python package your dashboard needs. The
server installs exactly what's in it and nothing else.

!!! danger "This one is required, not optional"

    Unlike R, there is no fallback. Without a `requirements.txt`, the
    deployment stops immediately with a message telling you to create one.

    The reason is that import names and package names often differ —
    `import cv2` comes from `opencv-python`, `import sklearn` from
    `scikit-learn`, `import yaml` from `PyYAML`. There's no reliable way to
    guess, and guessing wrong would install the wrong thing.

---

## The quick way

In the environment where your dashboard already works — the virtualenv, conda
env, or wherever you run it from:

```bash
pip freeze > requirements.txt
```

That's it. Confirm the file has content and that you recognise the names:

```bash
head requirements.txt
```

```console
dash==2.18.2
pandas==2.2.3
plotly==5.24.1
```

!!! warning "Run it in the *right* environment"

    If you run `pip freeze` in your system Python instead of your project's
    environment, you'll capture hundreds of unrelated packages. The build then
    takes far longer than it should and is much more likely to hit a conflict.

    Check you're in the right place first:

    ```bash
    which python      # macOS / Linux
    where python      # Windows
    ```

    It should point inside your project's environment, not `/usr/bin/python3`.

---

## If your environment is messy

`pip freeze` captures *everything installed*, including things you no longer
use. That's harmless but slow. Two tidier options:

=== "pipreqs (scans your code)"

    ```bash
    pip install pipreqs
    pipreqs /path/to/my-dashboard
    ```

    This reads your `import` statements and writes a much shorter
    `requirements.txt` with only what you actually import.

    **Check the result.** `pipreqs` guesses package names from import names,
    which is exactly the problem described above — it's usually right and
    occasionally wrong. Compare against `pip freeze` output for anything you
    don't recognise, and it does not catch packages imported dynamically or
    used only as a dependency of something else.

=== "A clean environment (most reliable)"

    Build a fresh environment, install only what your app needs until it runs,
    then freeze that:

    ```bash
    python -m venv fresh
    source fresh/bin/activate          # Windows: fresh\Scripts\activate

    pip install dash pandas plotly     # add until the app runs
    python app.py                      # test it

    pip freeze > requirements.txt
    deactivate
    ```

    Slower, but you end up certain the list is both complete and minimal.

=== "conda"

    A conda `environment.yml` is **not** read by the deployment. Export a pip
    list instead:

    ```bash
    conda activate my-env
    pip list --format=freeze > requirements.txt
    ```

    Note `pip list --format=freeze` rather than `pip freeze` — in a conda
    environment, `pip freeze` writes local file paths for conda-installed
    packages, producing a file that can't be installed anywhere else.

    Check the result for lines containing `file://` or `@` and remove them.

=== "uv"

    If you manage the project with [uv](https://docs.astral.sh/uv/) and have a
    `pyproject.toml` and `uv.lock`, **you don't have to do anything** — the
    deployment generates `requirements.txt` from your lockfile automatically.

    To do it yourself anyway:

    ```bash
    uv export --no-hashes --frozen -o requirements.txt
    ```

=== "Poetry"

    ```bash
    poetry export --without-hashes -f requirements.txt -o requirements.txt
    ```

    On Poetry 2.x this needs the export plugin:
    `poetry self add poetry-plugin-export`.

---

## Should versions be pinned?

`pip freeze` pins everything (`pandas==2.2.3`). **Keep it that way.** An
unpinned list means the server installs whatever is current on the day it
builds, and your dashboard can change behaviour or stop working without you
touching it.

The trade-off is that a pinned list eventually goes stale, which is the subject
of the next section.

---

## When an old project won't build

Very common with paper-companion repositories whose `requirements.txt` was
written years ago. Two failures usually appear together, and fixing the first
reveals the second.

??? failure "1. A pinned package won't compile"

    Symptom, partway through the build:

    ```
    pandas/_libs/tslibs/np_datetime.c:16:10:
    fatal error: longintrepr.h: No such file or directory
    ```

    What happened: `pandas==0.24.2` predates Python 3.11, which made that
    header private. No amount of fiddling with setuptools fixes it.

    **The fix is to use an older Python**, not to fight the compiler. Old
    packages have prebuilt wheels for the Python they were released against, so
    an older base image skips compiling entirely.

    In Part 3, on the **Publish** tab, open **Advanced** and set
    **Base image** to `python:3.7-slim` (or `3.8`, `3.9` — try the one your
    project was written for). See
    [Step 3 · Publish](../part3-deploy/step3-publish.md#advanced-options).

??? failure "2. Unpinned transitive dependencies have moved on"

    Symptom: the build **succeeds**, then the app dies at startup:

    ```
    ImportError: cannot import name 'get_current_traceback'
    from 'werkzeug.debug.tbtools'
    ```

    What happened: `dash==1.12.0` pins Dash but says nothing about Flask or
    Werkzeug, so pip installed today's versions of those — which are no longer
    compatible.

    **The fix is to pin what the original author relied on but never
    declared.** For a Dash app of that vintage, add to `requirements.txt`:

    ```
    werkzeug<2.1
    flask<2.2
    itsdangerous<2.1
    jinja2<3.1
    ```

!!! note "The honest trade-off"

    An end-of-life Python gets no security updates. Pointing at
    `python:3.7-slim` is a reasonable way to get an old dashboard running and
    evaluate it. It is not a good permanent home for something on the public
    internet.

    The durable fix is updating the pins — which for an old Dash app also means
    replacing `import dash_core_components as dcc` with
    `from dash import dcc`.

---

## Packages that need system libraries

Most Python packages install from prebuilt wheels and need nothing extra. A few
— usually geospatial or image-processing — need system libraries.

If a package fails to build with an error mentioning a missing `.h` file or a
missing library, add an `apt.txt` to your project with one Ubuntu package name
per line:

```
libgdal-dev
libgeos-dev
libproj-dev
```

Blank lines and `#` comments are ignored.

!!! tip "Try the wheel first"

    Before reaching for `apt.txt`, check whether a prebuilt version exists.
    `pip install geopandas` on a modern Python pulls in binary wheels for GDAL
    and friends and needs no system packages at all — whereas an old pinned
    version may not.

---

## What to upload

- [x] `requirements.txt` — **required**
- [x] `apt.txt` — only if you needed one
- [ ] `venv/` or `.venv/` — no; it's excluded automatically and wouldn't work anyway
- [ ] `environment.yml` — not read; export to `requirements.txt` instead

---

Next → **[How your app finds its data](data-paths.md)**
