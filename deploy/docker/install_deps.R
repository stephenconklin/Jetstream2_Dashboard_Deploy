# Detect and install whatever R packages a Shiny project needs, without the
# Dockerfile having to hardcode a package list per project.
#
# - If the project ships an renv.lock, restore exactly those pinned versions.
# - Otherwise, statically scan its .R/.Rmd files for library()/require()/
#   pkg::fn() usage (renv::dependencies() — no prior renv::init() needed)
#   and install whatever the base image doesn't already provide.
args <- commandArgs(trailingOnly = TRUE)
project_dir <- if (length(args) >= 1) args[[1]] else "."

if (!requireNamespace("renv", quietly = TRUE)) {
  install.packages("renv", repos = "https://cloud.r-project.org")
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
    install.packages(pkgs, repos = "https://cloud.r-project.org", Ncpus = parallel::detectCores())
  }
}

# install.packages()/renv::restore() print errors but exit 0 on partial
# failure, which would otherwise let `docker build` report success on a
# broken image. Fail loudly instead so the build itself fails.
missing <- setdiff(required, rownames(installed.packages()))
if (length(missing) > 0) {
  stop("Failed to install required package(s): ", paste(missing, collapse = ", "))
}
