# Questions people ask

---

## Access and privacy

### Is my dashboard private?

**No.** Anyone with the address can open it. There is no login screen, no
password, and no access control.

The address is a number nobody would guess, which is *obscurity*, not
*security* — search engines and automated scanners find IP addresses routinely.

If your dashboard shows anything you wouldn't put on a public web page, don't
publish it this way.

### Can I add a password?

Not through this tooling, which deliberately does one job. Your options, in
increasing order of effort:

1. **Put the login in your app.** Every framework can do it —
   [`shinymanager`](https://datastorm-open.github.io/shinymanager/) for R Shiny,
   [`streamlit-authenticator`](https://github.com/mkhorasani/Streamlit-Authenticator)
   for Streamlit, `dash-auth` for Dash. Simplest, and it stays with your app.
2. **Add HTTP basic auth in nginx.** A shared username and password in front of
   everything. Needs editing
   `deploy/nginx/dashboard.conf.template` and re-running provisioning — see
   [the nginx front end](../reference/deployment.md#the-nginx-front-end).
3. **Restrict by network.** Limit the instance's security group to your
   institution's IP range, so it's only reachable from campus.

### Can I restrict it to my institution?

Yes, and it's the most robust option if it fits. Edit the instance's security
group in Exosphere to allow inbound `80/tcp` only from your institution's IP
range, instead of from anywhere. Ask your IT department for the range.

### How do I give my dashboard a secret API key?

Not through a `.env` file — those are deliberately excluded from what gets
uploaded, so a secret can't end up baked into an image that might be shared.

The workable approaches:

- **A file on your data volume.** Read it at startup like any other data file.
  It never enters the image, and it's as protected as the instance is.
- **A file outside your project**, read with an absolute path on the instance.

Either way, remember your dashboard is public — anything it can display, a
visitor can see. Don't build a feature that echoes the key back.

---

## Cost and resources

### How much does this cost?

Your allocation is charged for **instance time**, whether or not anyone is
using your dashboard. An `m3.small` costs 2 service units per hour, roughly
1,500 SU/month. An Explore allocation of 100,000 SU covers that for years.

Volumes are charged separately and much more cheaply, by reserved size.

### Does stopping the dashboard save money?

**No.** The **Stop** button stops your dashboard; the instance keeps running
and keeps being charged. To stop the charge, shut down the *instance* in
Exosphere.

### How big an instance do I need?

Start with `m3.small` (2 vCPU, 6 GB). It handles most dashboards and most
audiences.

Go to `m3.medium` (8 vCPU, 30 GB) if:

- Your dashboard loads more than about 2 GB into memory
- It's an R geospatial project (builds are much faster with more cores)
- You expect many simultaneous users

You can resize later — it reboots the instance, and your dashboard comes back
automatically.

### How many people can use it at once?

More than you probably expect for browsing, fewer than you'd like for heavy
computation.

All four frameworks serve from a small pool of workers, so a user running a
long calculation occupies one for its duration. A dashboard that's mostly
displaying precomputed results handles dozens of concurrent users on an
`m3.small`. One that runs a model on every click handles a handful.

If concurrency matters, precompute what you can and resize up.

---

## Multiple dashboards

### Can I run two dashboards on one instance?

**No.** One instance runs one dashboard, by design. Publishing a second
replaces the first.

The reason is that supporting several would mean routing, port management and
per-dashboard package isolation — which is most of what makes deployment hard,
and all of what this tooling exists to avoid.

**Create a second instance instead.** It's a few clicks and its own IP address.

### Can two dashboards share one volume?

Not simultaneously — a volume attaches to one instance at a time. Either keep
two copies of the data, or put both dashboards on one instance… which you
can't. So: two copies.

---

## Frameworks and code

### Can I deploy Flask / FastAPI / Panel / Voilà / Quarto?

Not with this tooling. It supports R Shiny, Plotly Dash, Python Shiny and
Streamlit.

You can run anything you like on a Jetstream2 instance, but you'd be doing the
Docker and web-server work yourself. Start from the
[Jetstream2 documentation](https://docs.jetstream-cloud.org/).

### It detected the wrong framework. Why?

Detection reads your code for framework-specific signals rather than trusting
filenames — because `app.py` alone could be any of three frameworks plus Flask.

It gets it wrong when there's a **leftover file** with signals from an old
version. Delete or rename it.

If the ambiguity is genuine, force the choice on tab 3 →
[Advanced](../part3-deploy/step3-publish.md#advanced-options).

### Can I use a Jupyter notebook?

Not directly. Convert it to one of the four frameworks first — for a notebook
that's already mostly plots and widgets, Streamlit is usually the quickest
translation.

### Does my app need to be in Git?

No. Git, a `.zip`, or a folder copied across all work equally well.

Git makes updating much easier, though: `git push` on your machine,
`git pull` on the instance, **Publish again**.

---

## Data

### How big can my data be?

As big as your volume. Volumes can be hundreds of gigabytes, and your dashboard
reads from the volume directly rather than loading it all.

What matters more is how much your dashboard loads into **memory** at once —
that's bounded by the instance size, not the volume.

### Do I have to rebuild when my data changes?

**No.** Replace the files on the volume and press **Restart**. Seconds rather
than minutes.

This is the payoff for attaching data at run time instead of building it in,
and it's why the [data paths](../part2-prepare/data-paths.md) page is worth
getting right.

### Can my dashboard write files?

Yes, under `data/` — that folder is attached read-write, and anything written
there lands on the volume and survives restarts and republishes.

Anything written elsewhere inside the container is lost on the next restart.

### What if I don't have a volume?

Small data can live inside your project folder, in a `data/` directory, and
gets copied onto the instance with your code.

Fine for a few hundred megabytes. Beyond that, every build gets slower and the
instance's disk fills up. Create a volume.

---

## Operations

### What happens when the instance reboots?

Your dashboard starts again automatically — *provided* the data volume
remounts. Making that reliable is what
[Make it survive a reboot](../part3-deploy/step2-your-data.md#make-it-survive-a-reboot)
does, and it's worth the one click.

The exception: a dashboard you stopped with the **Stop** button stays stopped,
deliberately.

### What happens if my dashboard crashes?

It's restarted automatically.

If it *wedges* rather than crashing — alive but no longer answering, which
nothing built into Docker detects — a watchdog notices within a few minutes and
restarts it.

### Can I get a proper domain name?

Yes, and it's the only route to `https://`. See
[Can I get https?](../part3-deploy/share-your-dashboard.md#can-i-get-https).

### Will the address change?

Not while the instance exists. Reboots, republishes and resizes all preserve
it. Deleting the instance releases it.

### Can I move my dashboard to a different instance?

Yes. Create the new instance from the same image, move the volume across
(detach, attach), get your code onto it, and publish. Your project is
self-describing by this point, which is what makes that straightforward.

The address changes.

---

## The tooling itself

### Do I need to know Docker?

No. It's used underneath, and you never write a Dockerfile or run a `docker`
command.

If you're curious, [the technical reference](../reference/deployment.md)
explains exactly what's built and why.

### Can I use the command line instead?

Yes — the application is a thin front end over the same scripts, and the two
are interchangeable. A deploy done from a terminal shows up in the application
and vice versa. See
[Command line equivalents](../reference/command-line.md).

### Where are the logs?

`~/dashboard-deploy-logs/` on the instance. Every publish leaves a timestamped
file, and **Save a report to send for help** writes its bundle there too.

### How do I update the deployment tooling itself?

```bash
cd ~/Jetstream2_Dashboard_Deploy
git pull
```

Then publish again if a change affects how your dashboard is built. Your
running dashboard is unaffected until you do.

### Something's wrong that isn't covered anywhere

- Dashboard problems → [When something goes wrong](troubleshooting.md), then
  the project's [GitHub issues](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/issues)
- Instance, volume, allocation problems →
  [help@jetstream-cloud.org](mailto:help@jetstream-cloud.org)
