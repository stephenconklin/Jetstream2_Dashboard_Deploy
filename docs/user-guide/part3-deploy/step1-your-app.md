# Step 1 · Your app

<p class="meta-line">5 minutes. Tab 1 of the application.</p>

This tab answers one question: **where is your dashboard's code?** It offers
three ways, and once you've answered it immediately tells you what it found.

<figure class="shot">
  <img src="../../assets/screenshots/p3-tab1-empty.png"
       alt="Tab 1 with the three radio options — already on this server, download from Git, or a .zip file — and nothing selected yet.">
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

    <figure class="shot">
      <img src="../../assets/screenshots/p3-tab1-git.png"
           alt="Tab 1 with the Git option selected, showing the Address field with a repository URL entered.">
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

    <figure class="shot">
      <img src="../../assets/screenshots/p3-tab1-zip.png"
           alt="Tab 1 with the zip option selected, a file chosen, and the Unpack it button.">
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
    a `git clone` from a terminal, or a previous session.

    1. Select **It's already on this server**
    2. Click **Browse…** and find the folder, or type the path
    3. Click **Use this folder**

    <figure class="shot">
      <img src="../../assets/screenshots/p3-tab1-browse.png"
           alt="Tab 1 with the browse option, showing a folder path selected.">
      <figcaption>Tab 1 with the browse option, showing a folder path selected.</figcaption>
    </figure>

    Pick the folder that **contains** your dashboard's code, not the folder
    above it and not the file itself.

---

## Read what it found

However you got here, the application immediately inspects the project and
reports back:

<figure class="shot">
  <img src="../../assets/screenshots/p3-tab1-detected.png"
       alt="Tab 1 after a successful selection: the detected framework, and the 'Your dashboard's main file' box with its dropdown.">
  <figcaption>Tab 1 after a successful selection: the detected framework, and
  the "Your dashboard's main file" box with its dropdown.</figcaption>
</figure>

```
Found a r-shiny dashboard in /home/exouser/water-quality

Next, check step 2: it asks where your dashboard's data files are.
```

**Check two things.** It takes five seconds and catches most of the problems
that would otherwise show up 20 minutes into a build.

| What | What you're checking |
|---|---|
| **The framework** | Is it the one you expect? |
| **The main file** | Is that the file you run to start your dashboard? |

### Your dashboard's main file

This is the file you'd open and run to start your dashboard — in RStudio,
the one you press **Run App** on. It **doesn't need any particular name**:
`cc_water_quality.R` works just as well as `app.R`.

<figure class="shot">
  <img src="../../assets/screenshots/p3-tab1-main-file.png"
       alt="The 'Your dashboard's main file' box with the dropdown open, listing two candidate files.">
  <figcaption>The "Your dashboard's main file" box with the dropdown open,
  listing two candidate files.</figcaption>
</figure>

- **One likely file:** it's picked for you. If it isn't called `app.R`, a note
  says so. That's fine: when you publish, a one-line `app.R` that runs your
  file is added to the published copy. Nothing in your folder changes.
- **Several likely files:** nothing is picked, and **Publish** stays disabled
  until you choose one from the dropdown. Old versions are the usual cause
  (`app_v2.R`, `app_old.R`).
- **The wrong file was picked:** choose a different one from the dropdown, or
  use **Choose another file…** to pick any `.R` or `.py` file in the folder.

R Shiny files that *build* `ui` and `server` but never call `shinyApp()` can
be chosen too. The published copy finishes the job for you.

### Worth checking in your code

If your code does something that works on your own computer but usually not
on a server, a box appears listing each case with its file and line number:

<figure class="shot">
  <img src="../../assets/screenshots/p3-tab1-code-notes.png"
       alt="The 'Worth checking in your code' box listing two notes — a setwd() call and a file name whose capitals don't match.">
  <figcaption>The "Worth checking in your code" box listing two notes — a
  setwd() call and a file name whose capitals don't match.</figcaption>
</figure>

| It says | Why it matters on the server |
|---|---|
| uses `"C:/…"`, `"/Users/…"`, `"~/…"` | That's a location on your own computer. Put the file in your app folder and use just its name |
| calls `setwd()` | That folder doesn't exist on the server, and the app already runs from its own folder |
| calls `install.packages()` | Publishing installs your packages. Doing it again on every start is slow and can fail |
| calls `runApp()` | The server starts your app itself. A second `runApp()` stops it from ever finishing starting up |
| reads `"stations.csv"`, but the file is called `"Stations.csv"` | Mac and Windows ignore capital letters in file names. The server doesn't |
| reads a file that isn't in your app folder | It won't be on the server either, unless it's in your data folder (step 2) |

These are **advice, not errors**. They never stop you publishing, and an
occasional one may not apply (a line in a data-preparation script the
dashboard never runs, say). But if your dashboard shows an error after
publishing, start with this list.

A few things are fixed automatically and don't need you at all. They're
fixed in the published copy only, never in your folder:

- an `.Rprofile` that activates `renv` (the package library it points to
  isn't on the server — packages are installed for you instead)
- RStudio's leftovers (`.RData`, `.Rhistory`, `.Rproj.user/`, `rsconnect/`)
  are left out

---

## If it can't recognise your project

An error dialog appears with the script's own explanation. The ones you're
likely to see:

??? failure "“Couldn't find a dashboard's main file”"

    Nothing in the folder looks like a dashboard to the automatic check.
    If the folder does contain `.R` or `.py` files, the application offers to
    let you **choose the main file yourself** — say yes and pick the file you
    run to start your dashboard.

    Otherwise:

    - Check you selected the folder **containing** the app file, not its parent
    - Check the file is at the top level, not in `src/` or `inst/`
    - Check the signals in
      [Check your file layout](../part2-prepare/entry-point.md)

    If your app lives in a subfolder, add a shim — see
    [the starting file must be at the top level](../part2-prepare/entry-point.md#the-starting-file-must-be-at-the-top-level).

??? failure "“That file can't be used”"

    The file you chose as the main file was turned down, with the reason.
    The most common one: the folder also has an `app.R`, which the server
    always runs first. Choose `app.R`, or rename it (to `old_app.R`, say) so
    the file you chose is the one that runs.

??? failure "“Multiple framework signals detected” — Python files for different frameworks"

    The error names each file and the framework signal it found in each —
    say, a Dash `app.py` next to an old Streamlit script. Almost always a
    leftover from an earlier version.

    Say yes when the application offers to let you choose the main file, and
    pick the right one. Or delete or rename the one you don't want deployed
    and select the folder again. Renaming to
    `old_app.py.bak` is enough.

??? failure "“no requirements.txt was found”"

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

??? failure "“Could not download” from a Git address"

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
