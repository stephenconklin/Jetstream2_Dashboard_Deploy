#!/usr/bin/env bash
# Bare-metal provisioning script for any single R Shiny app on a
# Jetstream2 Ubuntu 22.04 (jammy) instance.
#
# One instance = one app. No Docker, no per-app subpaths: Shiny Server serves
# a single app at "/", and Nginx reverse-proxies port 80 -> 3838 so the app
# is reachable directly in a browser at the instance's fixed IP.
#
# Run as a user with sudo (e.g. the default `exouser` on Jetstream2):
#   sudo APP_REPO_URL=https://github.com/you/your-app.git ./provision_baremetal.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this script with sudo/root." >&2
  exit 1
fi

# --- Configuration -----------------------------------------------------------
APP_REPO_URL="${APP_REPO_URL:-https://github.com/YOUR_ORG/YOUR_APP.git}"
APP_BRANCH="${APP_BRANCH:-main}"
APP_DIR="/srv/shiny-server"
SHINY_SERVER_VERSION="1.5.22.1017"   # check https://posit.co/download/shiny-server/ for latest

# --- System packages ---------------------------------------------------------
apt-get update
apt-get upgrade -y

apt-get install -y --no-install-recommends \
  software-properties-common \
  dirmngr \
  ca-certificates \
  gnupg \
  curl \
  git \
  gdebi-core \
  nginx \
  ufw

# CRAN's R build (Ubuntu's default repo lags several R releases behind)
curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
  | gpg --dearmor -o /usr/share/keyrings/cran-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cran-archive-keyring.gpg] https://cloud.r-project.org/bin/linux/ubuntu jammy-cran40/" \
  > /etc/apt/sources.list.d/cran-r.list

# ubuntugis-unstable carries current GDAL/GEOS/PROJ, which sf/terra/raster
# need — the Ubuntu default repo's versions are too old and fail to build them.
add-apt-repository -y ppa:ubuntugis/ubuntugis-unstable

apt-get update
apt-get install -y --no-install-recommends \
  r-base r-base-dev \
  gdal-bin libgdal-dev \
  libgeos-dev \
  libproj-dev \
  libudunits2-dev \
  libssl-dev \
  libcurl4-openssl-dev \
  libxml2-dev

# --- Shiny Server (open source) ----------------------------------------------
ARCH_SUFFIX="amd64"
TMP_DEB="/tmp/shiny-server.deb"
curl -fsSL "https://download3.rstudio.org/ubuntu-18.04/x86_64/shiny-server-${SHINY_SERVER_VERSION}-${ARCH_SUFFIX}.deb" -o "$TMP_DEB"
gdebi -n "$TMP_DEB"
rm -f "$TMP_DEB"

# --- Deploy the app -----------------------------------------------------------
rm -rf "$APP_DIR"
git clone --branch "$APP_BRANCH" --depth 1 "$APP_REPO_URL" "$APP_DIR"
chown -R shiny:shiny "$APP_DIR"

# --- R packages the app needs -------------------------------------------------
# Auto-detected the same way as the Docker workflow (see install_deps.R):
# restore renv.lock if the app ships one, otherwise scan its library()/
# require() calls and install whatever isn't already present.
Rscript "$(dirname "${BASH_SOURCE[0]}")/docker/install_deps.R" "$APP_DIR"

# --- Shiny Server config: single app at "/" -----------------------------------
cat > /etc/shiny-server/shiny-server.conf <<'EOF'
run_as shiny;

server {
  listen 3838;

  location / {
    app_dir /srv/shiny-server;
    log_dir /var/log/shiny-server;
  }
}
EOF

systemctl enable shiny-server
systemctl restart shiny-server

# --- Nginx: reverse proxy 80 -> 3838 ------------------------------------------
cat > /etc/nginx/sites-available/shiny-app <<'EOF'
server {
  listen 80 default_server;
  server_name _;

  location / {
    proxy_pass http://127.0.0.1:3838;
    proxy_redirect http://127.0.0.1:3838/ $scheme://$host/;
    proxy_http_version 1.1;

    # Required for Shiny's websocket-based reactivity
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 20d;
  }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/shiny-app /etc/nginx/sites-enabled/shiny-app
nginx -t
systemctl enable nginx
systemctl restart nginx

# --- Firewall (defense in depth alongside the Jetstream2 security group) -----
ufw allow OpenSSH
ufw allow 80/tcp
ufw --force enable

echo "Done. App should be reachable at http://<instance-fixed-ip>/"
