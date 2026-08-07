# Part 3 · Publish it

<p class="meta-line">15 minutes of clicking, plus 5–45 minutes of build time you don't have to watch.</p>

Everything from here happens in the **Deploy My Dashboard** application on your
instance's desktop. It has four tabs, and they're numbered because they're
meant to be done in order.

<ul class="steps">
  <li><span class="steps__n">Tab 1</span> Your app — where your code is</li>
  <li><span class="steps__n">Tab 2</span> Your data — where your data lives</li>
  <li><span class="steps__n">Tab 3</span> Publish — build and go live</li>
  <li><span class="steps__n">Tab 4</span> Manage — check on it, restart it, read its logs</li>
</ul>

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-app-overview.png</span>
  </div>
  <figcaption>The Deploy My Dashboard window with all four tabs visible, on tab
  1. This is the guide's hero image — take it at a comfortable window size with
  a real project selected.</figcaption>
</figure>

---

## What the application actually does

Worth knowing, because it changes how you read its error messages.

The application is a **thin front end**. Every button runs the same shell
scripts that a command-line user would run, and any error you see is that
script's own message, passed through unchanged rather than reworded. Nothing is
hidden from you, and nothing happens that you couldn't do yourself in a
terminal.

Two consequences:

- **Error messages are literal and precise.** When it says a package failed to
  compile, that's the compiler talking. Reading the last few lines of the
  progress log is genuinely the fastest way to understand a failure.
- **You can switch between the two freely.** A deploy done from a terminal
  shows up in the application, and vice versa. See
  [Command line equivalents](../reference/command-line.md).

---

## Before you open it

Make sure you have to hand:

- [ ] Your **prepared project** — as a Git URL, a `.zip`, or a folder you're
      about to copy across *(from [Part 2](../part2-prepare/index.md))*
- [ ] Your **volume path** — `/media/volume/<name>` *(from [Part 1](../part1-instance/attach-volume.md))*
- [ ] Your **data**, ready to upload
- [ ] Your instance's **IP address**

---

Start → **[Open the web desktop](open-the-desktop.md)**
