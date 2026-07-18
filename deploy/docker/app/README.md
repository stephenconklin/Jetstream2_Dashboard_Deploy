# Drop your Shiny project here

Put an R Shiny project directly in this folder — `app.R` (or a `ui.R` +
`server.R` pair), plus any `data/` it reads from — then from the repo root
run:

```bash
./deploy/docker/build_and_run.sh
```

Optional files you can add alongside your app code:

- `renv.lock` — if present, exact package versions are restored from it.
  Otherwise dependencies are auto-detected by scanning your code for
  `library()`/`require()` calls.
- `apt.txt` — one system package per line, for anything your project needs
  beyond what the base R image already provides (e.g. `default-jdk` for
  `rJava`, `imagemagick` for `magick`).

To deploy a project that lives elsewhere instead of copying it here, pass its
path directly: `./deploy/docker/build_and_run.sh /path/to/project`.

To smoke-test the deploy tooling itself before pointing it at a real project,
copy in the bundled example: `cp -r examples/hello-world/* deploy/docker/app/`.

Everything in this folder except this README is gitignored — it's a working
slot, not something to commit.
