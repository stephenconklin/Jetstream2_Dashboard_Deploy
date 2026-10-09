# How your app finds its data

<p class="meta-line">15 minutes. This is the single most common cause of a dashboard that publishes successfully and then shows nothing but errors.</p>

Your data reaches your dashboard in one of two ways:

- **Published with the app.** Data files in your project folder, whether next
  to your code or in a folder inside it, are copied in with the code. Nothing
  to set up, and your code reads them exactly as it does on your computer.
  Right for small data, up to about a gigabyte.
- **Attached from a storage volume.** The data stays on the volume and is
  **attached** to your running dashboard at a fixed location. Right for large
  data, or data you update often, since updating it needs no re-publish.

Either way, get the path right and everything works. Get it wrong and the
build succeeds, followed by a page full of "file not found". Most of this page
is about the second way, which is the one with paths to get right.

---

## The one picture that explains attaching

```
ON THE SERVER                             INSIDE YOUR RUNNING DASHBOARD

/media/volume/salmon-data/  ──────────→   /srv/shiny-server/data/     (R Shiny)
   ├── counts.csv                or  ──→   /app/data/                  (Python)
   ├── sites.geojson
   └── rasters/                            ├── counts.csv
       └── ndvi.tif                        ├── sites.geojson
                                           └── rasters/
   ↑                                           └── ndvi.tif
   you choose this folder
   in Part 3, step 2                       ↑
                                           your code reads from here
```

**The contents of the folder you choose appear at a fixed path inside your
app.** Not the folder itself — its contents. Choose
`/media/volume/salmon-data` containing `counts.csv`, and your app sees
`data/counts.csv`.

| Your framework | Your data appears at |
|---|---|
| R Shiny | `/srv/shiny-server/data/` |
| Plotly Dash | `/app/data/` |
| Python Shiny | `/app/data/` |
| Streamlit | `/app/data/` |

You never type those paths. What matters is that they're where the relative
path `data/…` points from your app's working directory — so **`data/counts.csv`
is the path that works in every framework.**

!!! tip "Your code uses a different folder name?"

    If your code reads `Data/counts.csv` or `inputs/counts.csv`, there's no
    need to change it. Type that folder name (`Data`, `inputs`) under **What
    your code calls that folder** in Part 3, step 2, and the attachment
    appears under that name instead. On the command line it's
    `DATA_SUBDIR=inputs`.

---

## What your code should look like

=== "R Shiny"

    Use a path **relative to your project root**, starting with `data/`:

    ```r
    # ✅ Works
    counts <- read.csv("data/counts.csv")
    sites  <- sf::st_read("data/sites.geojson")
    ndvi   <- terra::rast("data/rasters/ndvi.tif")
    ```

    Shiny Server runs your app with the project root as its working directory,
    and the data is attached at `data/` inside it. So the same path works on
    your laptop and on the server, with no changes.

    ```r
    # ❌ Won't work — absolute path from your own machine
    counts <- read.csv("/Users/jane/Documents/salmon/counts.csv")

    # ❌ Won't work — points outside the project
    counts <- read.csv("../shared-data/counts.csv")

    # ❌ Fragile — setwd() in a Shiny app is unreliable
    setwd("~/salmon"); counts <- read.csv("counts.csv")
    ```

    !!! tip "Using `here::here()`?"

        `here::here("data", "counts.csv")` works, because `here` resolves
        against the project root. It's a good habit generally.

=== "Plotly Dash / Python Shiny / Streamlit"

    You have two options. **Both work** — pick either.

    **Option A — relative path (simplest, matches R):**

    ```python
    # ✅ Works
    import pandas as pd
    counts = pd.read_csv("data/counts.csv")
    ```

    **Option B — the `DATA_DIR` environment variable (more portable):**

    The deployment sets an environment variable called `DATA_DIR` inside your
    container pointing at exactly the same place. Reading it means your code
    doesn't hardcode any path convention:

    ```python
    # ✅ Works, and adapts if the location ever changes
    import os
    import pandas as pd

    DATA = os.environ.get("DATA_DIR", "data")   # falls back to data/ locally
    counts = pd.read_csv(os.path.join(DATA, "counts.csv"))
    ```

    The `.get(..., "data")` fallback is what keeps it working on your laptop,
    where `DATA_DIR` isn't set.

    ```python
    # ❌ Won't work — absolute path from your own machine
    counts = pd.read_csv("/Users/jane/Documents/salmon/counts.csv")

    # ❌ Won't work — points outside the project
    counts = pd.read_csv("../shared-data/counts.csv")
    ```

---

## If your app already uses its own variable

Plenty of projects have their own convention — `VI_DATACUBE_ROOT`,
`PROJECT_DATA`, a `config.yaml` entry. You don't have to rewrite all of it. Add
one line at the top of your entry file to bridge:

=== "Python"

    ```python
    import os
    # Bridge: use the deployment's DATA_DIR if this app's own variable isn't set
    os.environ.setdefault("VI_DATACUBE_ROOT", os.environ.get("DATA_DIR", "data"))
    ```

    Put this **before** any import that reads the variable.

=== "R"

    ```r
    # Bridge: point this app's own option at the mounted data folder
    if (Sys.getenv("MY_DATA_ROOT") == "") {
      Sys.setenv(MY_DATA_ROOT = "data")
    }
    ```

---

## Three arrangements, all fine

### A. Data files next to your code

```
my-dashboard/
├── water_quality.R
├── stations.csv
└── watersheds.shp   (+ .dbf, .prj, .shx …)
```

```r
stations <- read.csv("stations.csv")
```

The most common arrangement, and it **just works**: choose *In my app folder*
in Part 3, step 2 (it's the default), and everything is published with the
app. Change a file, publish again.

Keep it small. Every publish copies the whole folder, and above about a
gigabyte the application warns you to use arrangement C instead.

### B. A `data/` folder inside your project

```
my-dashboard/
├── app.R
├── renv.lock
└── data/
    └── counts.csv
```

You can go either way in Part 3, step 2:

- **In my app folder:** `data/` is published with the app, like arrangement A.
- **In a separate folder on this server:** you choose a folder on your volume,
  and it's attached *over the top of* the `data/` folder you shipped. The
  files in your project's `data/` are left out of the published copy. This is
  why the empty-folder warning below matters.

### C. Data on the volume, not in the project

```
my-dashboard/                        /media/volume/salmon-data/
├── app.R                            ├── counts.csv
└── renv.lock                        └── rasters/
   (no data/ folder)
```

**This is the recommended arrangement for anything large.** Your project stays
small and Git-friendly; your data lives where it belongs.

Your code is unchanged — it still says `read.csv("data/counts.csv")` — because
the `data/` path is supplied by the attachment rather than by a folder you
shipped.

!!! warning "The trap in arrangement C"

    A project with no `data/` folder *looks* like it doesn't need a data
    location. But it does — you just moved the data out, which is exactly the
    right thing to have done.

    **Choose *In a separate folder on this server* in Part 3, step 2, and pick
    your volume folder.** If you don't, your dashboard starts, finds no
    `data/` directory, and fails. The application catches the common case:
    when your code reads `data/…` paths and the folder isn't there, step 2
    starts on that option and warns you if you switch away from it.

---

## :material-alert-octagon: The empty-folder mistake

The most expensive mistake on this page, because you lose a whole build to it.

If you point the deployment at a folder that is **empty** — a volume you
haven't uploaded to yet, or the wrong volume — that empty folder is attached
over your app's `data/` directory. Your app then sees an empty `data/`, even if
your project shipped files there.

The application warns you about this before building. **Read the warning.**

The order that avoids it entirely:

1. Create and attach the volume *(Part 1 — done)*
2. **Upload your data to it** *(Part 3, step 2)*
3. Point the deployment at it
4. Publish

---

## Checking your paths before you upload

The application does this check for you the moment you select your project,
and lists anything it finds under **Worth checking in your code** on tab 1:
paths on your own computer, `setwd()`, file names whose capital letters don't
match, files your code reads that aren't in the folder. To check before you
upload, search your project for absolute paths. From your project folder:

=== "macOS / Linux"

    ```bash
    grep -rnE '"(/Users|/home|[A-Z]:\\\\)' --include='*.R' --include='*.Rmd' --include='*.py' .
    ```

=== "Windows PowerShell"

    ```powershell
    Get-ChildItem -Recurse -Include *.R,*.Rmd,*.py |
      Select-String -Pattern '"(/Users|/home|[A-Z]:\\)'
    ```

Anything this finds is a path that won't exist on the server. Every hit needs
converting to a relative path: just the file name for a file in your project
folder, or `data/…` for attached data.

Also worth checking for:

- `setwd(` in R — should not appear in a Shiny app at all
- `os.chdir(` in Python — same
- `../` in any data path — the attachment point has no parent you can reach

---

## Data you write, not just read

If your dashboard *writes* files — caching results, saving user uploads,
exporting figures — attach a data folder from your volume (arrangement B or C)
and write them under `data/`. That folder is attached read-write, and anything
written there lands on the volume and survives restarts and rebuilds.

Anything written **elsewhere** inside the container is lost when the dashboard
is republished, and possibly sooner. That includes data published with the
app (arrangement A, or B with *In my app folder*): it's a copy, and the next
publish replaces it.

```python
# ✅ Survives
out = os.path.join(os.environ.get("DATA_DIR", "data"), "cache", "results.parquet")

# ❌ Lost on the next restart
out = "/tmp/results.parquet"
```

---

## Updating your data later

**Attached data** (on a volume) doesn't need a rebuild to update. Replace the
files on the volume, then press **Restart** on the application's Manage tab.
Seconds, not minutes. That's the main practical payoff of attaching it.

**Data published with the app** is updated by publishing again (Part 3,
step 3). Simple, but it's a full publish each time, which is why large or
frequently changing data is better attached.

---

Next → **[Final checks before you upload](before-you-upload.md)**
