# Create your instance

<p class="meta-line">About 10 minutes, of which 8 is the instance building itself.</p>

You'll create the server from a **prepared image** — a snapshot of an instance
that already has Docker, nginx, the deployment tooling and the **Deploy My
Dashboard** desktop application installed and tested. Starting from that image
is what turns this from a systems-administration exercise into a few clicks.

---

## 1. Start the Create Instance flow

In Exosphere, click **Create** (top right) → **Instance**.

You'll land on the image chooser.

---

## 2. Choose the Dashboard Deploy image

Look under **By Image** and search for the image name your group published.

!!! note "Ask your group for the exact image name"

    The Dashboard Deploy image is created and shared by your project, not by
    Jetstream2, so its name and visibility depend on how it was published. It
    is usually one of:

    - listed under **Public** if it was shared with everyone, or
    - listed under **Shared with me** / your project's own images, or
    - given to you as an **image ID** to paste into the search box.

    If you can't find it, ask whoever pointed you at this guide. Don't
    substitute a plain Ubuntu image — it won't have the desktop application on
    it, and Part 3 will not work.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p1-choose-image.png</span>
  </div>
  <figcaption>The image chooser with the Dashboard Deploy image selected. The
  search box and the Public / Shared-with-me tabs should both be visible.</figcaption>
</figure>

??? info "What's actually on this image"

    So you know what you're getting, and what to re-create if you ever have to
    build one yourself:

    - Ubuntu 22.04 with a graphical desktop and web-desktop access
    - Docker, plus a swapfile so a big build doesn't run out of memory
    - nginx, configured as a reverse proxy in front of your dashboard
    - The `autoheal` watchdog, which restarts your dashboard if it wedges
    - The deployment tooling, cloned to `~/Jetstream2_Dashboard_Deploy`
    - The **Deploy My Dashboard** desktop icon
    - The base images for all four frameworks, pre-downloaded — this alone
      saves 10 minutes on your first publish

    It is built by `deploy/desktop/setup_image.sh` in the repository. See
    [Building the researcher image](../reference/deployment.md#building-the-researcher-image).

---

## 3. Fill in the instance settings

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p1-create-instance-form.png</span>
  </div>
  <figcaption>The Create Instance form, with Name, Flavor, Enable web desktop
  and the disk-size slider visible.</figcaption>
</figure>

Work down the form:

**Name**
:   Something you'll recognise in six months. `salmon-dashboard`, not
    `instance-3`.

**Flavor** *(the size of the server)*
:   Start with **`m3.small`** (2 vCPU, 6 GB RAM). This is enough for almost
    every dashboard, and you can resize later.

    Choose **`m3.medium`** (8 vCPU, 30 GB RAM) up front if your dashboard is
    an R geospatial project, loads more than about 2 GB into memory at once, or
    you expect many people using it simultaneously. R Shiny builds in
    particular are much faster with more cores.

**Instance count**
:   Leave at **1**. One instance runs one dashboard.

**Enable web desktop**
:   :material-alert: **Turn this ON.** This is the setting that lets you reach
    the graphical desktop from your browser in Part 3. Without it you'd be
    limited to SSH, and the **Deploy My Dashboard** icon would be unreachable.

**Choose a root disk size**
:   The default that comes with your flavor is fine if your data is going on a
    volume, which it should be.

    Building a container image needs working space, and R geospatial images are
    large. If the slider lets you, **give it at least 60 GB** — the deployment
    tooling warns you below 15 GB free, and running out *during* a build
    produces a genuinely baffling error.

**SSH public key**
:   Optional. Add one if you already have a key and want to use `rsync` or
    `ssh` later. You can skip it entirely and still complete this guide.

**Advanced options**
:   Leave alone. In particular, do not change the network settings.

---

## 4. Create it, then wait

Click **Create**. Exosphere returns you to the instance list with your instance
in state **Building**.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p1-instance-building.png</span>
  </div>
  <figcaption>The instance list showing the new instance in the Building state,
  with its progress message.</figcaption>
</figure>

This takes **5–10 minutes**. The Dashboard Deploy image is large, so be patient
— a plain Ubuntu instance would be quicker. Exosphere shows what it's doing
underneath the status.

You're finished with this step when the instance shows **Ready** and has an
**IP address** listed.

!!! success "Write down the IP address"

    Something like `149.165.170.42`. This is your dashboard's permanent web
    address — `http://149.165.170.42/` — once you publish in Part 3. Put it
    somewhere you'll find it.

---

## 5. Confirm the web desktop works

Don't wait until Part 3 to discover this is off. Click your instance's name,
then look for **Web Desktop** in the actions.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p1-instance-ready.png</span>
  </div>
  <figcaption>The instance detail page in the Ready state, showing the IP
  address and the Web Desktop action.</figcaption>
</figure>

Clicking it opens a Linux desktop in a new browser tab. If you see one — with a
**Deploy My Dashboard** icon on it — Part 1's hardest step is behind you. Close
the tab for now; you'll come back to it in Part 3.

??? failure "Web Desktop isn't offered"

    You almost certainly left **Enable web desktop** off when creating the
    instance. It cannot be switched on afterwards from Exosphere.

    The quickest fix is to delete this instance and create a new one with the
    box ticked — you've lost nothing but the build time. See the
    [Jetstream2 web desktop documentation](https://docs.jetstream-cloud.org/ui/exo/webdesktop/)
    for the alternative.

---

## Common problems

??? failure "The instance is stuck in Building for more than 20 minutes"

    Check the status message beneath it. If it mentions quota, you've hit a
    limit on your allocation — Exosphere shows your quota usage on the
    allocation page. Delete any instances you're not using and try again.

    Otherwise, delete it and retry once. If it fails a second time, email
    [help@jetstream-cloud.org](mailto:help@jetstream-cloud.org) with the
    instance name and time.

??? failure "It says Ready but has no IP address"

    Give it another minute and refresh. If there's still no address, the
    floating-IP pool may be exhausted; see
    [Jetstream2's IP address documentation](https://docs.jetstream-cloud.org/ui/exo/instance_management/).

??? question "Can I resize the instance later?"

    Yes — Exosphere has a **Resize** action on the instance. It reboots the
    instance, and your dashboard comes back automatically afterwards. Resizing
    up is straightforward; resizing down is sometimes refused if the root disk
    doesn't fit the smaller flavor.

---

Next → **[Create a storage volume](create-volume.md)**
