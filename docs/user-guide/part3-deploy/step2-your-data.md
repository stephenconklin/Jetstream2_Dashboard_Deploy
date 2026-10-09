# Step 2 · Your data

<p class="meta-line">10 minutes of clicking, plus however long your upload takes. Tab 2 of the application.</p>

Your dashboard can only read files it can see on the server. This tab asks
one question — **where are your dashboard's data files?** — and offers two
answers:

<figure class="shot">
  <img src="../../assets/screenshots/p3-tab2-question.png"
       alt="Tab 2's 'Where are your dashboard's data files?' question, with 'In my app folder' selected and the size summary beneath it.">
  <figcaption>Tab 2's "Where are your dashboard's data files?" question, with
  "In my app folder" selected and the size summary beneath it.</figcaption>
</figure>

| Answer | Choose it when | What happens |
|---|---|---|
| **In my app folder, with the code** | Your data sits next to your code, or in a folder inside it, and adds up to less than about a gigabyte | Published along with the app. Your code keeps reading files exactly as it does on your computer |
| **In a separate folder on this server** | Your data is large, changes often, or already lives on a storage volume | Attached to the app when it runs. Update it any time without re-publishing |

The application picks the first answer for you, unless your app folder is
over about a gigabyte, or your code reads from a `data/` folder that your
project doesn't have (so the data must be somewhere else). If your dashboard
reads no data files at all, leave it as it is and go on to step 3.

---

## Option 1 · In my app folder

**Nothing to do.** This is how most dashboards arrive: a `.csv`, a
spreadsheet or a shapefile sitting right next to the code, read by its name:

```r
stations <- read.csv("stations.csv")
sheds    <- sf::st_read("watersheds.shp")
```

Everything in your app folder is published with your dashboard, so those
lines work unchanged. The tab shows the total size, for example:

> Everything in your app folder is published with your dashboard — 3.5 MB in
> all. Your code can keep reading its files exactly as it does on your own
> computer.

Two things to know:

- **When a data file changes, publish again** (step 3) to update it. The
  published copy doesn't follow your folder by itself.
- **Keep it under about a gigabyte.** Every publish copies the whole folder
  again, so large data makes every publish slow and fills the disk. Above
  that size the tab shows a warning: move the data into one folder on a
  storage volume and use Option 2 instead.

This tool deliberately doesn't try to publish datasets of many gigabytes
inside the app. Big data belongs on a storage volume.

---

## Option 2 · In a separate folder on this server

The rest of this page is about this option: data on a storage volume,
attached to your dashboard when it runs. It has four parts, top to bottom:

1. **What your code calls that folder**
2. **Where your data lives on this server**: pick the folder
3. **How to get your data here**: three ways to upload it
4. **Check what's arrived**: confirm it actually worked

<figure class="shot">
  <img src="../../assets/screenshots/p3-tab2-full.png"
       alt="Tab 2 with 'In a separate folder' selected, showing the folder name, the location list, the transfer routes, and the check panel.">
  <figcaption>Tab 2 with "In a separate folder" selected, showing the folder
  name, the location list, the transfer routes, and the check panel.</figcaption>
</figure>

!!! tip "Do the upload first, then pick the folder"

    The order that avoids the most rework: pick your volume, upload your data
    into it, then confirm with the check button before moving on. A folder
    that's empty when you publish causes a failure that costs you a whole
    build.

### What your code calls that folder

Your data folder appears **inside** your app under a name, and that name has
to be the one your code uses. If your code says
`read.csv("data/counts.csv")`, the name is `data`, which is the default. If it
says `read.csv("Inputs/counts.csv")`, type `Inputs` and press Enter.

The name is all that matters. The folder on the server can be called
anything.

### Where your data lives on this server

At the top is a list of every place data could go on this instance, best first.

<figure class="shot">
  <img src="../../assets/screenshots/p3-tab2-locations.png"
       alt="The 'Where your data lives on this server' list showing an attached volume with its free space, and the home folder below it.">
  <figcaption>The "Where your data lives on this server" list showing an attached volume
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

#### Read the mapping line

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

### How to get your data here

Three routes, because researchers arrive with very different setups. Pick one.

<figure class="shot">
  <img src="../../assets/screenshots/p3-tab2-routes.png"
       alt="The 'How to get your data here' section with the three route options and the detail panel for the selected one.">
  <figcaption>The "How to get your data here" section with the three route
  options and the detail panel for the selected one.</figcaption>
</figure>

Selecting a route shows what it's best for, and either a button that opens the
right tool or a command already filled in with your instance's details.

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

    **The right route for larger data** on your laptop, when you're
    comfortable with a terminal — it resumes after an interruption. The
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

### Check what's arrived { #check-what-s-arrived }

Press **Look in that folder now**. This is the point of the whole tab: every
route above is just instructions, and this is what tells you whether they
worked.

<figure class="shot">
  <img src="../../assets/screenshots/p3-tab2-verify.png"
       alt="The 'Check what's arrived' panel showing a successful listing: file count, total size, and the first few filenames.">
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

## Moved your data onto a volume? Use Option 2

If you followed Part 2's advice and moved your data out of your project onto
a storage volume, your app folder no longer holds it, so Option 1 has
nothing to publish. Choose **In a separate folder on this server** and pick
your volume, or your dashboard will start with no data.

The application usually spots this for you: when your code reads files from
`data/` and your project has no `data/` folder, it starts on the second
option, and warns you (⚠) if you switch back to the first.

---

Next → **[Step 3 · Publish](step3-publish.md)**
