# Step 1 · Your app

<p class="meta-line">5 minutes. Tab 1 of the application.</p>

This tab answers one question: **where is your dashboard's code?** It offers
three ways, and once you've answered it immediately tells you what it found.

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab1-empty.png</span>
  </div>
  <figcaption>Tab 1 with the three radio options — already on this server,
  download from Git, or a .zip file — and nothing selected yet.</figcaption>
</figure>

---

## Choose how your code gets here

=== "Download from GitHub"

    **The smoothest option**, and worth setting up for if you haven't.

    1. Select **Download it from GitHub (or another Git address)**
    2. Paste the repository URL:
       `https://github.com/your-lab/your-dashboard`
    3. Click **Download**

    The repository is cloned into your home folder on the instance and selected
    automatically.

    <figure class="shot shot--todo">
      <div class="shot__box">
        <span class="shot__label">Screenshot needed</span>
        <span class="shot__file">assets/screenshots/p3-tab1-git.png</span>
      </div>
      <figcaption>Tab 1 with the Git option selected, showing the Address field
      with a repository URL entered.</figcaption>
    </figure>

    **Private repository?** You'll be prompted for a username and password.
    GitHub no longer accepts account passwords here — create a
    [personal access token](https://github.com/settings/tokens) with `repo`
    scope and paste that as the password.

    If that's a nuisance, download a `.zip` from GitHub's web interface
    instead and use the zip option.

=== "A .zip file"

    **The simplest option, and needs nothing set up.**

    1. **Drag the `.zip` from your own computer onto the web desktop.** It
       lands in your home folder (`/home/exouser`).
    2. Select **I have a .zip file**
    3. Click **Choose…**, pick the file, then click **Unpack it**

    <figure class="shot shot--todo">
      <div class="shot__box">
        <span class="shot__label">Screenshot needed</span>
        <span class="shot__file">assets/screenshots/p3-tab1-zip.png</span>
      </div>
      <figcaption>Tab 1 with the zip option selected, a file chosen, and the
      Unpack it button.</figcaption>
    </figure>

    It's unpacked and selected automatically.

    !!! warning "Zips are for code, not data"

        Drag-and-drop is slow and unreliable above about a gigabyte. Keep the
        zip to your project code and move the data across separately in
        [step 2](step2-your-data.md).

=== "Already on this server"

    Use this if you copied your project across some other way — `rsync`,
    Globus, a `git clone` from a terminal, or a previous session.

    1. Select **It's already on this server**
    2. Click **Browse…** and find the folder, or type the path
    3. Click **Use this folder**

    <figure class="shot shot--todo">
      <div class="shot__box">
        <span class="shot__label">Screenshot needed</span>
        <span class="shot__file">assets/screenshots/p3-tab1-browse.png</span>
      </div>
      <figcaption>Tab 1 with the browse option, showing a folder path selected.</figcaption>
    </figure>

    Pick the folder that **contains** `app.R` / `app.py`, not the folder above
    it and not the file itself.

---

## Read what it found

However you got here, the application immediately inspects the project and
reports back:

<figure class="shot shot--todo">
  <div class="shot__box">
    <span class="shot__label">Screenshot needed</span>
    <span class="shot__file">assets/screenshots/p3-tab1-detected.png</span>
  </div>
  <figcaption>Tab 1 after a successful selection, showing the detected
  framework, the entry point, and the note about the data folder.</figcaption>
</figure>

```
Found a r-shiny dashboard in /home/exouser/salmon-dashboard
Entry point: app.R

This project includes a data/ folder, so choose where that data lives
on this server in step 2.
```

**Check all three lines.** This takes five seconds and catches most of the
problems that would otherwise appear 20 minutes into a build.

| Line | What you're checking |
|---|---|
| **Framework** | Is it the one you expect? |
| **Entry point** | Is that actually your app's starting file? |
| **The note at the end** | Does it match what you know about your data? |

That last line is worth dwelling on. It says one of two things:

> *"This project includes a `data/` folder, so choose where that data lives in
> step 2."*

You **must** answer step 2. The Publish button stays disabled until you do.

> *"This project doesn't include a `data/` folder. If your dashboard reads data
> files kept somewhere else — on your storage volume, say — point step 2 at
> them. Otherwise go straight to step 3."*

You **may** need step 2 anyway, and this is the case people get wrong. If you
moved your data onto the volume in Part 2 — which is the recommended thing to
have done — then you have no `data/` folder *and* you definitely need step 2.
The application can't tell those two situations apart, so you have to.

---

## If it can't recognise your project

An error dialog appears with the script's own explanation. The three you're
likely to see:

??? failure "\"No app.R, ui.R/server.R, ... or a recognizable app.py found\""

    The starting file isn't where it's looking, or doesn't contain a
    recognisable signal.

    - Check you selected the folder **containing** the app file, not its parent
    - Check the file is at the top level, not in `src/` or `inst/`
    - Check the signals in
      [Check your file layout](../part2-prepare/entry-point.md)

    If your app lives in a subfolder, add a shim — see
    [the starting file must be at the top level](../part2-prepare/entry-point.md#the-starting-file-must-be-at-the-top-level).

??? failure "\"Ambiguous framework\" — signals found in more than one file"

    The error names each file and the framework signal it found in each. Almost
    always a leftover file from an earlier version.

    Delete or rename the one you don't want deployed, then select the folder
    again. Renaming to `old_app.py.bak` is enough.

    If the ambiguity is genuine, you can force the choice on
    [tab 3 under Advanced](step3-publish.md#advanced-options).

??? failure "\"no requirements.txt was found\""

    A Python project without its package list. This is a hard stop — the
    application will let you select the project, but the Publish button on
    tab 3 stays disabled and tells you what to do.

    Go back to
    [creating a requirements.txt](../part2-prepare/python-packages.md). If your
    app already works somewhere on this instance, you can generate one here:

    ```bash
    cd ~/my-dashboard
    pip freeze > requirements.txt
    ```

    Then click **Use this folder** again to re-inspect.

??? failure "\"Could not download\" from a Git address"

    Check the URL is right and reachable — paste it into the desktop's browser
    to confirm. For a private repository, use a personal access token as the
    password, not your account password.

---

## Re-selecting after a change

If you edit your project on the instance — adding a `requirements.txt`, fixing
a path — click **Use this folder** again. The application re-inspects from
scratch and updates what it reports.

---

Next → **[Step 2 · Your data](step2-your-data.md)**
