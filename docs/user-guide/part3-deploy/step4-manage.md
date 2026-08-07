# Step 4 · Manage

<p class="meta-line">The tab you'll come back to. Tab 4 of the application.</p>

Once your dashboard is live, this tab is where you check on it, restart it, read
its logs, and get help.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab4-healthy.png</span>
  </div>
  <figcaption>Tab 4 with a healthy dashboard: the green headline with the URL,
  the button row, Details, Storage, and the log pane.</figcaption>
</figure>

---

## The headline

The top line tells you the state of things in plain language:

> **The dashboard is up and reachable.** Your dashboard is at
> `http://149.165.170.42/`

It re-checks itself **every 30 seconds** while you're looking at this tab, so a
dashboard that recovers — or stops responding — becomes visible without you
pressing anything. The timestamp beside **Keep checking automatically** says
when the reading is from.

(The automatic check is skipped when you're on a different tab. Each probe costs
real time against a wedged dashboard, and there's no sense spending it on a tab
nobody is looking at.)

### What each verdict means

| Headline | What's happening | What to do |
|---|---|---|
| **Up and reachable** | Working | Nothing |
| **Nothing is published yet** | No dashboard exists on this instance | Steps 1–3 |
| **Your dashboard is stopped** | It exists but isn't running — and stays stopped, including through a reboot | **Start** |
| **The app isn't responding** | The container is running but your app inside it is silent | Read the log below |
| **The web server isn't serving** | Your app is fine; nginx in front of it isn't | [Troubleshooting](../help/troubleshooting.md#nginx-problems) |
| **The web server can't reach the app** | Both are running but not talking | [Troubleshooting](../help/troubleshooting.md#nginx-problems) |
| **Answering, but its health check is failing** | It responds, but not consistently | Read the log; may restart itself |

That distinction between *your app* and *the web server in front of it* exists
because from a browser the two failures look identical — a page that won't load
— and they need completely different fixes.

---

## The buttons

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab4-buttons.png</span>
  </div>
  <figcaption>Close-up of the button row: Open dashboard, Refresh,
  Restart/Start, Stop, Publish again.</figcaption>
</figure>

**Open dashboard**
:   Opens your dashboard in the desktop's browser.

**Refresh**
:   Re-checks now rather than waiting for the automatic poll.

**Restart** *(or **Start**, if it's stopped)*
:   Restarts your dashboard without rebuilding. Takes seconds.

    **This is what you press after updating your data**, since data is attached
    rather than baked in.

    Also the first thing to try if your dashboard has gone strange — sluggish,
    stuck, memory-bloated.

**Stop**
:   Takes your dashboard offline. It asks first, because:

    !!! warning "Stop is stickier than it looks"

        A stopped dashboard **stays stopped**, including across a reboot, until
        you start it again. It will not quietly come back on its own.

    Stopping does not save you money — the instance is what's billed, and it's
    still running. To stop being charged, shut down the *instance* in
    Exosphere.

**Publish again**
:   Rebuilds from your current code and republishes. Your existing dashboard
    stays up until the new one is ready.

    This is how you deploy a code change: update the code, press this.

---

## Details

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab4-details.png</span>
  </div>
  <figcaption>The Details panel with all eight rows populated.</figcaption>
</figure>

Eight facts, ordered the way you'd read them while working out what's wrong.
**These are the things to quote when asking for help.**

| Row | Reading it |
|---|---|
| **Container** | `running` is what you want. `exited` means it stopped or crashed. |
| **Health check** | `healthy` / `unhealthy` / `starting`. `starting` is normal for the first few minutes. |
| **Restarts** | Should be `0` or low. A climbing number means your app is crash-looping. |
| **Served by** | `nginx on port 80 → app on 127.0.0.1:8080` is the expected setup. |
| **Responding** | Raw HTTP codes from each layer. `200` is good; `502` means nginx can't reach your app; `000` means nothing answered at all. |
| **Auto-restart** | Whether the watchdog that restarts a wedged dashboard is running. |
| **Memory** | How much your dashboard is using. Climbing steadily over days suggests a leak. |
| **Disk** | Free space on the instance's own disk. |

!!! tip "Restarts climbing is the clearest signal of a crash loop"

    If **Restarts** goes up every time you press Refresh, your app is starting,
    failing, and being restarted over and over. The log below shows the same
    error repeating. Almost always a missing data file or a missing package.

---

## Storage

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab4-storage.png</span>
  </div>
  <figcaption>The Storage panel showing free space, image size, reclaimable
  space, and the Free up space button.</figcaption>
</figure>

```
Disk: 23.1 GB free of 60 GB.  Your dashboard's image is 7.2 GB.
Can be freed up: 4.1 GB of old layers, 8.9 GB of build cache.
```

Every time you republish, the previous version's leftovers stay behind and the
build cache grows. On a modest instance this eventually fills the disk — and
running out **during** a build produces one of the least readable errors this
tooling can generate, because it surfaces as a compile failure naming a file
rather than as "the disk is full".

When free space gets tight the panel says so explicitly, rather than leaving you
to judge whether a number is worrying.

**Free up space** removes leftover pieces of previous builds and the build
cache. It is deliberately conservative:

| Removed | Kept |
|---|---|
| Untagged leftover layers from previous builds | Your dashboard's current image |
| Docker's build cache | Your stopped dashboard container, if you stopped it |
| | The auto-restart watchdog |

Your running dashboard is unaffected. The only cost is that your next publish
is slower, because the cached pieces have to be rebuilt.

It can take a few minutes on a large cache. The button greys out while it works.

---

## Recent output from your app

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab4-logs.png</span>
  </div>
  <figcaption>The log pane showing typical R Shiny startup output.</figcaption>
</figure>

**Show latest** fetches your app's own output — everything it has printed,
including errors and warnings. This is where an R traceback or a Python
exception appears.

**Save to a file…** writes it out so you can attach or email it.

What to look for:

```console
# ✅ Healthy R Shiny startup
[2026-08-07T14:22:01.104] [INFO] shiny-server - Starting listener on 0.0.0.0:3838

# ❌ A missing data file — the single most common failure
Warning: Error in file: cannot open file 'data/counts.csv': No such file or directory

# ❌ A missing package
Error in library(leaflet) : there is no package called 'leaflet'

# ❌ Out of memory (the container was killed)
Killed
```

For the first of those, go back to
[How your app finds its data](../part2-prepare/data-paths.md) — it's nearly
always an empty or wrong data folder.

---

## Save a report to send for help

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab4-report.png</span>
  </div>
  <figcaption>The "Report saved" dialog naming the file path.</figcaption>
</figure>

Press this before emailing anyone. It writes a single file containing the
health verdict, disk figures, what's running, the proxy configuration, the web
server's recent errors, and your app's own log.

It gathers nothing you couldn't read yourself on this tab — it exists so that
asking for help is one button instead of six commands read out over email.

The file lands in `~/dashboard-deploy-logs/`, and the dialog offers to open the
folder. Attach it to your email.

---

## Everyday tasks

??? question "I changed my data. What do I do?"

    Upload the new files to your volume, then press **Restart**. Seconds, no
    rebuild — because data is attached rather than built in.

??? question "I changed my code. What do I do?"

    Get the new code onto the instance (`git pull` in the project folder, or
    re-download on tab 1), then press **Publish again**.

    Your existing dashboard keeps serving until the new one is ready.

??? question "I want to publish a completely different dashboard here"

    Go to tab 1 and select the new project, then publish. The old one is
    replaced automatically — one instance runs one dashboard.

    If you want both reachable at once, create a second instance.

??? question "I closed the application. Did I lose anything?"

    No. Reopen it and it comes back on whatever is currently published — tabs 1
    and 2 refilled with the project and data folder your live dashboard was
    built from.

    It reads that from the running dashboard itself, so it's right even after a
    reboot, even if you published from a terminal, and even if you're on a
    different computer.

??? question "I deleted the project folder. Is my dashboard broken?"

    No. Your code was copied into the image when you published, so it keeps
    serving. Tab 1 will tell you the folder is gone.

    You will need the code back before you can publish again.

---

Next → **[Share and update your dashboard](share-your-dashboard.md)**
