# Open the web desktop

<p class="meta-line">2 minutes.</p>

The web desktop is a full Linux desktop delivered to your browser. No software
to install, no SSH keys, no terminal — it works from any machine you can log in
to Exosphere from.

---

## 1. Open it from Exosphere

Go to [exosphere.jetstream-cloud.org](https://exosphere.jetstream-cloud.org/),
click your instance's name, and find **Web Desktop** among the actions.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-webdesktop-link.png</span>
  </div>
  <figcaption>The instance detail page in Exosphere with the Web Desktop action
  highlighted.</figcaption>
</figure>

It opens in a new browser tab and takes a few seconds to connect.

!!! tip "Give it room"

    Put the browser tab in full screen (++f11++ on most systems). The
    application's window has four tabs and a log pane, and a cramped browser
    window makes it much harder to work with.

---

## 2. Find the Deploy My Dashboard icon

The desktop has a **Deploy My Dashboard** icon on it. Double-click it.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-desktop-icon.png</span>
  </div>
  <figcaption>The Ubuntu desktop after connecting, with the Deploy My Dashboard
  icon visible. Include enough surrounding desktop that it's findable.</figcaption>
</figure>

The window takes a few seconds to appear the first time.

If it doesn't appear at all, the icon is also in the applications menu under
**Deploy My Dashboard**. Failing that, see
[the troubleshooting page](../help/troubleshooting.md#application-problems).

---

## 3. What you'll see

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-first-open.png</span>
  </div>
  <figcaption>The application on first open, on tab 1, with nothing selected
  yet.</figcaption>
</figure>

On a fresh instance it opens on **1. Your app** with nothing selected.

If a dashboard is **already published** on this instance, the application
reopens on it — tabs 1 and 2 come back filled in with the project and data
folder it's currently serving, and tab 1 says *Currently published*. It reads
that from the running dashboard itself, so it's accurate even if you published
from a terminal, or from a different browser, or last month.

---

## Working in the web desktop

A few things behave differently from a desktop on your own machine.

??? tip "Copy and paste"

    Copying between your own computer and the web desktop goes through the
    session's clipboard panel rather than working directly. In Guacamole-based
    sessions, ++ctrl+alt+shift++ opens a side panel with a clipboard box: paste
    into it on one side, and it becomes available on the other.

    The application avoids needing this where it can — any command it wants you
    to run is shown in a box you can select and copy from, and its buttons open
    links directly rather than making you retype URLs.

??? tip "Getting a terminal"

    You rarely need one, but: applications menu → **Terminal**, or right-click
    the desktop.

??? warning "The session can drop"

    Remote desktop connections drop — a laptop sleeping, a wifi change, a VPN
    reconnect. **This does not kill your build.** Builds run detached from the
    application, so if your connection drops mid-build the build carries on
    without you. Reconnect, reopen the application, and it picks the build back
    up where you left it.

    This is a deliberate design decision, because a 40-minute R build that died
    because a laptop lid closed would be intolerable.

??? note "It feels slow"

    Screen-sharing a desktop over the internet is inherently laggy. Try a
    smaller browser window, and close any other tabs streaming video. Nothing
    you do in this application is timing-sensitive.

---

Next → **[Step 1 · Your app](step1-your-app.md)**
