#!/usr/bin/env bash
#
# Provision a fresh Jetstream2 instance to host a dashboard.
#
#   sudo ./deploy/bootstrap.sh                        # provision the host
#   sudo ./deploy/bootstrap.sh /path/to/project       # provision, then deploy
#   sudo ./deploy/bootstrap.sh --check                # read-only status
#   sudo ./deploy/bootstrap.sh --remove-proxy         # roll back to no nginx
#   sudo ./deploy/bootstrap.sh --set-domain dash.example.org [--email you@example.org]
#                                                     # serve HTTPS under that name
#   sudo ./deploy/bootstrap.sh --clear-domain         # back to http://<IP>/
#
# Target: a fresh Ubuntu 22.04/24.04 Jetstream2 instance. Idempotent — every
# step detects existing state and skips, so re-running is the normal way to
# apply a configuration change from deploy/deploy.env.
#
# ---------------------------------------------------------------------------
# What this is, and what build_and_run.sh is
# ---------------------------------------------------------------------------
# They provision different things and neither replaces the other:
#
#   bootstrap.sh      the HOST — Docker, swap, nginx, TLS, firewall, autoheal.
#                     Run once per instance, as root.
#   build_and_run.sh  the APP  — builds and runs whatever project a researcher
#                     drops in. Run every time the code changes, as the
#                     ordinary user.
#
# bootstrap.sh never contains framework knowledge: which port a Streamlit app
# listens on, where data gets mounted, how R dependencies are resolved all
# stay in build_and_run.sh and lib/. What bootstrap decides is only *where the
# container publishes*, and it says so by writing one small state file that
# build_and_run.sh reads — see deploy/lib/proxy.sh.
#
# ---------------------------------------------------------------------------
# What this does NOT do
# ---------------------------------------------------------------------------
# It does not provision your data. Research datasets are routinely tens of GB
# and belong on an attached Jetstream2 volume, not in a git clone or a Docker
# image. Attach and mount the volume first; see docs/user-guide/reference/deployment.md.
#
# Lets `shellcheck -x` resolve both `source` lines below (lib/proxy.sh and
# deploy.env) relative to this script rather than the caller's cwd. Has to sit
# before the first command in the file to apply file-wide — see the note in
# build_and_run.sh's header about this repo's two linter conventions.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# For PROXY_ENV_FILE and AUTOHEAL_CONTAINER. Sourced rather than restated so
# the path bootstrap WRITES and the path build_and_run.sh READS cannot drift.
source "$SCRIPT_DIR/lib/proxy.sh"
# For LOW_DISK_GB and the free-space helpers, shared with manage.sh so the
# threshold warned about here and the one the GUI reports are the same number.
source "$SCRIPT_DIR/lib/disk.sh"
# For check_domain(), the read-only "does this name point here?" test the
# desktop app also runs before asking for HTTPS.
source "$SCRIPT_DIR/lib/domain.sh"

MODE="full"
ASSUME_YES=0
PROJECT_DIR=""
SET_DOMAIN=""
SET_EMAIL=""
CLEAR_DOMAIN=0
# --set-domain and --email take a value, so they are read in a first pass;
# everything else keeps the single-word handling below.
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --set-domain)  [[ $# -ge 2 ]] || { echo "--set-domain needs a name" >&2; exit 2; }
                   SET_DOMAIN="$2"; shift 2 ;;
    --email)       [[ $# -ge 2 ]] || { echo "--email needs an address" >&2; exit 2; }
                   SET_EMAIL="$2"; shift 2 ;;
    --clear-domain) CLEAR_DOMAIN=1; shift ;;
    *)             args+=("$1"); shift ;;
  esac
done
for arg in "${args[@]+"${args[@]}"}"; do
  case "$arg" in
    --check)         MODE="check" ;;
    --remove-proxy)  MODE="remove-proxy" ;;
    --yes|-y)        ASSUME_YES=1 ;;
    # -E, not a basic-regex `\?`: BSD sed (macOS, where this repo is developed)
    # matches that literally rather than as "optional".
    --help|-h)       sed -n '2,16p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    -*)              echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
    *)               PROJECT_DIR="$arg" ;;
  esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
  C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_HEAD=""; C_OFF=""
fi
step() { printf '\n%s==> %s%s\n' "$C_HEAD" "$*" "$C_OFF"; }
ok()   { printf '    %sOK%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
skip() { printf '    ---  %s (already done, skipping)\n' "$*"; }
warn() { printf '    %sWARN%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '\n%sFAILED%s %s\n\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
step "Preflight"

[[ $EUID -eq 0 ]] || die "Must run as root:  sudo $0${*:+ $*}"

# The invoking (non-root) user owns the checkout and should own anything this
# script creates on their behalf. Deploying as root would leave root-owned
# files scattered through a researcher's project directory.
# pkexec, the desktop app's fallback when passwordless sudo isn't available,
# reports the caller as a uid rather than SUDO_USER.
REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" && -n "${PKEXEC_UID:-}" ]]; then
  REAL_USER="$(id -nu "$PKEXEC_UID" 2>/dev/null || true)"
fi
REAL_USER="${REAL_USER:-root}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[[ -n "$REAL_HOME" ]] || die "Cannot resolve a home directory for user '$REAL_USER'"
ok "running as root on behalf of '$REAL_USER'"

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "Tested on Ubuntu; found '${ID:-unknown}'. Continuing."
  ok "OS: ${PRETTY_NAME:-unknown}"
fi

# Defaults live here, not only in the example file: a bootstrap run with no
# deploy.env at all must still do the right thing for a plain instance. The
# example file documents them; this is what actually applies.
SERVER_NAME=""
CERTBOT_EMAIL=""
ENABLE_TLS="yes"
# ACME directory to request certificates from. Empty means Let's Encrypt's
# production service. Set to Let's Encrypt staging to rehearse, or to a local
# Pebble server in testing (with REQUESTS_CA_BUNDLE pointing at its CA).
CERTBOT_SERVER=""
APP_HOST_PORT="8080"
CLIENT_MAX_BODY_SIZE="100m"
RATE_LIMIT="30r/s"
RATE_BURST="200"
CONN_LIMIT="32"
PROXY_TIMEOUT="3600s"
SWAP_SIZE="2G"
ENABLE_AUTOHEAL="yes"
ENABLE_UFW="no"
PROTECT_VNC="yes"

ENV_FILE="$SCRIPT_DIR/deploy.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=deploy.env.example
  . "$ENV_FILE"
  set +a
  ok "loaded $ENV_FILE"
else
  ok "no deploy.env — using built-in defaults (copy deploy.env.example to change them)"
fi

# Names are case-insensitive, and certbot and nginx both want them lower-case.
SERVER_NAME="$(printf '%s' "$SERVER_NAME" | tr '[:upper:]' '[:lower:]')"

[[ "$APP_HOST_PORT" =~ ^[0-9]+$ ]] || die "APP_HOST_PORT must be a port number, got '$APP_HOST_PORT'"
[[ "$APP_HOST_PORT" != "80" ]] || die "APP_HOST_PORT cannot be 80 — nginx needs that port."

# Let's Encrypt cannot issue for a bare IP. Work that out now rather than
# letting certbot fail two thirds of the way through an otherwise fine run.
# An email is optional: Let's Encrypt no longer sends expiry reminders, and
# renewal is automatic, so it's only a contact address on the account.
TLS_OK="no"
if [[ -n "$SERVER_NAME" && "$ENABLE_TLS" == "yes" ]]; then
  if [[ "$SERVER_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "SERVER_NAME is a bare IP — Let's Encrypt cannot issue for IPs. TLS skipped."
  elif ! domain_name_is_valid "$SERVER_NAME"; then
    warn "SERVER_NAME='$SERVER_NAME' isn't a valid domain name. TLS skipped."
  else
    TLS_OK="yes"
  fi
fi

PROXY_STATE_FILE="$PROXY_ENV_FILE"
VNC_FIREWALL_BIN="/usr/local/libexec/dashboard-deploy-vnc-firewall.sh"
VNC_FIREWALL_UNIT="dashboard-deploy-vnc-firewall.service"
NGINX_SITE="/etc/nginx/sites-available/dashboard"
NGINX_TLS_SNIPPET="/etc/nginx/snippets/dashboard-tls.conf"
MAINTENANCE_ROOT="/var/www/dashboard-deploy"
CERTBOT_RELOAD_HOOK="/etc/letsencrypt/renewal-hooks/deploy/dashboard-deploy-reload"

# Whether a certificate for SERVER_NAME is on disk, i.e. whether the site
# should be rendered for HTTPS. The decision is the certificate's existence,
# not the setting alone: a name whose certificate request failed keeps the
# plain HTTP site, so the dashboard never ends up half-switched.
tls_cert_ready() {
  [[ -n "$SERVER_NAME" && "$ENABLE_TLS" == "yes" \
     && -s "/etc/letsencrypt/live/$SERVER_NAME/fullchain.pem" \
     && -s "/etc/letsencrypt/live/$SERVER_NAME/privkey.pem" ]]
}

# Render the nginx site for "http" (today's config, byte for byte, which is
# what every instance without a domain name keeps) or "https" (the same
# server block on 443 with the TLS snippet, plus a port-80 block that
# redirects). Writes $NGINX_SITE and, for https, $NGINX_TLS_SNIPPET.
render_nginx_site() {
  local mode="$1" listen listen6 listen6_80 tls_include_expr
  # Binding [::] on a host with IPv6 disabled doesn't degrade — nginx fails to
  # start outright. Render those lines as comments there instead.
  local have_ipv6=0
  [[ -e /proc/net/if_inet6 ]] && have_ipv6=1

  if [[ "$mode" == "https" ]]; then
    listen="listen 443 ssl;"
    if [[ "$have_ipv6" -eq 1 ]]; then
      listen6="listen [::]:443 ssl;"
      listen6_80="listen [::]:80;"
    else
      listen6="# listen [::]:443 ssl;  (IPv6 unavailable on this host)"
      listen6_80="# listen [::]:80;  (IPv6 unavailable on this host)"
    fi
    tls_include_expr="s|__TLS_INCLUDE__|include $NGINX_TLS_SNIPPET;|"
    install -d -m 0755 "$(dirname "$NGINX_TLS_SNIPPET")"
    sed -e "s|__SERVER_NAME__|$SERVER_NAME|g" \
      "$SCRIPT_DIR/nginx/dashboard-tls.conf.template" > "$NGINX_TLS_SNIPPET"
  else
    listen="listen 80;"
    if [[ "$have_ipv6" -eq 1 ]]; then
      listen6="listen [::]:80;"
    else
      listen6="# listen [::]:80;  (IPv6 unavailable on this host)"
    fi
    # The marker line goes entirely, so the HTTP site is identical to what
    # this template rendered before HTTPS support existed.
    tls_include_expr="/__TLS_INCLUDE__/d"
  fi

  # `|` as the sed delimiter, because RATE_LIMIT contains a slash ("30r/s").
  sed -e "s|__LISTEN__|$listen|g" \
      -e "$tls_include_expr" \
      -e "s|__SERVER_NAME__|${SERVER_NAME:-_}|g" \
      -e "s|__LISTEN_IPV6__|$listen6|g" \
      -e "s|__APP_HOST_PORT__|$APP_HOST_PORT|g" \
      -e "s|__CLIENT_MAX_BODY_SIZE__|$CLIENT_MAX_BODY_SIZE|g" \
      -e "s|__RATE_LIMIT__|$RATE_LIMIT|g" \
      -e "s|__RATE_BURST__|$RATE_BURST|g" \
      -e "s|__CONN_LIMIT__|$CONN_LIMIT|g" \
      -e "s|__PROXY_TIMEOUT__|$PROXY_TIMEOUT|g" \
      -e "s|__MAINTENANCE_ROOT__|$MAINTENANCE_ROOT|g" \
      "$SCRIPT_DIR/nginx/dashboard.conf.template" > "$NGINX_SITE"

  if [[ "$mode" == "https" ]]; then
    sed -e "s|__SERVER_NAME__|$SERVER_NAME|g" \
        -e "s|__LISTEN_IPV6_80__|$listen6_80|g" \
        "$SCRIPT_DIR/nginx/dashboard-http-redirect.conf.template" >> "$NGINX_SITE"
  fi
}

# Ask Let's Encrypt (or CERTBOT_SERVER) for a certificate for $1, answering
# its challenge through nginx, which must be running. certbot only obtains the
# certificate — `certonly`, never its installer — so it doesn't edit the site;
# render_nginx_site decides how it's served. Against production, a staging
# dry run goes first, so a name that can't be validated fails without
# spending Let's Encrypt's five-failures-an-hour allowance. Returns certbot's
# status; its own output says why.
obtain_certificate() {
  local name="$1" email="${2:-}"
  local -a common=(certonly --nginx -d "$name" --cert-name "$name"
                   --non-interactive --agree-tos --keep-until-expiring)
  if [[ -n "$email" ]]; then
    common+=(-m "$email")
  else
    common+=(--register-unsafely-without-email)
  fi
  if [[ -n "$CERTBOT_SERVER" ]]; then
    common+=(--server "$CERTBOT_SERVER")
  else
    certbot "${common[@]}" --dry-run || return 1
  fi
  certbot "${common[@]}"
}

# Set KEY="VALUE" in deploy/deploy.env, creating it from the example when it
# doesn't exist yet. The file stays owned by whoever owns the checkout, since
# it's edited by hand too. Values are validated by the callers before they
# get here: the file is sourced by bash.
set_deploy_env_key() {
  local key="$1" value="$2" owner
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$SCRIPT_DIR/deploy.env.example" "$ENV_FILE"
  fi
  if grep -qE "^[[:space:]]*${key}=" "$ENV_FILE"; then
    sed -i -E "s|^[[:space:]]*${key}=.*|${key}=\"${value}\"|" "$ENV_FILE"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$ENV_FILE"
  fi
  owner="$(stat -c '%U:%G' "$SCRIPT_DIR" 2>/dev/null || true)"
  [[ -n "$owner" ]] && chown "$owner" "$ENV_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# --set-domain / --clear-domain: change which name the site is served under,
# then fall through to the normal provision, which renders the site to match.
#
# --set-domain obtains the certificate BEFORE writing anything, so a name
# that doesn't point here yet, or a certificate request that fails, stops
# with every setting as it was and the dashboard still on its old address.
# That's what lets the desktop app offer it as one button.
# ---------------------------------------------------------------------------
if [[ -n "$SET_DOMAIN" && "$CLEAR_DOMAIN" -eq 1 ]]; then
  die "--set-domain and --clear-domain can't be used together."
fi
if [[ ( -n "$SET_DOMAIN" || "$CLEAR_DOMAIN" -eq 1 ) && "$MODE" != "full" ]]; then
  die "--set-domain and --clear-domain can't be combined with --check or --remove-proxy."
fi
if [[ -n "$SET_DOMAIN" ]]; then
  step "Domain name"
  check_domain "$SET_DOMAIN"
  [[ "$DOMAIN_OK" -eq 1 ]] || die "$(domain_reason_text)
       Nothing has been changed."
  ok "$(domain_reason_text)"
  if [[ -n "$SET_EMAIL" && ! "$SET_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+$ ]]; then
    die "'$SET_EMAIL' doesn't look like an email address. Nothing has been changed."
  fi
  if ! command -v nginx >/dev/null 2>&1 || ! systemctl is-active --quiet nginx; then
    die "nginx isn't running here yet. Run 'sudo $0' once to provision the
       host, then set the domain. Nothing has been changed."
  fi
  command -v certbot >/dev/null 2>&1 \
    || die "certbot isn't installed yet. Run 'sudo $0' once to provision the
       host, then set the domain. Nothing has been changed."
  if [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    ok "a certificate for $DOMAIN is already here"
  elif obtain_certificate "$DOMAIN" "$SET_EMAIL"; then
    ok "certificate issued for $DOMAIN"
  else
    die "Couldn't get a certificate for $DOMAIN (certbot's reason is above).
       Usual causes: the DNS record changed in the last hour and Let's Encrypt
       still sees the old one, or port 80 is blocked in the Jetstream2 security
       group. Nothing has been changed; the dashboard is still on its old address."
  fi
  set_deploy_env_key SERVER_NAME "$DOMAIN"
  [[ -n "$SET_EMAIL" ]] && set_deploy_env_key CERTBOT_EMAIL "$SET_EMAIL"
  SERVER_NAME="$DOMAIN"
  [[ -n "$SET_EMAIL" ]] && CERTBOT_EMAIL="$SET_EMAIL"
  TLS_OK="yes"
  ok "deploy.env now names $DOMAIN — serving it over HTTPS below"
elif [[ "$CLEAR_DOMAIN" -eq 1 ]]; then
  step "Domain name"
  set_deploy_env_key SERVER_NAME ""
  SERVER_NAME=""
  TLS_OK="no"
  ok "domain name cleared — the site goes back to http://<this server's IP>/ below
         (any certificate is kept, so setting the name again is quick)"
fi

# ---------------------------------------------------------------------------
# --check: report and stop, changing nothing
# ---------------------------------------------------------------------------
if [[ "$MODE" == "check" ]]; then
  step "Host"
  for c in docker nginx; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c installed"; else warn "$c NOT installed"; fi
  done
  if docker buildx version >/dev/null 2>&1; then
    ok "BuildKit installed (buildx $(docker buildx version | awk '{print $2}'))"
  elif command -v docker >/dev/null 2>&1; then
    warn "BuildKit NOT installed — builds use the slow legacy builder; re-run bootstrap.sh"
  fi
  command -v systemctl >/dev/null 2>&1 && \
    echo "    ---  nginx service: $(systemctl is-active nginx 2>/dev/null || echo inactive)"
  if [[ -x "$VNC_FIREWALL_BIN" && "$("$VNC_FIREWALL_BIN" status 2>/dev/null)" == "active" ]]; then
    ok "desktop VNC ports closed to the internet (only this host and Docker)"
  elif ss -tln 2>/dev/null | grep -qE '0\.0\.0\.0:59(0[0-9]|10) '; then
    warn "a VNC port is listening on every address with nothing restricting it — re-run bootstrap.sh"
  fi
  echo "    ---  swap: $(swapon --show=SIZE --noheadings 2>/dev/null | tr '\n' ' ' || echo none)"
  echo "    ---  root disk: $(df -h / | awk 'NR==2{print $5" used, "$4" free"}')"

  step "Proxy state"
  if [[ -f "$PROXY_STATE_FILE" ]]; then
    ok "$PROXY_STATE_FILE"
    sed 's/^/    ---  /' "$PROXY_STATE_FILE"
  else
    warn "no $PROXY_STATE_FILE — the app publishes directly on port 80"
  fi

  step "HTTPS"
  if [[ -z "$SERVER_NAME" ]]; then
    echo "    ---  no domain name set — serving http://<this server's IP>/"
  elif tls_cert_ready; then
    expires="$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$SERVER_NAME/fullchain.pem" 2>/dev/null | cut -d= -f2 || true)"
    ok "certificate for $SERVER_NAME${expires:+, valid until $expires} (renews automatically)"
    if grep -q '^PUBLIC_SCHEME=https' "$PROXY_STATE_FILE" 2>/dev/null; then
      ok "serving https://$SERVER_NAME/"
    else
      warn "a certificate is here but the site isn't using it yet — re-run bootstrap.sh"
    fi
  else
    warn "$SERVER_NAME is set but has no certificate yet, so the site is plain HTTP.
         Check it with: ./deploy/lib/domain.sh $SERVER_NAME"
  fi

  step "Listening sockets"
  # The security-critical line: anything on 0.0.0.0 other than nginx means an
  # app server is exposed to the internet directly.
  ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:'"$APP_HOST_PORT"' ' | sed 's/^/    ---  /' || \
    echo "    ---  (nothing listening on 80/443/$APP_HOST_PORT)"

  step "Application"
  if command -v docker >/dev/null 2>&1; then
    docker ps -a --format '    ---  {{.Names}}  {{.Status}}  {{.Ports}}' || true
    # manage.sh does the real diagnosis; no point reimplementing it here.
    if [[ -x "$SCRIPT_DIR/manage.sh" ]]; then
      echo
      sudo -u "$REAL_USER" "$SCRIPT_DIR/manage.sh" health 2>/dev/null || \
        "$SCRIPT_DIR/manage.sh" health || true
    fi
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --remove-proxy: roll back to publishing the container directly on port 80
#
# The rollback path exists because "put nginx in front" is the kind of change
# that is easy to make and, without this, fiddly to undo at exactly the moment
# something is broken and the instance is remote.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "remove-proxy" ]]; then
  step "Removing the nginx front end"
  rm -f "$PROXY_STATE_FILE"
  ok "deleted $PROXY_STATE_FILE — the next deploy publishes on 0.0.0.0:80"
  rm -f /etc/nginx/sites-enabled/dashboard
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop nginx >/dev/null 2>&1 || true
    systemctl disable nginx >/dev/null 2>&1 || true
    ok "nginx stopped and disabled (still installed; not uninstalled)"
  fi
  docker rm -f "$AUTOHEAL_CONTAINER" >/dev/null 2>&1 && ok "autoheal removed" || true
  cat <<EOF

    The host is back to the pre-proxy layout, but the running container is
    still bound to 127.0.0.1:$APP_HOST_PORT — nothing rebinds it in place.
    Re-publish to move it back onto port 80:

      ./deploy/build_and_run.sh /path/to/your/project

EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# Host packages
# ---------------------------------------------------------------------------
step "Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# iproute2 provides `ss`, used above and by the port-conflict check below.
apt-get install -y -qq ca-certificates curl git gnupg lsb-release iproute2 >/dev/null
ok "base packages present"

step "Docker Engine"
if command -v docker >/dev/null 2>&1; then
  skip "docker"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck disable=SC1091  # /etc/os-release exists on the target, not here
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null
  ok "Docker installed"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
DOCKER_GROUP_PENDING=0
if [[ "$REAL_USER" != "root" ]] && ! id -nG "$REAL_USER" | grep -qw docker; then
  usermod -aG docker "$REAL_USER"
  DOCKER_GROUP_PENDING=1
  warn "added '$REAL_USER' to the docker group — they must log out and back in for it to apply"
fi
ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"

# ---------------------------------------------------------------------------
# BuildKit, checked separately from Docker itself because it's the half that
# goes missing: Jetstream2's images ship Ubuntu's docker.io, so the step above
# skips, and docker.io leaves buildx out. Without it `docker build` falls back
# to the deprecated legacy builder, which on Docker 29's containerd image
# store re-processes the whole base image on every Dockerfile step — about
# 75 s each even for EXPOSE, so a republish where every step is cached still
# takes 7 minutes, and an R build twice as long as it should. The plugin has
# to come from the same family as the engine: Docker's own packages pair with
# docker-buildx-plugin, Ubuntu's with docker-buildx, and mixing the two
# conflicts. Not fatal when it can't be added: builds work, just slowly.
step "BuildKit"
if docker buildx version >/dev/null 2>&1; then
  skip "buildx $(docker buildx version | awk '{print $2}')"
else
  buildx_pkg=""
  if dpkg -s docker-ce >/dev/null 2>&1; then
    buildx_pkg="docker-buildx-plugin"
  elif dpkg -s docker.io >/dev/null 2>&1; then
    buildx_pkg="docker-buildx"
  fi
  if [[ -n "$buildx_pkg" ]] && apt-get install -y -qq "$buildx_pkg" >/dev/null \
     && docker buildx version >/dev/null 2>&1; then
    ok "installed $buildx_pkg (buildx $(docker buildx version | awk '{print $2}'))"
  else
    buildx_why="couldn't tell how Docker was installed"
    [[ -n "$buildx_pkg" ]] && buildx_why="$buildx_pkg didn't install"
    warn "BuildKit not added ($buildx_why). Builds still work, but slowly.
         Install the buildx plugin that matches how Docker was installed here,
         then check with: docker buildx version"
  fi
fi

# ---------------------------------------------------------------------------
step "Swapfile (${SWAP_SIZE})"
if [[ "$SWAP_SIZE" == "0" ]]; then
  skip "disabled in deploy.env"
elif swapon --show 2>/dev/null | grep -q '/swapfile'; then
  skip "/swapfile active"
else
  # fallocate fails on some filesystems; dd always works, just slowly.
  fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || \
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "swap enabled and recorded in /etc/fstab"
fi

# ---------------------------------------------------------------------------
# Disk space
#
# Reported here rather than left to fail later, because running out of it
# mid-build is one of the least legible failures this tool can produce: the
# error surfaces as a compile or extraction error hundreds of lines into a
# build log, naming a file rather than the disk. An R geospatial image is
# ~6-8GB on top of a ~4.5GB rocker/geospatial base, and Docker's build cache
# grows with every rebuild on top of that.
#
# A warning, not a hard failure: the threshold is a rule of thumb, the exact
# need depends entirely on the project, and the Python frameworks are far
# lighter than the R ones. Refusing to provision a host over it would be
# wrong.
# ---------------------------------------------------------------------------
step "Disk space"
# An unparseable answer means `df` did not support these flags, not that the
# disk is full. Say nothing rather than warn about "0GB free", which would be
# alarming and wrong.
FREE_GB="$(disk_free_gb)"
if [[ -z "$FREE_GB" ]]; then
  skip "could not read free space on /"
elif [[ "$FREE_GB" -lt "$LOW_DISK_GB" ]]; then
  warn "only ${FREE_GB}GB free on / — an R geospatial build can want more than that.
         Reclaim space before publishing if a build fails partway:
           ./deploy/manage.sh disk      # see where it has gone
           ./deploy/manage.sh cleanup   # remove leftover layers and the build cache
         Both are also in the desktop application's Manage tab. A stale dashboard
         image is often the largest single item, and is safe to remove because
         the next publish rebuilds it."
else
  ok "${FREE_GB}GB free on /"
fi

# ---------------------------------------------------------------------------
# Proxy state file — written BEFORE nginx, so that if anything below fails,
# a subsequent build_and_run.sh still binds loopback rather than racing nginx
# for port 80.
# ---------------------------------------------------------------------------
step "Proxy state file"
install -d -m 0755 "$(dirname "$PROXY_STATE_FILE")"
cat > "$PROXY_STATE_FILE" <<EOF
# Written by deploy/bootstrap.sh — do not edit by hand; re-run bootstrap.
#
# Read by deploy/lib/proxy.sh. Its presence is what tells build_and_run.sh to
# publish the app container on loopback behind nginx instead of directly on
# 0.0.0.0:80. Deleting it (or running bootstrap.sh --remove-proxy) reverts to
# direct publication on the next deploy.
APP_BIND_ADDR=127.0.0.1
APP_HOST_PORT=$APP_HOST_PORT
SERVER_NAME=$SERVER_NAME
PUBLIC_SCHEME=http
EOF
chmod 0644 "$PROXY_STATE_FILE"
ok "$PROXY_STATE_FILE (app -> 127.0.0.1:$APP_HOST_PORT)"

# ---------------------------------------------------------------------------
# nginx — install and validate, but do NOT start
#
# Everything in this step is non-destructive, and that is the point of where
# it sits. On an instance that is already serving a dashboard, the container
# still holds port 80 at this moment; taking it down is the next step. Doing
# all the fallible work first — the package install, rendering the template,
# `nginx -t` — means a bad config or a failed download stops the script while
# the old dashboard is still up and serving, rather than after it has been
# removed. Downtime is then just the gap between the next two steps.
#
# nginx must not start during `apt-get install`, or its postinst fails trying
# to bind the port the dashboard is still using — which leaves dpkg
# half-configured and needing manual repair. policy-rc.d returning 101 is
# Debian's own mechanism for exactly this: it tells the maintainer scripts
# not to start services, and is removed again immediately afterwards.
# ---------------------------------------------------------------------------
step "nginx reverse proxy"
if command -v nginx >/dev/null 2>&1; then
  skip "nginx installed"
else
  POLICY_RC="/usr/sbin/policy-rc.d"
  POLICY_RC_EXISTED=0
  [[ -e "$POLICY_RC" ]] && POLICY_RC_EXISTED=1
  if [[ "$POLICY_RC_EXISTED" -eq 0 ]]; then
    printf '#!/bin/sh\nexit 101\n' > "$POLICY_RC"
    chmod 0755 "$POLICY_RC"
  fi
  apt-get install -y -qq nginx >/dev/null
  [[ "$POLICY_RC_EXISTED" -eq 0 ]] && rm -f "$POLICY_RC"
  ok "nginx installed (not started yet — port 80 is still the dashboard's)"
fi

# certbot is installed whether or not a domain is configured, so an image
# built from this host already has it and the desktop app's "use this name"
# needs no apt-get (or working mirror) at click time. Inert without a name:
# no certificate, nothing for its renewal timer to do. After nginx, not with
# the base packages, because python3-certbot-nginx can pull nginx in, and
# nginx must not be installed or started outside the policy-rc.d guard above.
if command -v certbot >/dev/null 2>&1; then
  skip "certbot installed"
else
  apt-get install -y -qq --no-install-recommends certbot python3-certbot-nginx >/dev/null
  ok "certbot installed (used only if a domain name is set)"
fi
# Reload nginx whenever a renewal puts new certificate files in place: nginx
# reads them only at start or reload, so without this a renewed certificate
# would sit unused until it was the old one that expired.
install -d -m 0755 "$(dirname "$CERTBOT_RELOAD_HOOK")"
printf '#!/bin/sh\n# Installed by deploy/bootstrap.sh: pick up a renewed certificate.\nsystemctl reload nginx\n' \
  > "$CERTBOT_RELOAD_HOOK"
chmod 0755 "$CERTBOT_RELOAD_HOOK"

install -d -m 0755 "$MAINTENANCE_ROOT/_deploy"
install -m 0644 "$SCRIPT_DIR/nginx/unavailable.html" "$MAINTENANCE_ROOT/_deploy/unavailable.html"
ok "maintenance page at $MAINTENANCE_ROOT/_deploy/unavailable.html"

# HTTPS only once a certificate exists; otherwise today's HTTP site exactly.
if tls_cert_ready; then
  SITE_MODE="https"
else
  SITE_MODE="http"
fi
if [[ -e /proc/net/if_inet6 ]]; then
  ok "IPv6 available — listening on it too"
else
  warn "IPv6 unavailable — nginx will listen on IPv4 only"
fi
render_nginx_site "$SITE_MODE"
ok "site rendered for $SITE_MODE${SERVER_NAME:+ ($SERVER_NAME)}"

rm -f /etc/nginx/sites-enabled/default
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/dashboard

# The validation gate. `nginx -t` parses the config without binding anything,
# so it is safe to run while the dashboard still owns port 80 — and failing
# here costs nothing, because nothing has been taken down yet.
nginx -t 2>/dev/null || { nginx -t; die "nginx config test failed — nothing has been taken offline."; }
ok "config valid ($NGINX_SITE)"

# ---------------------------------------------------------------------------
# Cutover: free port 80, then start nginx on it
#
# This is the only moment of downtime in the whole transition, and everything
# that could fail has already been done. On an instance already serving a
# dashboard, port 80 is held by the app container itself, so freeing it means
# taking the dashboard offline — not something to do behind someone's back.
# It comes back when it is re-published, which this script does for you if you
# passed a project directory.
# ---------------------------------------------------------------------------
step "Cutover"
PORT80_CONTAINERS="$(containers_publishing_host_port 80 | tr '\n' ' ')"
PORT80_CONTAINERS="${PORT80_CONTAINERS% }"
if [[ -n "$PORT80_CONTAINERS" ]]; then
  # shellcheck disable=SC2086
  PORT80_NAMES="$(container_names_for_ids $PORT80_CONTAINERS)"
  echo
  echo "    A container is bound to host port 80: $PORT80_NAMES"
  echo "    nginx needs that port, so it has to be removed and re-published"
  echo "    behind the proxy. The image is kept, so re-publishing is a fast"
  echo "    cached rebuild rather than a full one."
  echo
  if [[ "$ASSUME_YES" -eq 0 && -z "$PROJECT_DIR" && -t 0 ]]; then
    echo "    You did not pass a project directory, so nothing will re-publish"
    echo "    it automatically — you will need to run build_and_run.sh yourself"
    echo "    afterwards. Ctrl-C now and re-run as:"
    echo "      sudo $0 /path/to/your/project"
    echo
    read -rp "    Take the dashboard offline and continue anyway? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "Stopped at your request. Nothing has been taken offline."
  elif [[ "$ASSUME_YES" -eq 0 && -z "$PROJECT_DIR" ]]; then
    die "A container holds port 80 and there is no terminal to confirm removing it.
       Re-run with a project directory (which re-publishes automatically):
         sudo $0 /path/to/your/project
       or confirm non-interactively:
         sudo $0 --yes"
  fi
  # shellcheck disable=SC2086
  docker rm -f $PORT80_CONTAINERS >/dev/null
  ok "removed $PORT80_NAMES — the dashboard is offline from here until it re-publishes"
elif ss -tlnp 2>/dev/null | grep -q ':80 ' && ! ss -tlnp 2>/dev/null | grep ':80 ' | grep -q nginx; then
  echo
  ss -tlnp 2>/dev/null | grep ':80 ' | sed 's/^/    /' || true
  die "Port 80 is held by something other than nginx or a container (shown above).
       Stop that service and re-run. Nothing has been taken offline."
else
  ok "port 80 free"
fi

systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
ok "nginx serving :80 -> 127.0.0.1:$APP_HOST_PORT"

sleep 1
probe="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1/_deploy/health || echo 000)"
if [[ "$probe" == "200" ]]; then
  ok "http://127.0.0.1/_deploy/health -> 200"
else
  warn "nginx health probe -> $probe (see /var/log/nginx/dashboard.error.log)"
fi
# The state file was written above with PUBLIC_SCHEME=http; it says https only
# now that nginx is actually serving it, which is what manage.sh and the app
# read to show https://<name>/ as the address.
if [[ "$SITE_MODE" == "https" ]]; then
  sed -i 's|^PUBLIC_SCHEME=.*|PUBLIC_SCHEME=https|' "$PROXY_STATE_FILE"
fi

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------
step "TLS"
if [[ "$TLS_OK" != "yes" ]]; then
  skip "no domain name configured — serving http://<this server's IP>/"
elif [[ "$SITE_MODE" == "https" ]]; then
  ok "serving https://$SERVER_NAME/ (certificate in /etc/letsencrypt/live/$SERVER_NAME/)"
else
  # A name is configured but there's no certificate yet: the deploy.env route
  # rather than --set-domain. Check DNS first, then ask; either failing leaves
  # the HTTP site running.
  check_domain "$SERVER_NAME"
  if [[ "$DOMAIN_OK" -ne 1 ]]; then
    warn "$(domain_reason_text)
         Serving plain HTTP until it does; re-run bootstrap.sh then."
  elif ! obtain_certificate "$SERVER_NAME" "$CERTBOT_EMAIL"; then
    warn "certbot couldn't get a certificate (its reason is above) — the site
         stays on plain HTTP. Usual causes: DNS changed in the last hour, or
         port 80 is blocked in the Jetstream2 security group. Re-run bootstrap.sh."
  else
    render_nginx_site https
    if nginx -t 2>/dev/null; then
      systemctl reload nginx
      sed -i 's|^PUBLIC_SCHEME=.*|PUBLIC_SCHEME=https|' "$PROXY_STATE_FILE"
      SITE_MODE="https"
      ok "certificate issued; serving https://$SERVER_NAME/, with http:// redirecting"
    else
      # Shouldn't happen, but never leave a config nginx won't load.
      render_nginx_site http
      warn "the HTTPS config failed nginx's own check, so the site stays on plain
         HTTP. See: sudo nginx -t"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Autoheal
# ---------------------------------------------------------------------------
step "Autoheal sidecar"
if [[ "$ENABLE_AUTOHEAL" == "yes" ]]; then
  # Docker does not act on health status by itself: `restart: unless-stopped`
  # only reacts to the process *exiting*, and the failure this catches is the
  # one where it doesn't — an app that is alive but no longer serving. Without
  # a watcher, that is an outage that lasts until a human notices.
  #
  # Recreated rather than left alone, so a changed image or interval actually
  # takes effect on a re-run.
  docker rm -f "$AUTOHEAL_CONTAINER" >/dev/null 2>&1 || true
  if docker run -d \
      --name "$AUTOHEAL_CONTAINER" \
      --restart unless-stopped \
      -e AUTOHEAL_CONTAINER_LABEL=autoheal \
      -e AUTOHEAL_INTERVAL=30 \
      -e AUTOHEAL_START_PERIOD="${HEALTH_START_PERIOD%s}" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      --memory 64m \
      --log-opt max-size=5m --log-opt max-file=2 \
      willfarrell/autoheal:latest >/dev/null 2>&1; then
    ok "watching containers labelled autoheal=true"
  else
    warn "could not start the autoheal sidecar (no network for the image pull?).
         Not fatal — health checks still work, nothing restarts automatically."
  fi
else
  skip "disabled in deploy.env"
fi

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
step "Firewall"
# Not "Jetstream2's security groups already filter this": Exosphere's desktop
# instances were found with the VNC port open to the internet (see the next
# step), so the security group can't be assumed to cover everything. ufw
# stays opt-in because a mistake in it locks you out of a remote instance;
# the known exposure is closed by the step below either way.
if [[ "$ENABLE_UFW" == "yes" ]]; then
  apt-get install -y -qq ufw >/dev/null
  ufw allow OpenSSH >/dev/null
  ufw allow 'Nginx Full' >/dev/null
  if ufw status | grep -q "Status: active"; then
    skip "ufw already active (rules refreshed)"
  else
    ufw --force enable >/dev/null
    ok "ufw enabled (SSH + nginx only)"
    warn "CONFIRM SSH ACCESS FROM A SECOND TERMINAL before closing this one."
  fi
else
  skip "disabled in deploy.env (opt-in; the desktop's VNC ports are closed below regardless)"
fi

# ---------------------------------------------------------------------------
# Desktop VNC ports. Exosphere's desktop instances run TurboVNC listening on
# every address (0.0.0.0:5901) for Guacamole, and their security group can
# leave that open: on the test instance, internet bots held all 100 of
# TurboVNC's connection slots for a week, so the Guacamole desktop simply
# stopped connecting — and every one of them was trying the VNC password.
# Guacamole connects from inside the host (Docker's bridge), so the ports are
# closed to everything else, by rules a boot-time unit re-applies: iptables
# rules alone vanish on reboot. Before network-pre.target, so there's no
# window at boot; after ufw, which would otherwise rebuild INPUT around them.
# Harmless on an instance with no VNC at all.
# ---------------------------------------------------------------------------
step "Desktop VNC ports"
if [[ "$PROTECT_VNC" != "yes" ]]; then
  skip "disabled in deploy.env"
else
  install -D -m 0755 -o root -g root "$SCRIPT_DIR/lib/vnc_firewall.sh" "$VNC_FIREWALL_BIN"
  cat > "/etc/systemd/system/$VNC_FIREWALL_UNIT" <<UNIT
[Unit]
Description=Keep desktop VNC ports reachable only from this host and Docker (Jetstream2 Dashboard Deploy)
DefaultDependencies=no
After=local-fs.target ufw.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$VNC_FIREWALL_BIN apply
ExecStop=$VNC_FIREWALL_BIN remove

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "$VNC_FIREWALL_UNIT" >/dev/null 2>&1 || true
  # restart, not start: a re-run picks up a changed script.
  if systemctl restart "$VNC_FIREWALL_UNIT" && [[ "$("$VNC_FIREWALL_BIN" status)" == "active" ]]; then
    ok "VNC ports 5900-5910 reachable only from this host and Docker (re-applied at every boot)"
  else
    warn "couldn't apply the VNC port rules — see: systemctl status $VNC_FIREWALL_UNIT"
  fi
fi

# ---------------------------------------------------------------------------
# Optional: deploy the app
# ---------------------------------------------------------------------------
DEPLOYED=0
if [[ -n "$PROJECT_DIR" ]]; then
  step "Deploying $PROJECT_DIR"
  [[ -d "$PROJECT_DIR" ]] || die "Not a directory: $PROJECT_DIR"

  # As the real user where possible, so a generated renv.lock or
  # requirements.txt lands in their project owned by them rather than by root.
  # Right after a fresh install their docker group membership isn't active in
  # this session yet, so fall back to root and hand ownership back afterwards.
  # `env` rather than `sudo VAR=value cmd`: sudoers' default env_reset rejects
  # variables set that way unless the rule carries SETENV, so the direct form
  # fails with "you are not allowed to set the following environment
  # variables" on a stock Ubuntu instance.
  if [[ "$DOCKER_GROUP_PENDING" -eq 0 ]] && sudo -u "$REAL_USER" docker info >/dev/null 2>&1; then
    sudo -u "$REAL_USER" -H env DATA_DIR="${DATA_DIR:-}" \
      "$SCRIPT_DIR/build_and_run.sh" "$PROJECT_DIR" || die "The deploy failed — see above."
  else
    warn "'$REAL_USER' cannot reach Docker yet (group membership applies at next login);"
    warn "running the deploy as root and restoring ownership afterwards."
    DATA_DIR="${DATA_DIR:-}" "$SCRIPT_DIR/build_and_run.sh" "$PROJECT_DIR" || \
      die "The deploy failed — see above."
    chown -R "$REAL_USER":"$REAL_USER" "$PROJECT_DIR" 2>/dev/null || true
  fi
  DEPLOYED=1
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
IP="$(lookup_public_ip)"
IP="${IP:-$(hostname -I | awk '{print $1}')}"
# The name only once HTTPS is really serving it; until then the IP, which
# always works — a name whose certificate request failed may not point here.
if grep -q '^PUBLIC_SCHEME=https' "$PROXY_STATE_FILE" && [[ -n "$SERVER_NAME" ]]; then
  URL="https://$SERVER_NAME/"
else
  URL="http://$IP/"
fi

step "Host provisioning complete"
cat <<EOF

    URL             $URL
    Exposure        nginx is the only public listener; the app binds
                    127.0.0.1:$APP_HOST_PORT and is unreachable from outside
    Health          ./deploy/manage.sh health

    Verify the app is not publicly exposed:
      sudo ss -tlnp | grep -E ':80|:$APP_HOST_PORT'
      # expect nginx on 0.0.0.0:80 and docker-proxy on 127.0.0.1:$APP_HOST_PORT ONLY

EOF

# DEPLOYED only says whether this run published one. A re-run on an instance
# that's already serving a dashboard said "No dashboard is published yet",
# which reads as if the re-run had taken it down. Docker's publish filter
# matches the host port, which is where the app sits behind nginx.
if [[ "$DEPLOYED" -eq 0 ]] \
   && [[ -n "$(docker ps -q --filter "publish=$APP_HOST_PORT" 2>/dev/null)" ]]; then
  cat <<EOF
    A dashboard is already published and still serving. To publish a new
    version, use "Deploy My Dashboard" on the desktop, or as $REAL_USER:

      ./deploy/build_and_run.sh /path/to/your/project

EOF
elif [[ "$DEPLOYED" -eq 0 ]]; then
  cat <<EOF
    No dashboard is published yet. Either open "Deploy My Dashboard" on the
    desktop, or publish from a terminal as $REAL_USER:

      ./deploy/build_and_run.sh /path/to/your/project

EOF
fi

if [[ "$DOCKER_GROUP_PENDING" -eq 1 ]]; then
  cat <<EOF
    NOTE: '$REAL_USER' was just added to the docker group. Log out and back in
    (or reboot) before running build_and_run.sh, or docker will report a
    permission error on the socket.

EOF
fi

cat <<EOF
    Routine operations:
      sudo $SCRIPT_DIR/bootstrap.sh --check          # status snapshot
      sudo $SCRIPT_DIR/bootstrap.sh                  # re-apply deploy.env changes
      sudo $SCRIPT_DIR/bootstrap.sh --remove-proxy   # roll back to no nginx
      $SCRIPT_DIR/manage.sh health                   # diagnose a problem

EOF
