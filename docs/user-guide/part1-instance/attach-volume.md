# Attach the volume to your instance

<p class="meta-line">About 3 minutes.</p>

Attaching plugs the volume into the instance and gives it a path in the
instance's filesystem — a folder you can put files into. Exosphere does the
formatting and mounting for you.

---

## 1. Attach it

From the **volume's** page in Exosphere, click **Attach**, then choose your
instance. (You can also start from the instance's page and attach from there —
same result.)

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p1-attach-volume.png</span>
  </div>
  <figcaption>The Attach Volume dialog with the target instance selected.</figcaption>
</figure>

The instance must be **Ready** — you can't attach to one that's still building.

---

## 2. Let Exosphere format and mount it

A brand-new volume is a blank disk with no filesystem, the way a new external
drive is before you format it. Exosphere handles this: it will offer to format
and mount the volume, and you should let it.

Accept the default filesystem (**ext4**) and the default mount point unless you
have a specific reason not to.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p1-format-mount.png</span>
  </div>
  <figcaption>Exosphere's format-and-mount prompt for a newly attached volume.</figcaption>
</figure>

!!! danger "Never format a volume that already has data on it"

    Formatting erases everything. Exosphere only offers to format a volume it
    believes is blank, but if you're reattaching an existing volume and are
    offered a format, **stop** and check you have the right volume.

---

## 3. Note the path

Once mounted, the volume appears on the instance at:

```
/media/volume/<your-volume-name>
```

So a volume named `salmon-data` is at `/media/volume/salmon-data`. Exosphere
shows the exact path on the volume's page.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p1-volume-attached.png</span>
  </div>
  <figcaption>The volume page after attaching, showing state <strong>In use</strong>
  and the mount point under <code>/media/volume/</code>.</figcaption>
</figure>

**Write this path down.** In Part 3 you'll point the deployment application at
it, and everything under it becomes visible to your dashboard.

---

## 4. Confirm it from the instance

Worth 60 seconds now, because a volume that looks attached in Exosphere but
isn't actually mounted causes a confusing failure much later.

Open the **Web Desktop** from your instance's page, launch **Terminal** from
the applications menu, and run:

```bash
df -h /media/volume/*
```

You should see a line for your volume with its full size and almost all of it
free:

```console
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb        98G   24K   93G   1% /media/volume/salmon-data
```

If instead you get `No such file or directory`, the volume isn't mounted. Go
back to the volume page in Exosphere and check its state is **In use**.

!!! tip "You don't have to use the terminal for this"

    Part 3's **Deploy My Dashboard** application lists your attached volumes,
    with their free space, on its **Your data** tab. If you'd rather not touch
    a terminal at all, skip this check — you'll see the same information there,
    and a missing volume will be obvious because it won't be in the list.

---

## Make the mount survive a reboot

This is the one detail in Part 1 that will bite you months later if you skip it.

A volume mounted this way is mounted *now*, but the instance does not
necessarily remember to remount it when it reboots. If that happens, your
dashboard restarts, finds an empty folder where its data should be, and either
shows errors or shows nothing — with no obvious clue why.

**You don't have to fix this now.** The **Deploy My Dashboard** application
detects the situation and offers a one-click fix on its **Your data** tab,
with the exact system change shown to you first. See
[Step 2 · Your data](../part3-deploy/step2-your-data.md#make-it-survive-a-reboot).

Just remember that it's a thing, so that when the application offers, you say
yes.

---

## Common problems

??? failure "Attach fails, or the volume stays in state Attaching"

    Refresh the page — Exosphere sometimes lags behind the actual state. If
    it's still stuck after a few minutes, detach and reattach.

    A volume that's already attached to a *different* instance can't be
    attached to this one. Check the volume list for what it's connected to.

??? failure "`df` shows the volume but with 0% free, or a size far smaller than I asked for"

    You're probably looking at the wrong device — the instance's own root disk
    also appears in `df` output. Match the path under **Mounted on** to
    `/media/volume/<your-volume-name>` exactly.

??? question "Can I attach more than one volume?"

    Yes, and each gets its own folder under `/media/volume/`. The deployment
    application can only point your dashboard at **one** of them, though, so
    keep everything your dashboard reads under a single volume.

---

## :material-check-all: Part 1 complete

You now have:

- [x] An instance, **Ready**, with a note of its **IP address**
- [x] Web Desktop confirmed working
- [x] A volume, **In use**, with a note of its path under `/media/volume/`

Next → **[Part 2 · Prepare your dashboard](../part2-prepare/index.md)**, which
you do on your own computer.
