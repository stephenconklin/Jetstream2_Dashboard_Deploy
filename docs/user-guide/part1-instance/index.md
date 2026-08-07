# Part 1 · Set up your server

<p class="meta-line">About 20 minutes, most of it spent waiting for things to boot.</p>

In this part you'll create two things in **Exosphere**, Jetstream2's web
interface:

<ul class="steps">
  <li class="is-current"><span class="steps__n">1 · Instance</span> The server that runs your dashboard, built from a prepared image</li>
  <li class="is-current"><span class="steps__n">2 · Volume</span> A separate disk that holds your data</li>
  <li class="is-current"><span class="steps__n">3 · Attach</span> Connecting the two together</li>
</ul>

---

## Why two separate things?

This trips people up, so it's worth 30 seconds now.

**The instance** is the computer. It has its own disk, but that disk is part of
the instance — delete the instance and the disk goes with it. It's also
relatively small.

**The volume** is a separate disk you rent independently. You attach it to an
instance, use it, and it survives everything that happens to that instance. You
can detach it and plug it into a different instance later.

```
┌─────────────────────────────────┐
│  Instance  (the computer)       │
│                                 │
│   • Ubuntu Linux                │
│   • Docker + nginx              │      ← from the Dashboard Deploy image
│   • Deploy My Dashboard app     │
│   • your dashboard's CODE       │
│                                 │
│   /media/volume/my-data ────────┼──→ ┌──────────────────┐
└─────────────────────────────────┘    │ Volume           │
                                       │  your DATA       │
                                       └──────────────────┘
                                        survives independently
```

So: **code on the instance, data on the volume.** Your dashboard's code is
small and usually lives in Git anyway; your data may be tens of gigabytes and
is the thing you'd least like to lose or re-upload.

!!! tip "Skipping the volume"

    If your dataset is genuinely small — a few CSV files totalling under a
    gigabyte, say, that live inside your project folder — you can skip the
    volume and keep everything on the instance. The publish flow handles this
    fine. Come back and add a volume when the data grows.

---

## Log in to Exosphere

Everything in Part 1 happens at **[exosphere.jetstream-cloud.org](https://exosphere.jetstream-cloud.org/)**.

Sign in with your ACCESS credentials, then choose the allocation you want to
use. If you belong to more than one, pick deliberately — that's what gets
charged.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p1-exosphere-home.png</span>
  </div>
  <figcaption>The Exosphere home page after logging in, showing the allocation
  selector and the <strong>Create</strong> button.</figcaption>
</figure>

!!! info "Exosphere vs. Horizon"

    Jetstream2 offers two web interfaces. **Exosphere** is the friendly one and
    is what this guide uses throughout. **Horizon** is the raw OpenStack
    dashboard — more powerful, much more to learn. You never need it here.

---

Next → **[Create your instance](create-instance.md)**
