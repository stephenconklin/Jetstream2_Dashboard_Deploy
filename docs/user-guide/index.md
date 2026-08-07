# Publish your dashboard on Jetstream2

You built a dashboard — in **R Shiny**, **Plotly Dash**, **Python Shiny**, or
**Streamlit** — and it works on your laptop. Now you want a web address you can
put in a paper, send to a collaborator, or hand to a funder, and have it still
work six months from now.

This guide takes you there. It assumes you have never used Docker, never
configured a web server, and would rather not open a terminal. Where a terminal
is genuinely the easiest tool for a job, the exact command is given and you can
copy it.

!!! tip "The short version"

    Rent a server from Jetstream2 built from a prepared image, put your code and
    data on it, then click **Publish my dashboard**. Your dashboard gets a
    permanent address like `http://149.165.xxx.xxx/` and stays up.

---

## What you'll do

<ul class="steps">
  <li><span class="steps__n">Part 1</span> Create a server and a place to keep your data</li>
  <li><span class="steps__n">Part 2</span> Get your dashboard ready to travel</li>
  <li><span class="steps__n">Part 3</span> Publish it and keep it running</li>
</ul>

<div class="grid cards" markdown>

-   :material-server: **[Part 1 · Set up your server](part1-instance/index.md)**

    Launch a Jetstream2 instance from the **Dashboard Deploy** image, create a
    storage volume for your data, and attach it.

    *About 20 minutes, most of it waiting.*

-   :material-folder-check: **[Part 2 · Prepare your dashboard](part2-prepare/index.md)**

    Three things have to be true before a dashboard can be published: the right
    file layout, a list of the packages it needs, and data paths that survive
    the move. Do this on your own computer.

    *30 minutes to an afternoon, depending on the project.*

-   :material-rocket-launch: **[Part 3 · Publish it](part3-deploy/index.md)**

    Open the web desktop, click the **Deploy My Dashboard** icon, and work
    through its four tabs. Then check on it, read its logs, and update it.

    *15 minutes of clicking; the build itself takes 5–40 minutes.*

-   :material-lifebuoy: **[Help](help/troubleshooting.md)**

    Symptom-by-symptom fixes for the things that actually go wrong, plus the
    questions people ask most.

</div>

---

## Is this guide for you?

**Yes, if** you have a working dashboard in one of the four supported
frameworks and access to a Jetstream2 allocation.

**Not quite yet, if** you don't have a Jetstream2 allocation. See
[Before you start](before-you-start.md) — it takes a few days to get one, so
begin there.

**You may want something else, if** you need several dashboards reachable at
once, or user logins and passwords on your dashboard. This tooling runs
**one dashboard per server** and publishes it to the open internet. See
[Questions people ask](help/faq.md).

---

## What "published" actually means here

Your dashboard runs inside a **container** on a Linux server that Jetstream2
rents you. A container is a sealed box holding your code plus every package it
needs, so what runs on the server is not affected by anything else installed
there. You never have to build or think about that box — the **Deploy My
Dashboard** application does it.

The result:

| | |
|---|---|
| **Address** | `http://<your-instance-ip>/` — fixed, and yours as long as the instance exists |
| **Uptime** | Restarts by itself if it crashes, and comes back after the server reboots |
| **Your data** | Lives on a separate storage volume, so you can update it without rebuilding anything |
| **Cost** | Charged against your Jetstream2 allocation while the instance is on |

!!! warning "It is public by default"

    Anyone with the address can open your dashboard. There is no login screen.
    Don't publish anything you wouldn't put on a public web page — see
    [Questions people ask](help/faq.md#is-my-dashboard-private).

---

## Getting help

If something breaks, the application has a **Save a report to send for help**
button on its **Manage** tab. That file contains everything a helper needs. See
[When something goes wrong](help/troubleshooting.md).

For questions about Jetstream2 itself — allocations, quotas, instances that
won't start — the Jetstream2 team is at
[help@jetstream-cloud.org](mailto:help@jetstream-cloud.org) and their
documentation is at [docs.jetstream-cloud.org](https://docs.jetstream-cloud.org/).
