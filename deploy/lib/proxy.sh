#!/usr/bin/env bash
# Where the app container binds, and how to health-check it — the two facts
# that change when an nginx reverse proxy is in front of the deployment.
#
# Sourced by build_and_run.sh (via common.sh), manage.sh and bootstrap.sh.
# Not meant to be run directly.
#
# ---------------------------------------------------------------------------
# The proxy state file is the single source of truth
# ---------------------------------------------------------------------------
# bootstrap.sh writes /etc/dashboard-deploy/proxy.env when it installs nginx.
# Its presence is what tells build_and_run.sh to publish the container on
# loopback instead of on 0.0.0.0:80, and tells manage.sh which URL to probe.
#
# Deliberately a file rather than a heuristic. The alternatives are all worse:
# sniffing for an nginx process says nothing about whether *this* deployment
# is the one behind it; probing port 80 races with a container that is mid
# restart; and an environment variable is lost the moment a researcher opens a
# different terminal or the GUI relaunches. A file written once by the
# provisioning step is unambiguous, survives reboots, and is trivially
# inspectable when something looks wrong.
#
# Absence of the file means "no proxy" and reproduces the original behaviour
# exactly — direct 0.0.0.0:80 publication. Every deployment made before nginx
# existed therefore keeps working untouched, and so does a local test on a
# laptop, where bootstrap.sh is never run.

# Overridable so the whole proxy path can be exercised without root and
# without touching /etc — set DASHBOARD_PROXY_ENV to a scratch file.
# Several constants and the variables resolve_app_bind() sets are consumed by
# the scripts that source this file, not by this file itself, so the linter
# cannot see their use when checking it on its own terms.
# shellcheck disable=SC2034
PROXY_ENV_FILE="${DASHBOARD_PROXY_ENV:-/etc/dashboard-deploy/proxy.env}"

# The sidecar that restarts a container Docker has marked unhealthy. Named
# here because bootstrap.sh creates it, manage.sh reports on it, and
# common.sh must never mistake it for a stale app container.
AUTOHEAL_CONTAINER="dashboard-autoheal"

# Grace period before a container's health check starts counting failures,
# and the matching window during which the autoheal sidecar ignores everything
# after its own start.
#
# Pinned to `app_init_timeout` in deploy/docker/shiny-server.conf, which is the
# longest startup allowance any of the four frameworks grants itself. A
# geospatial R Shiny worker attaching sf/terra/GDAL/PROJ really does take
# minutes to report "Listening on", and a start period shorter than that
# allowance marks a perfectly healthy app unhealthy while it is still booting —
# which autoheal then "fixes" by restarting it, forever. Raise both together or
# neither.
HEALTH_START_PERIOD="300s"

# Every path under this prefix belongs to the deployment tooling (nginx's own
# health endpoint, the maintenance page) and is not proxied to the app.
# Documented in docs/deployment.md so a project knows not to claim it.
DEPLOY_RESERVED_PREFIX="/_deploy/"

# Read one key out of the proxy state file. Parsed rather than sourced: this
# file is read by unprivileged code paths, and `source` on a root-owned file
# is a habit worth not forming. Values are plain and unquoted by construction
# (bootstrap.sh writes them), but strip quotes anyway in case one is edited in
# by hand.
_proxy_env_get() {
  local key="$1"
  [[ -r "$PROXY_ENV_FILE" ]] || return 0
  sed -n "s/^[[:space:]]*${key}=//p" "$PROXY_ENV_FILE" | tail -1 | tr -d '"'"'"
}

# Sets PROXY_ENABLED, APP_BIND_ADDR, APP_HOST_PORT and PROXY_SERVER_NAME from
# the state file, falling back to the pre-nginx defaults when it is absent.
#
# APP_HOST_PORT is the port on the *host*; the port inside the container is
# still container_port_for_framework()'s answer and is unaffected by any of
# this. Keeping the two separate is what lets nginx sit in between without
# every framework's Dockerfile needing to know about it.
resolve_app_bind() {
  PROXY_ENABLED=0
  APP_BIND_ADDR="0.0.0.0"
  APP_HOST_PORT="80"
  PROXY_SERVER_NAME=""

  [[ -r "$PROXY_ENV_FILE" ]] || return 0

  local addr port name
  addr="$(_proxy_env_get APP_BIND_ADDR)"
  port="$(_proxy_env_get APP_HOST_PORT)"
  name="$(_proxy_env_get SERVER_NAME)"

  # A state file that exists but is malformed is a real possibility (a
  # half-finished hand edit), and silently falling back to 0.0.0.0:80 would
  # publish the app straight to the internet — the exact thing the proxy is
  # there to prevent. Refuse instead.
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ -z "$addr" ]]; then
    echo "$PROXY_ENV_FILE exists but does not define a usable APP_BIND_ADDR and" >&2
    echo "APP_HOST_PORT. Fix it, or delete it to go back to publishing the app" >&2
    echo "directly on port 80. Re-running 'sudo ./deploy/bootstrap.sh' rewrites it." >&2
    exit 1
  fi

  PROXY_ENABLED=1
  APP_BIND_ADDR="$addr"
  APP_HOST_PORT="$port"
  PROXY_SERVER_NAME="$name"
}

# The URL the app itself answers on, bypassing nginx. Used by the smoke test
# and by manage.sh to tell an app failure apart from a proxy failure.
app_direct_url() {
  echo "http://127.0.0.1:${APP_HOST_PORT}/"
}

# What the public actually reaches: nginx when it is in front, otherwise the
# container's own published port.
public_local_url() {
  if [[ "${PROXY_ENABLED:-0}" -eq 1 ]]; then
    echo "http://127.0.0.1/"
  else
    echo "http://127.0.0.1:${APP_HOST_PORT}/"
  fi
}

# Docker health-check command for a framework, run *inside* the container.
#
# Not a HEALTHCHECK line in each Dockerfile, which is the more obvious place
# for it, for two reasons. The port is only known at deploy time (CONTAINER_PORT
# can override the framework default), and python:3.11-slim ships neither curl
# nor wget — so three of the four images would have to grow a package purely
# to be checkable. Passing it to `docker run --health-cmd` instead keeps the
# images unchanged and the port correct.
#
# Checks `/` rather than a `/health` route: the app is an arbitrary project
# dropped in by a researcher and is guaranteed to expose no such route. That
# makes this a LIVENESS check only — same limitation run_smoke_test() carries.
# A framework that catches an exception and renders it as a page still answers
# 200 and still reads as healthy.
#
# Any status below 500 counts as alive, including a 404: an app that serves its
# real UI from a sub-path is unusual but legitimate, and restarting it forever
# over a 404 at `/` would be worse than not checking at all.
app_health_cmd() {
  local fw="$1" port="$2"
  case "$fw" in
    r-shiny)
      # Dockerfile.r-shiny installs curl for the Shiny Server .deb download,
      # so it is always present in this image.
      echo "curl -fsS -o /dev/null --max-time 20 http://127.0.0.1:${port}/"
      ;;
    dash|python-shiny|streamlit)
      # Python is guaranteed by the base image these three build on.
      cat <<PYCHECK
python -c "
import sys, urllib.error, urllib.request
try:
    code = urllib.request.urlopen('http://127.0.0.1:${port}/', timeout=20).status
except urllib.error.HTTPError as exc:
    code = exc.code
except Exception:
    sys.exit(1)
sys.exit(0 if code < 500 else 1)
"
PYCHECK
      ;;
    *)
      echo "app_health_cmd: unknown framework '$fw'" >&2
      return 1
      ;;
  esac
}
