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
# built. renv::restore() resolves a lockfile's "CRAN" packages against
# whatever "CRAN" currently means, so a pinned version released *after* that
# frozen snapshot date would otherwise 404 forever, no matter how long you
# wait. Point at the real, rolling CRAN mirror so any pinned version can
# actually be fetched regardless of when it was released relative to the
# base image's build date.
options(repos = c(CRAN = "https://cloud.r-project.org"))

if (!requireNamespace("renv", quietly = TRUE)) {
  install.packages("renv")
}

lockfile <- file.path(project_dir, "renv.lock")

if (file.exists(lockfile)) {
  required <- names(renv::lockfile_read(lockfile)$Packages)
  renv::restore(project = project_dir, lockfile = lockfile, prompt = FALSE)
} else {
  deps <- renv::dependencies(path = project_dir, progress = FALSE)
  required <- unique(deps$Package)
  pkgs <- setdiff(required, rownames(installed.packages()))
  if (length(pkgs) > 0) {
    install.packages(pkgs, Ncpus = parallel::detectCores())
  }
}

# install.packages()/renv::restore() print errors but exit 0 on partial
# failure, which would otherwise let `docker build` report success on a
# broken image. Fail loudly instead so the build itself fails.
missing <- setdiff(required, rownames(installed.packages()))
if (length(missing) > 0) {
  stop("Failed to install required package(s): ", paste(missing, collapse = ", "))
}
