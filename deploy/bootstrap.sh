#!/usr/bin/env bash
#
# Provision a fresh Jetstream2 instance to host a dashboard.
#
#   sudo ./deploy/bootstrap.sh                        # provision the host
#   sudo ./deploy/bootstrap.sh /path/to/project       # provision, then deploy
#   sudo ./deploy/bootstrap.sh --check                # read-only status
#   sudo ./deploy/bootstrap.sh --remove-proxy         # roll back to no nginx
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
# image. Attach and mount the volume first; see docs/deployment.md.
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

MODE="full"
ASSUME_YES=0
PROJECT_DIR=""
for arg in "$@"; do
  case "$arg" in
    --check)         MODE="check" ;;
    --remove-proxy)  MODE="remove-proxy" ;;
    --yes|-y)        ASSUME_YES=1 ;;
    # -E, not a basic-regex `\?`: BSD sed (macOS, where this repo is developed)
    # matches that literally rather than as "optional".
    --help|-h)       sed -n '2,12p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
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
REAL_USER="${SUDO_USER:-root}"
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
APP_HOST_PORT="8080"
CLIENT_MAX_BODY_SIZE="100m"
RATE_LIMIT="10r/s"
RATE_BURST="60"
CONN_LIMIT="32"
PROXY_TIMEOUT="3600s"
SWAP_SIZE="2G"
ENABLE_AUTOHEAL="yes"
ENABLE_UFW="no"

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

[[ "$APP_HOST_PORT" =~ ^[0-9]+$ ]] || die "APP_HOST_PORT must be a port number, got '$APP_HOST_PORT'"
[[ "$APP_HOST_PORT" != "80" ]] || die "APP_HOST_PORT cannot be 80 — nginx needs that port."

# Let's Encrypt cannot issue for a bare IP. Work that out now rather than
# letting certbot fail two thirds of the way through an otherwise fine run.
TLS_OK="no"
if [[ -n "$SERVER_NAME" && "$ENABLE_TLS" == "yes" ]]; then
  if [[ "$SERVER_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "SERVER_NAME is a bare IP — Let's Encrypt cannot issue for IPs. TLS skipped."
  elif [[ -z "$CERTBOT_EMAIL" ]]; then
    warn "CERTBOT_EMAIL is empty — TLS skipped."
  else
    TLS_OK="yes"
  fi
fi

PROXY_STATE_FILE="$PROXY_ENV_FILE"
NGINX_SITE="/etc/nginx/sites-available/dashboard"
MAINTENANCE_ROOT="/var/www/dashboard-deploy"

# ---------------------------------------------------------------------------
# --check: report and stop, changing nothing
# ---------------------------------------------------------------------------
if [[ "$MODE" == "check" ]]; then
  step "Host"
  for c in docker nginx; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c installed"; else warn "$c NOT installed"; fi
  done
  command -v systemctl >/dev/null 2>&1 && \
    echo "    ---  nginx service: $(systemctl is-active nginx 2>/dev/null || echo inactive)"
  echo "    ---  swap: $(swapon --show=SIZE --noheadings 2>/dev/null | tr '\n' ' ' || echo none)"
  echo "    ---  root disk: $(df -h / | awk 'NR==2{print $5" used, "$4" free"}')"

  step "Proxy state"
  if [[ -f "$PROXY_STATE_FILE" ]]; then
    ok "$PROXY_STATE_FILE"
    sed 's/^/    ---  /' "$PROXY_STATE_FILE"
  else
    warn "no $PROXY_STATE_FILE — the app publishes directly on port 80"
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
# Free port 80
#
# Ordering matters: the Debian nginx package starts the service in its
# postinst, and a bind failure there leaves dpkg half-configured and needing
# manual repair. So whatever holds port 80 has to go first.
#
# On an instance where a dashboard is already deployed, that is the app
# container itself — which means taking the dashboard offline. It comes back
# as soon as it is re-published, and this is the only moment of downtime in
# the whole transition, but it is not something to do behind someone's back.
# ---------------------------------------------------------------------------
step "Port 80"
PORT80_CONTAINERS="$(docker ps -aq --filter "publish=80" 2>/dev/null || true)"
if [[ -n "$PORT80_CONTAINERS" ]]; then
  PORT80_NAMES="$(docker ps -a --filter "publish=80" --format '{{.Names}}' | tr '\n' ' ')"
  echo
  echo "    A container is bound to host port 80: ${PORT80_NAMES% }"
  echo "    nginx needs that port, so it has to be removed and re-published"
  echo "    behind the proxy. The image is kept, so re-publishing is a fast"
  echo "    restart rather than a rebuild."
  echo
  if [[ "$ASSUME_YES" -eq 0 && -z "$PROJECT_DIR" && -t 0 ]]; then
    read -rp "    Take the dashboard offline and continue? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "Stopped at your request. Nothing has been changed."
  elif [[ "$ASSUME_YES" -eq 0 && -z "$PROJECT_DIR" ]]; then
    die "A container holds port 80 and there is no terminal to confirm removing it.
       Re-run with a project directory (which re-publishes automatically):
         sudo $0 /path/to/your/project
       or confirm non-interactively:
         sudo $0 --yes"
  fi
  # shellcheck disable=SC2086
  docker rm -f $PORT80_CONTAINERS >/dev/null
  ok "removed ${PORT80_NAMES% }"
elif ss -tlnp 2>/dev/null | grep -q ':80 ' && ! ss -tlnp 2>/dev/null | grep ':80 ' | grep -q nginx; then
  echo
  ss -tlnp 2>/dev/null | grep ':80 ' | sed 's/^/    /' || true
  die "Port 80 is held by something other than nginx or a container (shown above).
       Stop that service and re-run."
else
  ok "free"
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
# nginx
# ---------------------------------------------------------------------------
step "nginx reverse proxy"
command -v nginx >/dev/null 2>&1 || { apt-get install -y -qq nginx >/dev/null; ok "nginx installed"; }

install -d -m 0755 "$MAINTENANCE_ROOT/_deploy"
install -m 0644 "$SCRIPT_DIR/nginx/unavailable.html" "$MAINTENANCE_ROOT/_deploy/unavailable.html"
ok "maintenance page at $MAINTENANCE_ROOT/_deploy/unavailable.html"

# Binding [::]:80 on a host with IPv6 disabled doesn't degrade — nginx fails
# to start outright. Detect it and render that line as a comment instead, so
# an IPv6-less instance still gets a working proxy.
if [[ -e /proc/net/if_inet6 ]]; then
  LISTEN_IPV6="listen [::]:80;"
  ok "IPv6 available — listening on it too"
else
  LISTEN_IPV6="# listen [::]:80;  (IPv6 unavailable on this host)"
  warn "IPv6 unavailable — nginx will listen on IPv4 only"
fi

# `|` as the sed delimiter, because RATE_LIMIT contains a slash ("10r/s").
sed -e "s|__SERVER_NAME__|${SERVER_NAME:-_}|g" \
    -e "s|__LISTEN_IPV6__|$LISTEN_IPV6|g" \
    -e "s|__APP_HOST_PORT__|$APP_HOST_PORT|g" \
    -e "s|__CLIENT_MAX_BODY_SIZE__|$CLIENT_MAX_BODY_SIZE|g" \
    -e "s|__RATE_LIMIT__|$RATE_LIMIT|g" \
    -e "s|__RATE_BURST__|$RATE_BURST|g" \
    -e "s|__CONN_LIMIT__|$CONN_LIMIT|g" \
    -e "s|__PROXY_TIMEOUT__|$PROXY_TIMEOUT|g" \
    -e "s|__MAINTENANCE_ROOT__|$MAINTENANCE_ROOT|g" \
    "$SCRIPT_DIR/nginx/dashboard.conf.template" > "$NGINX_SITE"

rm -f /etc/nginx/sites-enabled/default
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/dashboard

nginx -t 2>/dev/null || { nginx -t; die "nginx config test failed — not reloading."; }
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

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------
step "TLS"
if [[ "$TLS_OK" == "yes" ]]; then
  apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
  if certbot certificates 2>/dev/null | grep -q "Domains:.*\b$SERVER_NAME\b"; then
    # A certificate already exists, but the site config was just re-rendered
    # from the template a few lines above — which wiped the listen 443 / ssl_
    # directives certbot had added. Re-install into the fresh config rather
    # than skipping, or every re-run of bootstrap would silently drop the
    # instance back to plain HTTP while reporting success.
    if certbot install --nginx --cert-name "$SERVER_NAME" --redirect >/dev/null 2>&1; then
      ok "existing certificate re-applied to the regenerated config"
      sed -i 's|^PUBLIC_SCHEME=.*|PUBLIC_SCHEME=https|' "$PROXY_STATE_FILE"
    else
      warn "certificate exists but could not be re-applied — the site is HTTP only.
         Try: sudo certbot install --nginx --cert-name $SERVER_NAME --redirect"
    fi
  elif certbot --nginx -d "$SERVER_NAME" --non-interactive --agree-tos \
               -m "$CERTBOT_EMAIL" --redirect; then
    ok "certificate issued; HTTP->HTTPS redirect enabled"
    sed -i 's|^PUBLIC_SCHEME=.*|PUBLIC_SCHEME=https|' "$PROXY_STATE_FILE"
  else
    warn "certbot failed — the site remains available over plain HTTP.
         Most common causes: DNS for $SERVER_NAME does not yet resolve to this
         instance's floating IP, or port 80 is closed in the Jetstream2
         security group. Fix, then re-run bootstrap.sh."
  fi
else
  skip "no DNS name configured (set SERVER_NAME and CERTBOT_EMAIL in deploy.env)"
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
      -e AUTOHEAL_START_PERIOD=180 \
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
  skip "disabled (Jetstream2 security groups already filter inbound traffic)"
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
IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
SCHEME="http"
grep -q '^PUBLIC_SCHEME=https' "$PROXY_STATE_FILE" && SCHEME="https"
URL="$SCHEME://${SERVER_NAME:-$IP}/"

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

if [[ "$DEPLOYED" -eq 0 ]]; then
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
