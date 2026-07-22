# Detect and install whatever R packages a Shiny project needs, without the
# Dockerfile having to hardcode a package list per project.
#
# - If the project ships an renv.lock, restore exactly those pinned versions.
# - Otherwise, statically scan its .R/.Rmd files for library()/require()/
#   pkg::fn() usage (renv::dependencies() — no prior renv::init() needed)
#   and install whatever the base image doesn't already provide.
args <- commandArgs(trailingOnly = TRUE)
project_dir <- if (length(args) >= 1) args[[1]] else "."

# Many R base images (rocker/geospatial included) point the default "CRAN"
# repo at a Posit Package Manager snapshot frozen on the date the image was
# built. A renv.lock itself also embeds the exact repository URLs active at
# snapshot() time (its top-level "R"$"Repositories" section), and
# renv::restore() prefers that recorded URL over the session's options("repos")
# — so overriding options(repos = ...) alone has no effect on restore. A
# pinned package version released *after* whichever snapshot date is baked
# into either the image or the lockfile would otherwise 404 forever, no
# matter how long you wait. renv.config.repos.override forces renv to ignore
# both and use this rolling mirror for every repo lookup during restore().
options(renv.config.repos.override = "https://cloud.r-project.org")
options(repos = c(CRAN = "https://cloud.r-project.org"))

if (!requireNamespace("renv", quietly = TRUE)) {
  install.packages("renv")
}

lockfile <- file.path(project_dir, "renv.lock")

# install.packages()/renv::restore() print errors but return normally (not an
# R error condition) on partial failure — e.g. a transient CRAN/mirror
# timeout — so retries are driven by checking what's still missing
# afterward, not by catching an exception. Across many different projects,
# transient network hiccups during a multi-package install are common enough
# to be worth a few retries before failing the whole build.
INSTALL_TRIES <- 3
INSTALL_RETRY_WAIT_SEC <- 15

if (file.exists(lockfile)) {
  required <- names(renv::lockfile_read(lockfile)$Packages)
  for (attempt in seq_len(INSTALL_TRIES)) {
    tryCatch(
      renv::restore(project = project_dir, lockfile = lockfile, prompt = FALSE),
      error = function(e) message("renv::restore() attempt failed: ", conditionMessage(e))
    )
    if (length(setdiff(required, rownames(installed.packages()))) == 0) break
    if (attempt < INSTALL_TRIES) {
      message(sprintf("Some packages still missing after attempt %d/%d — retrying in %ds...",
                       attempt, INSTALL_TRIES, INSTALL_RETRY_WAIT_SEC))
      Sys.sleep(INSTALL_RETRY_WAIT_SEC)
    }
  }
} else {
  deps <- renv::dependencies(path = project_dir, progress = FALSE)
  required <- unique(deps$Package)

  # rocker/geospatial's pinned GDAL is fixed at whatever version it shipped
  # with, but CRAN keeps releasing newer terra versions that assume a newer
  # GDAL API (e.g. GDALMDArray::AsClassicDataset()'s 3-arg overload only
  # exists in GDAL >= 3.8) — so blindly installing CRAN-latest terra can
  # start failing to compile here with no change to the deployed project's
  # own code, only to CRAN. Pin known-compatible versions instead of
  # CRAN-latest for packages in this situation; see docs/deployment.md's
  # "Pinning R package versions" section for how these were derived, and
  # update this table if a newer BASE_IMAGE ships a newer GDAL. (In normal
  # operation this branch only runs if a project genuinely has no
  # renv.lock and the build_and_run.sh preflight that would otherwise
  # generate one was bypassed — see generate_lock.R for the usual path.)
  KNOWN_COMPATIBLE_VERSIONS <- list(
    terra = list(min_gdal = "3.8.0", pinned_version = "1.8-5")
  )
  gdal_version <- suppressWarnings(tryCatch(
    system("gdal-config --version", intern = TRUE),
    error = function(e) NA_character_
  ))
  if (length(gdal_version) == 1 && !is.na(gdal_version)) {
    for (pkg in intersect(required, names(KNOWN_COMPATIBLE_VERSIONS))) {
      spec <- KNOWN_COMPATIBLE_VERSIONS[[pkg]]
      if (package_version(gdal_version) < spec$min_gdal) {
        message(sprintf(
          "GDAL %s detected (< %s) -- pinning %s to %s, a version known to compile against it.",
          gdal_version, spec$min_gdal, pkg, spec$pinned_version
        ))
        renv::install(sprintf("%s@%s", pkg, spec$pinned_version), prompt = FALSE)
      }
    }
  }

  for (attempt in seq_len(INSTALL_TRIES)) {
    pkgs <- setdiff(required, rownames(installed.packages()))
    if (length(pkgs) == 0) break
    tryCatch(
      install.packages(pkgs, Ncpus = parallel::detectCores()),
      error = function(e) message("install.packages() attempt failed: ", conditionMessage(e))
    )
    if (length(setdiff(required, rownames(installed.packages()))) == 0) break
    if (attempt < INSTALL_TRIES) {
      message(sprintf("Some packages still missing after attempt %d/%d — retrying in %ds...",
                       attempt, INSTALL_TRIES, INSTALL_RETRY_WAIT_SEC))
      Sys.sleep(INSTALL_RETRY_WAIT_SEC)
    }
  }
}

# install.packages()/renv::restore() print errors but exit 0 on partial
# failure, which would otherwise let `docker build` report success on a
# broken image. Fail loudly instead so the build itself fails.
missing <- setdiff(required, rownames(installed.packages()))
if (length(missing) > 0) {
  stop("Failed to install required package(s): ", paste(missing, collapse = ", "))
}
