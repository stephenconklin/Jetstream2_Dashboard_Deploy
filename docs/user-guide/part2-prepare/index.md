# Part 2 · Prepare your dashboard

<p class="meta-line">30 minutes for a straightforward project; an afternoon for an old or complicated one. Done on your own computer, not the server.</p>

Your dashboard currently works because of things that live on *your* computer:
the packages you installed over the years, the folder structure on your disk,
the paths you typed. None of that travels.

This part makes your project self-describing, so a server that has never seen it
can rebuild the conditions it needs. Three things have to be true.

---

## The checklist

<div class="grid cards" markdown>

-   :material-file-tree: **1. The right file layout**

    The tooling has to be able to find your app's starting file, and work out
    which framework it is.

    → [Check your file layout](entry-point.md)

-   :material-package-variant: **2. A list of the packages you use**

    A `renv.lock` for R, a `requirements.txt` for Python. This is the step
    people most often skip and most often get stuck on.

    → [R](r-packages.md) · [Python](python-packages.md)

-   :material-database-arrow-right: **3. Data paths that survive the move**

    Your data ends up somewhere different on the server. Your code has to read
    it in a way that still works.

    → [How your app finds its data](data-paths.md)

</div>

Then a short list of [final checks](before-you-upload.md) before you upload.

---

## Why this can't be automated away

It's reasonable to ask why the tooling can't just work this out.

For **R** it largely does — `renv` can scan your source files for
`library()` calls and it's usually right, so the tooling generates a `renv.lock`
for you if you don't supply one. You still get a better result by making one
yourself, because yours records the *versions that actually worked for you*.

For **Python** it genuinely cannot. There is no reliable way to get from
`import cv2` to the package name `opencv-python`, or from `import sklearn` to
`scikit-learn`, or from `import yaml` to `PyYAML`. Guessing wrong produces a
build that fails minutes in, or worse, one that succeeds and installs something
subtly different. So for Dash, Python Shiny and Streamlit a `requirements.txt`
is **required**, and the deployment stops with a clear message if it's missing.

For **data paths**, only you know which strings in your code are file paths.

---

## Start from a clean copy

Before you change anything: make sure your project is in version control, or
take a copy of the folder. Part 2 involves editing your code, and you want to
be able to get back.

If your project is already a Git repository — even one you've never pushed —
you're fine.

!!! tip "Git makes Part 3 easier too"

    If your project is on GitHub or GitLab, the deployment application can
    fetch it directly by URL, which is the smoothest of the three ways to get
    code onto the server. Pushing your prepared project to a repository at the
    end of Part 2 is worth the effort even if the repo is private.

---

Start with → **[Check your file layout](entry-point.md)**
