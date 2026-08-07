# Step 2 · Your data

<p class="meta-line">10 minutes of clicking, plus however long your upload takes. Tab 2 of the application.</p>

This tab does three things, top to bottom:

1. **Where your data will live** — pick the folder on the server
2. **How to get your data here** — four ways to upload it
3. **Check what's arrived** — confirm it actually worked

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab2-full.png</span>
  </div>
  <figcaption>Tab 2 in full, showing all three sections: the location list, the
  transfer routes, and the check panel.</figcaption>
</figure>

!!! tip "Do the upload first, then pick the folder"

    The order that avoids the most rework: pick your volume, upload your data
    into it, then confirm with the check button before moving on. A folder
    that's empty when you publish causes a failure that costs you a whole
    build.

---

## 1. Where your data will live

At the top is a list of every place data could go on this instance, best first.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab2-locations.png</span>
  </div>
  <figcaption>The "Where your data will live" list showing an attached volume
  with its free space, and the home folder below it.</figcaption>
</figure>

You'll see entries like:

```
/media/volume/salmon-data — storage volume (93.2 GB free of 98.4 GB)
/home/exouser — home folder on the system disk (41.0 GB free) —
    limited space, lost if the instance is deleted
```

**Your attached volume is preselected**, because it's nearly always the right
answer. If you have exactly one volume, there's usually nothing to do here.

Other things you may see:

| Entry | What it means | What to do |
|---|---|---|
| `— storage volume (… free)` | Attached and mounted, ready | Use it |
| `— home folder on the system disk` | The instance's own disk | Only for quick tests |
| `— attached but not mounted` | Volume is plugged in but has no path yet | Mount it in Exosphere, then press **Refresh** |
| `— attached but not formatted` | Brand-new blank disk | Format it in Exosphere, then press **Refresh** |

**Refresh** re-reads the list — press it after changing anything in Exosphere.
**Choose another folder…** lets you pick any folder on the instance, for the
unusual cases.

!!! warning "The home folder is not a home for data"

    It's on the instance's root disk: limited space, shared with Docker's build
    cache, and gone if the instance is ever rebuilt. It's deliberately listed
    last and never preselected. Fine for trying things out; wrong for a real
    dataset.

### Read the mapping line

Underneath the list, in fixed-width text, is the single most important line on
this tab:

```
/media/volume/salmon-data  →  /srv/shiny-server/data   (inside your app)
```

That is exactly what
[How your app finds its data](../part2-prepare/data-paths.md) described. The
**contents** of the folder on the left appear at the path on the right. Your
code reads `data/counts.csv`, so `counts.csv` needs to be directly inside
`/media/volume/salmon-data`.

If the folder on the left is right and your code uses `data/`-relative paths,
you're done thinking about paths.

---

## 2. How to get your data here

Four routes, because researchers arrive with very different setups. Pick one.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab2-routes.png</span>
  </div>
  <figcaption>The "How to get your data here" section with the four route
  options and the detail panel for the selected one.</figcaption>
</figure>

Selecting a route shows what it's best for, and either a button that opens the
right tool or a command already filled in with your instance's details.

=== "Globus — large datasets"

    **The right answer for tens of GB and up**, or anything you'd hate to
    restart. Globus transfers in the background, retries automatically, resumes
    after interruptions, and is supported natively by Jetstream2. Nothing to
    install.

    1. Click **Open Globus** — it opens in the desktop's browser
    2. Log in with your institution's credentials
    3. Set your source (your institution's storage, or Globus Connect Personal
       on your own machine) and this instance as the destination
    4. Start the transfer and close the browser — it keeps going and emails you
       when it's done

    If your institution has no endpoint,
    [Globus Connect Personal](https://www.globus.org/globus-connect-personal)
    turns your own laptop into one.

=== "Cloud storage"

    If your data is already in **Google Drive, Box or Dropbox**, the quickest
    path is to open it in *this desktop's* browser and download straight to the
    instance. The files never pass through your laptop, so you're limited by
    the instance's connection rather than your home broadband.

    1. Click **Google Drive** / **Box** / **Dropbox**
    2. Log in and download
    3. Move the files onto your volume — **Open that folder** opens the
       destination in the file manager, so you can drag them across

    Downloads land in `~/Downloads` by default, which is on the instance's root
    disk. Don't leave them there.

=== "rsync / scp — from your own computer"

    For a folder on your laptop, when you're comfortable with a terminal. The
    application shows the exact command with your instance's IP and destination
    already filled in:

    ```bash
    rsync -avP ~/mydata/ exouser@149.165.170.42:/media/volume/salmon-data/
    ```

    **Run this on your own computer, not in the web desktop.** Select the text
    in the box and copy it across.

    !!! warning "The trailing slash matters"

        `~/mydata/` copies the **contents** into the destination.
        `~/mydata` (no slash) creates a `mydata` folder inside it — so your
        files end up at `data/mydata/counts.csv` instead of `data/counts.csv`,
        and your app can't find them.

        This trips up nearly everyone once. The command in the box has the
        slash; keep it.

    `-P` makes an interrupted transfer resumable, which matters over a home
    connection.

    Prefer clicking? **Cyberduck** (macOS/Windows), **WinSCP** (Windows) and
    **FileZilla** (all platforms) all speak SFTP — connect to your instance IP
    as `exouser` with your SSH key, then drag files across.

=== "Drag and drop"

    Drag files onto the remote desktop session and they arrive in your **home
    folder**. Simplest option, no setup.

    **Slow and unreliable above about a gigabyte** — use one of the routes
    above for anything substantial. And remember they land in home, not on your
    volume, so move them across afterwards. **Open that folder** opens the home
    folder for you.

---

## 3. Check what's arrived { #check-what-s-arrived }

Press **Look in that folder now**. This is the point of the whole tab: every
route above is just instructions, and this is what tells you whether they
worked.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab2-verify.png</span>
  </div>
  <figcaption>The "Check what's arrived" panel showing a successful listing:
  file count, total size, and the first few filenames.</figcaption>
</figure>

```
1,284 files, 12.4 GB in /media/volume/salmon-data:
    counts.csv
    sites.geojson
    rasters/ndvi_2021.tif
    rasters/ndvi_2022.tif
    …and 1280 more
```

Check three things:

1. **The file count and size** look like what you sent
2. **The names are what your code expects** — `counts.csv`, not
   `mydata/counts.csv` (that's the trailing-slash mistake)
3. **The path at the top** matches the folder you selected

If it says `is empty — nothing has arrived yet`, stop here. Publishing now
would waste a build. See [the empty-folder
mistake](../part2-prepare/data-paths.md#the-empty-folder-mistake).

---

## Make it survive a reboot

If your data is on a volume that isn't set to remount automatically, a panel
appears here:

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab2-persist.png</span>
  </div>
  <figcaption>The reboot-persistence panel with its warning text and the
  "Make this permanent" button.</figcaption>
</figure>

> This volume is mounted now, but will **NOT** reconnect by itself after the
> instance reboots — your dashboard would restart with no data. This is worth
> fixing once.

**Click "Make this permanent".** It takes seconds and you only ever do it once
per volume.

You'll be shown the exact system change first, then asked for an administrator
password through the system's own dialog:

```
UUID=8f3c...  /media/volume/salmon-data  ext4  defaults,nofail,x-systemd.device-timeout=10s  0  2
```

??? info "What that line does, and why it's safe"

    It adds one entry to `/etc/fstab`, the file that tells Linux which disks to
    mount at boot.

    A badly-formed `/etc/fstab` can prevent a machine booting at all, which on
    a cloud instance means being locked out. So the tooling is careful:

    - **`nofail`** means that if the volume is ever detached, the instance
      still boots normally rather than dropping to an emergency console you
      can't reach.
    - **`x-systemd.device-timeout=10s`** stops the boot waiting 90 seconds for
      a missing disk.
    - The existing file is **backed up first**, the result is **validated**,
      and if validation fails the backup is **restored automatically**.
    - Running it twice can't create a duplicate entry.

    The full reasoning is in
    [Reboot persistence](../reference/deployment.md#reboot-persistence).

If the panel says the volume is **already set to reconnect automatically**,
there's nothing to do.

!!! note "The only test that counts is a reboot"

    Once you've published, it's worth rebooting the instance from Exosphere
    once and confirming the dashboard comes back with its data. Better to find
    out deliberately than during a power event six months from now.

---

## If your project has no `data/` folder

You'll see a slightly different message at the top of this tab:

> This project doesn't include a `data/` folder of its own. If your dashboard
> reads data files that live somewhere else on this server — a storage volume,
> typically — choose that folder below and it will appear inside your app at
> `/app/data`. If your dashboard doesn't read any data files, skip to step 3.

**Read this carefully — it's not "skip this tab".** If you followed Part 2's
advice and moved your data onto the volume, your project has no `data/` folder
*precisely because you did the right thing*, and you still need to choose your
volume here.

Only skip if your dashboard genuinely reads no data files at all — everything
is computed, or fetched from an API at run time.

---

Next → **[Step 3 · Publish](step3-publish.md)**
