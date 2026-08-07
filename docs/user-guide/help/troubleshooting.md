# When something goes wrong

Organised by **what you're seeing**, not by what's technically at fault — since
if you knew that, you wouldn't need this page.

!!! tip "Start here, whatever the problem"

    Open the application → **Manage** tab → read the **headline** and the
    **Details** panel, then press **Show latest** under *Recent output from
    your app*.

    Between them, those two things identify most problems in under a minute.
    And **Save a report to send for help** captures all of it in one file if
    you need to ask someone.

---

## My dashboard page won't load

The browser shows nothing, an error, or spins forever.

**First: check the address.** `http://` and not `https://` (unless you set up a
domain name), the right IP, no port number, no trailing path. `http://149.165.170.42/`.

Then open the Manage tab and match the headline:

??? failure "\"Nothing is published yet\""

    No dashboard exists on this instance. Either you haven't published, or you
    published on a *different* instance.

    Check the IP in Exosphere matches the one you're visiting.

??? failure "\"Your dashboard is stopped\""

    Somebody pressed **Stop**, or it was stopped from a terminal. It stays
    stopped until started, including through reboots.

    Press **Start**.

??? failure "\"The app isn't responding\""

    The container is running but your app inside it is silent. Nearly always
    your app crashed at startup.

    1. Press **Show latest** and read the bottom of the log
    2. Check **Restarts** in Details — climbing means a crash loop
    3. The usual causes, in order of frequency:
       - **A data file it can't find** →
         [data paths](../part2-prepare/data-paths.md)
       - **A missing package** → your package list is incomplete
       - **An error in the startup code** → the traceback names the line

??? failure "\"The web server isn't serving\" / \"can't reach the app\""

    Your app is fine; nginx in front of it isn't. See
    [nginx problems](#nginx-problems) below.

??? failure "The Manage tab says everything is fine, but I still can't load it"

    The dashboard is reachable *from the instance* but not from where you are.
    That's a network path problem, not a dashboard problem.

    - **Try from a different network** — phone on cellular data is the quickest
      test. Many campus and corporate networks block outbound traffic to
      unusual hosts.
    - **Check the security group** in Exosphere allows inbound `80/tcp`.
    - **Check you're using `http://`** — a browser that silently upgraded you
      to `https://` will fail if you haven't set up a certificate.

---

## My dashboard loads but shows an error

The page opens and shows a traceback, a red error box, or a broken plot.

**This is the normal outcome of a data-path problem**, and it's why the
application never claims your dashboard is "working" — only that it's live.
Shiny and Streamlit catch errors in your code and render them as a page.

### `cannot open file 'data/...': No such file or directory`

By far the most common. Your data isn't where your app is looking.

Work through these in order:

1. **Did you choose a data folder?** Manage tab → **Publish again** is not the
   fix; go to tab 2 and check a folder is selected.

2. **Is that folder actually empty?** Tab 2 → **Look in that folder now**. If
   it says empty, that's your answer — and note that an empty folder is
   attached *over* whatever your project shipped, hiding it.

3. **Are the files at the right level?** The **contents** of your chosen folder
   appear at `data/`. So:

    ```
    ✅ /media/volume/salmon-data/counts.csv      → data/counts.csv
    ❌ /media/volume/salmon-data/mydata/counts.csv → data/mydata/counts.csv
    ```

    The second is the classic `rsync` trailing-slash mistake. Either move the
    files up a level, or select the inner folder instead.

4. **Is your code using a relative path?** `read.csv("data/counts.csv")`, not
   an absolute path from your own machine. See
   [checking your paths](../part2-prepare/data-paths.md#checking-your-paths-before-you-upload).

### `there is no package called 'X'` (R), at run time

The build installed it, but the running app can't see it. Two causes:

- **You uploaded the `renv/` folder or `.Rprofile`.** The app tries to activate
  a renv project whose library doesn't exist there. Delete both from the
  project on the instance and publish again. See
  [what renv leaves behind](../part2-prepare/r-packages.md#what-renv-leaves-behind).
- **The package is loaded dynamically** and the static scan missed it. Add it
  explicitly to your `renv.lock`.

### `ModuleNotFoundError` (Python), at run time

The package isn't in your `requirements.txt`. Add it and publish again.

Check you generated the file in the environment where the app actually works —
a `pip freeze` in the wrong environment produces a plausible-looking file that's
missing the important entries.

---

## The build fails

**Read the last 20 lines of the Progress pane.** Everything above is normal
output; the reason is at the bottom, in the underlying tool's own words.

Every attempt leaves a full log in `~/dashboard-deploy-logs/`.

??? failure "`no space left on device`"

    The instance's disk filled up mid-build.

    1. Manage tab → **Storage** → **Free up space**
    2. Publish again

    If it happens repeatedly, the instance's root disk is too small for your
    project — R geospatial images are 8 GB or more before the build cache. Ask
    for a bigger root disk when creating the instance, or resize.

??? failure "`fatal error: <something>.h: No such file or directory`"

    A package is compiling from source and can't find a system library.

    **For Python**, this usually means the package is too old for the base
    image's Python. Set **Base image** to an older Python on tab 3 →
    [Advanced](../part3-deploy/step3-publish.md#advanced-options).

    **For R**, or if the header is clearly a library name (`gdal.h`, `proj.h`,
    `udunits2.h`), add an `apt.txt` to your project naming the Ubuntu package:

    ```
    libgdal-dev
    libudunits2-dev
    ```

??? failure "`configure: error: ... GDAL ... PROJ ... GEOS ...`"

    Geospatial version drift: CRAN shipped a version of `sf`/`terra` needing
    newer system libraries than the image has. Your code didn't change; CRAN
    did.

    - If you have **no `renv.lock`**, create one — see
      [R packages](../part2-prepare/r-packages.md). `terra` specifically is
      pinned automatically for the known case.
    - If you **do** have one that pins a too-new version, pin an older one by
      hand:
      [Pinning R package versions](../reference/deployment.md#pinning-r-package-versions-to-avoid-cran-version-drift).

??? failure "`ERROR: Could not find a version that satisfies the requirement`"

    A pinned Python package has no release for this Python version.

    Set **Base image** to the Python your project was written for — try
    `python:3.9-slim`, then `3.8`, then `3.7`.

??? failure "`ImportError: cannot import name '...' from '...'`"

    The build succeeded and the app died at startup. An unpinned transitive
    dependency has moved on — classically Werkzeug under an old Dash.

    Pin the underlying packages explicitly. See
    [when an old project won't build](../part2-prepare/python-packages.md#when-an-old-project-wont-build).

??? failure "It hangs for a long time with no output"

    Usually normal. R package compilation produces long silences, and a
    geospatial build can sit apparently idle for many minutes.

    Genuine hangs are rare. Give it 20 minutes past the last output before
    concluding anything, then press **Stop** and read the log.

??? failure "apt errors, connection timeouts, `Connection failed`"

    A network hiccup. The tooling retries automatically, so if you're seeing
    this as a final failure, retries were exhausted.

    Simply publishing again is usually enough. If it fails every time in the
    same place, the instance may be blocking outbound traffic; report it to
    [help@jetstream-cloud.org](mailto:help@jetstream-cloud.org).

---

## My dashboard was working and now isn't

??? failure "After a reboot"

    **The volume didn't remount.** By far the most likely cause. Your dashboard
    restarted, found an empty data folder, and failed.

    1. Check the volume in Exosphere is **In use**
    2. Application → tab 2 → is the volume in the list with its free space?
    3. If a **Make this permanent** button is offered, press it — that's the
       fix that stops this recurring. See
       [Make it survive a reboot](../part3-deploy/step2-your-data.md#make-it-survive-a-reboot)
    4. Manage tab → **Restart**

??? failure "It got slow, or stopped responding"

    1. Manage tab → **Memory** in Details. If it's near the instance's limit,
       your dashboard is running out of RAM.
    2. **Restart** clears it temporarily.
    3. If it recurs, either resize the instance up in Exosphere, or reduce what
       your dashboard loads into memory at once.

    A container killed for using too much memory shows `Killed` in the log,
    with no traceback.

??? failure "Restarts keeps climbing"

    A crash loop: your app starts, fails, is restarted, repeats.

    Press **Show latest** — you'll see the same error over and over. That error
    is the whole problem. Fix it and publish again.

    Pressing **Stop** breaks the loop while you investigate.

??? failure "Nothing changed and it broke anyway"

    Something outside your project moved. The usual suspects:

    - The instance rebooted and the volume didn't remount (see above)
    - The disk filled up
    - You republished, and CRAN or PyPI shipped a new version in the meantime —
      which is what lockfiles prevent

---

## nginx problems

nginx is the web server sitting in front of your dashboard, handling port 80.
When the Manage tab distinguishes a *web server* problem from an *app* problem,
this is what it means.

These need a terminal.

??? failure "\"The web server isn't serving\""

    ```bash
    sudo systemctl status nginx
    sudo nginx -t                  # check the config is valid
    sudo systemctl restart nginx
    ```

    If `nginx -t` reports an error, re-run the provisioning to regenerate the
    configuration from its template:

    ```bash
    cd ~/Jetstream2_Dashboard_Deploy
    sudo ./deploy/bootstrap.sh
    ```

??? failure "\"The web server can't reach the app\""

    Both are running but not talking. Usually the app is still starting up —
    wait a minute and press **Refresh**.

    If it persists:

    ```bash
    cd ~/Jetstream2_Dashboard_Deploy
    ./deploy/manage.sh health
    sudo tail -50 /var/log/nginx/dashboard.error.log
    ```

??? warning "Never edit the nginx config directly"

    `/etc/nginx/sites-available/dashboard` is regenerated from a template every
    time provisioning runs, so edits there are silently lost.

    Change `deploy/deploy.env` and re-run `sudo ./deploy/bootstrap.sh` instead.

---

## Application problems

??? failure "The desktop icon does nothing"

    Try the applications menu → **Deploy My Dashboard** instead.

    If that also does nothing, launch it from a terminal so you can see the
    error:

    ```bash
    ~/Jetstream2_Dashboard_Deploy/deploy/gui/launch_gui.sh
    ```

    A `ModuleNotFoundError: No module named 'tkinter'` means the graphical
    toolkit is missing — which shouldn't happen on the prepared image, and
    suggests you're on a plain Ubuntu image instead. Fix:

    ```bash
    sudo apt-get install -y python3-tk
    ```

??? failure "The window opened but tabs 1–3 are blank while a dashboard is running"

    Expected if the dashboard was published before the application learned to
    record where it came from. Publish once more and it will restore correctly
    from then on.

??? failure "\"Your dashboard is running, but the folder it was published from is no longer there\""

    You deleted or moved the project folder. **Your dashboard is unaffected** —
    its code was copied into the image when you published.

    To publish again, point tab 1 at the code's new location, or download it
    again.

??? failure "A build seems stuck and Stop doesn't respond"

    Give it 30 seconds — it asks the build to stop cleanly first.

    Builds run independently of the application, so closing the window does not
    stop a build. To be certain nothing is running:

    ```bash
    docker ps
    ```

---

## Instance and volume problems

For anything about the instance itself — it won't start, it has no IP, you're
over quota, a volume won't attach — the Jetstream2 team are the right people:

- [docs.jetstream-cloud.org](https://docs.jetstream-cloud.org/)
- [help@jetstream-cloud.org](mailto:help@jetstream-cloud.org)

Common ones are covered in [Part 1](../part1-instance/create-instance.md#common-problems).

---

## Asking for help

Do this before you write the email:

1. Manage tab → **Save a report to send for help**
2. Note the file path it gives you (in `~/dashboard-deploy-logs/`)
3. If a **build** failed, also grab the newest `deploy-*.log` from that folder

Then include:

- **What you expected and what happened instead**
- **What you'd changed** since it last worked, if it ever did
- **The framework** — R Shiny, Dash, Python Shiny, Streamlit
- **The report file**, attached

The report contains the health verdict, disk figures, what's running, the
nginx configuration and error log, and your app's own output — which is most of
what anyone would ask you for.
