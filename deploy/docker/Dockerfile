# Generic single-app Shiny image. Works for any R Shiny project dropped into
# the "app" build-context directory (app.R, or a ui.R/server.R pair, plus
# optional data/, renv.lock, and apt.txt) — see build_and_run.sh.
#
# BASE_IMAGE defaults to bare R; R packages the project needs (including
# `shiny` itself) are auto-detected and installed below. Override BASE_IMAGE
# for projects that need heavier system libraries pre-built, e.g.
# rocker/geospatial for sf/terra/raster, or rocker/shiny-verse for tidyverse.
ARG BASE_IMAGE=rocker/r-ver:4.4.1
FROM ${BASE_IMAGE}

# Shiny Server gives crash-restart and multi-session worker handling that a
# bare `shiny::runApp()` call doesn't provide.
ARG SHINY_SERVER_VERSION=1.5.22.1017
RUN apt-get update && apt-get install -y --no-install-recommends \
      gdebi-core curl \
    && curl -fsSL "https://download3.rstudio.org/ubuntu-18.04/x86_64/shiny-server-${SHINY_SERVER_VERSION}-amd64.deb" -o /tmp/shiny-server.deb \
    && gdebi -n /tmp/shiny-server.deb \
    && rm -f /tmp/shiny-server.deb \
    && rm -rf /var/lib/apt/lists/*

# Headers most CRAN packages need to compile from source — without these,
# even `shiny` itself fails to install on a bare BASE_IMAGE, since its
# dependency httpuv needs libuv/zlib, and common plotting packages
# (ragg/systemfonts/textshaping) need fontconfig/freetype/harfbuzz.
# Anything more specialized (e.g. rJava, GDAL) belongs in the project's
# apt.txt or a heavier BASE_IMAGE override instead of here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libuv1-dev \
      zlib1g-dev \
      libssl-dev \
      libcurl4-openssl-dev \
      libxml2-dev \
      libpng-dev \
      libjpeg-dev \
      libfontconfig1-dev \
      libfreetype6-dev \
      libharfbuzz-dev \
      libfribidi-dev \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Project-specific system libraries (e.g. default-jdk for rJava, imagemagick
# for magick) that BASE_IMAGE doesn't already provide. One package name per
# line in the project's apt.txt; leave it empty if none are needed.
COPY app/apt.txt /tmp/apt.txt
RUN if [ -s /tmp/apt.txt ]; then \
      apt-get update \
      && xargs -a /tmp/apt.txt apt-get install -y --no-install-recommends \
      && rm -rf /var/lib/apt/lists/*; \
    fi

COPY shiny-server.conf /etc/shiny-server/shiny-server.conf

RUN rm -rf /srv/shiny-server/*
COPY app/ /srv/shiny-server/
RUN rm -f /srv/shiny-server/apt.txt

# Auto-detect and install whatever R packages the project actually uses:
# renv.lock if the project ships one (exact pinned versions), otherwise a
# static scan of its library()/require() calls via renv::dependencies().
COPY install_deps.R /tmp/install_deps.R
RUN Rscript /tmp/install_deps.R /srv/shiny-server

RUN chown -R shiny:shiny /srv/shiny-server

EXPOSE 3838
CMD ["/usr/bin/shiny-server"]
