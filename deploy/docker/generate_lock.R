# Preflight step (R Shiny only): generate a renv.lock for a project that
# doesn't ship one, before the real `docker build` runs. build_and_run.sh
# invokes this via `docker run` against the `deps-base` build stage — the
# same compile environment (apt headers, BASE_IMAGE) the real build will
# use — so a CRAN-latest package that fails to compile against this image's
# system libraries (e.g. terra needing a newer GDAL than the image ships)
# surfaces here, before the real build, instead of buried in `docker build`
# output. It doesn't resolve that kind of failure itself — see
# docs/deployment.md's "Pinning R package versions" section for the manual
# fallback — but once a working set of versions is installed, it locks them
# in so the real build (and every rebuild after) is reproducible.
args <- commandArgs(trailingOnly = TRUE)
project_dir <- if (length(args) >= 1) args[[1]] else "."

# See install_deps.R for why both options are needed: rocker images point
# "CRAN" at a frozen Posit Package Manager snapshot, and renv prefers that
# over options("repos") unless explicitly overridden.
options(renv.config.repos.override = "https://cloud.r-project.org")
options(repos = c(CRAN = "https://cloud.r-project.org"))

if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv")

# Install into an isolated library rather than project_dir's own — this
# script only ever writes renv.lock into the project directory, not a full
# renv/ project scaffold or .Rprofile, so it doesn't leave anything behind
# that could surprise a local RStudio session opened against the project.
lib_dir <- tempfile("renv-lib-")
dir.create(lib_dir)
.libPaths(c(lib_dir, .libPaths()))

deps <- renv::dependencies(path = project_dir, progress = FALSE)
required <- unique(deps$Package)

# install.packages() prints errors but returns normally (not an R error
# condition) on partial failure — e.g. a transient CRAN/mirror timeout — so
# retries are driven by checking what's still missing afterward, matching
# install_deps.R's pattern.
INSTALL_TRIES <- 3
INSTALL_RETRY_WAIT_SEC <- 15
for (attempt in seq_len(INSTALL_TRIES)) {
  pkgs <- setdiff(required, rownames(installed.packages()))
  if (length(pkgs) == 0) break
  tryCatch(
    install.packages(pkgs, lib = lib_dir, Ncpus = parallel::detectCores()),
    error = function(e) message("install.packages() attempt failed: ", conditionMessage(e))
  )
  if (length(setdiff(required, rownames(installed.packages()))) == 0) break
  if (attempt < INSTALL_TRIES) {
    message(sprintf("Some packages still missing after attempt %d/%d — retrying in %ds...",
                     attempt, INSTALL_TRIES, INSTALL_RETRY_WAIT_SEC))
    Sys.sleep(INSTALL_RETRY_WAIT_SEC)
  }
}

missing <- setdiff(required, rownames(installed.packages()))
if (length(missing) > 0) {
  stop("Failed to install required package(s) while generating renv.lock: ", paste(missing, collapse = ", "))
}

renv::snapshot(
  project = project_dir,
  library = lib_dir,
  lockfile = file.path(project_dir, "renv.lock"),
  packages = required,
  prompt = FALSE
)
