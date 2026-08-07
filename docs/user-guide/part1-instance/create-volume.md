# Create a storage volume

<p class="meta-line">About 2 minutes.</p>

A volume is a disk you rent separately from any instance. Your dashboard's
**data** goes here, so that it survives whatever happens to the server.

!!! question "Do I need one?"

    **Yes**, if your data is more than about a gigabyte, or if losing it would
    mean re-uploading something painful, or if you might rebuild the instance
    later.

    **Not necessarily**, if your dashboard reads a couple of small CSV files
    that live inside the project folder itself. Those get copied onto the
    instance along with your code. You can skip to
    [Part 2](../part2-prepare/index.md) and add a volume later.

---

## 1. Create it

In Exosphere: **Create** → **Volume**.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p1-create-volume.png</span>
  </div>
  <figcaption>The Create Volume form, showing the Name and Size fields.</figcaption>
</figure>

**Name**
:   Keep it short and lowercase, with hyphens instead of spaces — `salmon-data`,
    not `Salmon Data (2024)`. The name becomes part of a filesystem path you'll
    type and read later, and spaces and capitals make that unpleasant.

**Size**
:   Ask for what your data needs plus comfortable headroom. **Volumes can be
    grown later but not shrunk**, and you're billed for what you reserve, so
    don't reflexively ask for a terabyte.

    A useful rule: your dataset's size, doubled, rounded up to something tidy.
    A 40 GB dataset → ask for 100 GB.

Click **Create**. It's ready in seconds — volumes are much faster to create
than instances.

---

## 2. Check it appears

Your new volume shows in the volume list as **Available**, meaning it exists but
isn't connected to anything yet.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p1-volume-list.png</span>
  </div>
  <figcaption>The volume list with the new volume in the Available state.</figcaption>
</figure>

---

## What a volume costs

Storage is charged separately from instance time and is comparatively cheap.
Jetstream2 documents current rates under
[Allocations](https://docs.jetstream-cloud.org/alloc/overview/).

Two things worth knowing:

- **You are billed for the size you reserved, not the size you used.** A 500 GB
  volume holding 10 GB of data costs the same as a full one.
- **A volume keeps costing while it's detached.** Deleting the instance does
  not delete the volume — that's the point of it, but it does mean an orphaned
  volume can quietly bill you for months. Delete volumes you've genuinely
  finished with.

---

## Common problems

??? failure "Create is greyed out, or it says I'm over quota"

    Allocations have a storage quota separate from the compute one, covering
    both total gigabytes and number of volumes. Exosphere shows both on your
    allocation page.

    Delete volumes you no longer need, or request a quota increase through
    [ACCESS](https://access-ci.org/).

??? question "Can I make it bigger later?"

    Yes. Exosphere has a **Resize** action on a volume, and it can be grown
    while attached on recent Jetstream2 images. It cannot be shrunk.

??? question "Can two instances share one volume?"

    Not safely, and Jetstream2 doesn't support it. A volume attaches to one
    instance at a time. If two dashboards need the same dataset, either put
    both on one instance's volume, or keep two copies.

---

Next → **[Attach the volume](attach-volume.md)**
