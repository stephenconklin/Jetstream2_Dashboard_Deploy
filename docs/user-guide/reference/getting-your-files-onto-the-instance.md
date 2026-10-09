# Getting your dashboard and data onto the instance

Everything else in these docs assumes your project is already on the Jetstream2 instance. This page covers how it gets there.

You don't have to read all of this. Pick the row that matches you:

| Your situation | Use |
|---|---|
| My code is on GitHub / GitLab | [Git](#git) |
| I have a folder on my laptop | [Drag and drop](#drag-and-drop) for small things, [rsync](#rsync-or-scp) otherwise |
| I have a `.zip` | [Drag and drop](#drag-and-drop), then unzip |
| My data is in Google Drive / Box / Dropbox | [Cloud storage](#cloud-storage) |
| My dataset is large (several GB) | [rsync](#rsync-or-scp), which resumes if interrupted |

If you're using the **Deploy My Dashboard** application on the instance's desktop, it walks you through all of these and — importantly — checks afterwards that your files actually arrived. This page is the reference behind it.

---

## Code and data are different problems

**Your code** is small. Any method works; Git is usually easiest.

**Your data** may not be. Two rules save a lot of pain:

1. **Put data on your storage volume, not in your home folder.** The home folder lives on the instance's root disk: limited space, and gone if the instance is ever deleted. A volume under `/media/volume/...` persists independently and can be far larger.
2. **Small data can stay in your project folder; large data can't.** Anything in the project folder is published with the app, and every publish copies it again — fine for a few spreadsheets, not for gigabytes. Large data goes in one folder on your volume, which the deployment attaches at run time, so it can be updated without re-publishing.

   If you do move a `data/` folder out of your project and onto a volume, **tell the tool where it went** — choose *In a separate folder on this server* in the application's step 2 and pick that folder, or set `DATA_DIR=/media/volume/... ` on the command line. Your app keeps reading `data/` exactly as before; that path is supplied by the mount. Without it the dashboard will start and then fail to find its files.

---

## Git

Best for code. Not for large data — Git handles big binary files poorly.

```bash
cd ~
git clone https://github.com/your-lab/your-dashboard.git
```

Private repository? Either use a personal access token when prompted for a password, or set up an SSH key on the instance. If neither appeals, download a `.zip` from the web interface instead and use [drag and drop](#drag-and-drop).

---

## Drag and drop

The simplest option, and it needs no setup: drag files onto the remote desktop session and they arrive in your **home folder** (`/home/exouser`).

Good for a project folder, a `.zip`, or a handful of small files. It is slow and unreliable for large transfers — **beyond about a gigabyte, use one of the routes below instead.**

If you dropped a zip:

```bash
cd ~
unzip your-project.zip
```

If you dropped data, move it onto your volume rather than leaving it in home:

```bash
mv ~/mydata /media/volume/your-volume/
```

---

## rsync (or scp)

Best for a folder on your own computer, when you're comfortable with a terminal. Works on macOS and Linux directly, and on Windows through PowerShell, WSL, or Git Bash.

**Run this on your own computer, not on the instance:**

```bash
rsync -avP ~/mydata/ exouser@YOUR-INSTANCE-IP:/media/volume/your-volume/
```

- `-a` preserves the folder structure, `-v` shows what's happening, `-P` lets an interrupted transfer resume where it stopped — worth having for anything large.
- **The trailing slash on the source matters.** `~/mydata/` copies the *contents* into the destination. `~/mydata` (no slash) creates a `mydata` folder inside it. This trips up nearly everyone at least once.

`scp` works too and is slightly simpler, but it cannot resume:

```bash
scp -r ~/mydata/* exouser@YOUR-INSTANCE-IP:/media/volume/your-volume/
```

Prefer a graphical tool? **Cyberduck** (macOS/Windows), **WinSCP** (Windows), and **FileZilla** (all platforms) all speak SFTP — connect to your instance IP as `exouser` with your SSH key, then drag files across.

---

## Cloud storage

If your data already lives in Google Drive, Box, Dropbox, OSF or Zenodo, the easiest path is often to **open the instance's desktop, launch its web browser, and download directly**. The files never pass through your laptop, so you're limited by the instance's connection rather than your home broadband.

Download into your volume rather than the default `~/Downloads`, or move it afterwards.

For repeated or scripted transfers, `rclone` is worth setting up — it can sync a Drive or Box folder to the instance with one command.

---

## Checking it worked

Whichever route you used, confirm the files are where the deployment will look for them:

```bash
ls -lh /media/volume/your-volume/
du -sh /media/volume/your-volume/      # total size
df -h /media/volume/your-volume/       # space left
```

The desktop application has a **"Look in that folder now"** button that does the same thing.

One thing worth understanding: a data folder on your volume is **mounted into** the running dashboard rather than copied into it. It appears inside the app as `data/` — `/srv/shiny-server/data` for R Shiny, `/app/data` for the Python frameworks, or another name if your code uses one (`DATA_SUBDIR`) — and Python apps can also read the `DATA_DIR` environment variable. The practical upshot is that **updating that data doesn't require rebuilding anything**; replace the files and restart the app. Data kept in the project folder, by contrast, is published with the app and updated by publishing again.

See [deployment.md](deployment.md) for what happens next.
