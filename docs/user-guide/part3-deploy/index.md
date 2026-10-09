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

## Finding your way around

The window is built to tell you, at every moment, two separate things: **what's
live now**, and **how far you've got** with what you're preparing.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-live-bar.png</span>
  </div>
  <figcaption>The top of the window: the live bar with a dashboard live and the
  amber "different project" line, the key, and the tabs with their symbols.</figcaption>
</figure>

**The live bar**, across the top, is about the dashboard people can visit
right now, whichever tab you're on. It reads *Nothing published yet* until you
publish, then *LIVE — your-project · published 3 Oct, 14:02* with an **Open
dashboard** button. Its second line says how what you're preparing relates to
it:

| It says | Meaning |
|---|---|
| *Same folder and settings as what's live* | Publishing again picks up any edits you've made to your files |
| *You've changed the main file or the data settings* | Publishing applies those changes |
| *This is a different project … publishing will replace it* (amber) | You'll be asked to confirm, with both folders named |
| *Building a new version — the current dashboard stays up* | Your old dashboard keeps serving until the new one is ready |

**The symbols** on each tab, and the coloured line at the top of tabs 1–3,
show where each step stands. The same key is shown under the live bar:

| Symbol | Means |
|---|---|
| ○ | To do — or not available yet |
| ⚠ | Needs your attention — the line says what |
| ◐ | Working — a publish is running |
| ✓ | Done |
| ✗ | Didn't finish — the reason is in the progress log |

The symbol is never the whole message: the line at the top of the tab always
says it in words.

**Greyed out means "not yet", not "broken".** Tabs 2 and 3 open once step 1
has found your dashboard. While a publish is running, tabs 1 and 2 are locked,
since changing them couldn't affect a build that has already started. The
publish button says why it's greyed, right beside it. Each step's **Next →**
button lights up once that step is done.

**The publish button says what it will do:** *Publish my dashboard* the first
time, *Update my dashboard* after you've changed settings, *Publish again* when
nothing has changed, and *Replace the live dashboard…* when you've picked a
different project.

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
