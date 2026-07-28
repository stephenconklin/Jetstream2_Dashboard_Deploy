#!/usr/bin/env bash
# Look after an already-deployed dashboard: status, logs, restart, stop.
#
#   ./deploy/manage.sh status [--porcelain]
#   ./deploy/manage.sh url
#   ./deploy/manage.sh logs [N]
#   ./deploy/manage.sh restart
#   ./deploy/manage.sh stop
#
# These are thin wrappers over plain `docker` commands, which still work
# directly and are documented in docs/deployment.md — nothing here is
# required to operate a deployment by hand.
#
# It exists because the GUI needs them, and the alternative was Python
# hardcoding the container name, host port 80, and its own copy of
# public_ip(). Deployment knowledge belongs in the shell; this keeps it
# there.
set -euo pipefail

TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$TOOLING_DIR/lib/common.sh"

CONTAINER_NAME="${CONTAINER_NAME:-dashboard-app}"

usage() {
  echo "usage: manage.sh {status [--porcelain]|url|logs [N]|restart|stop}" >&2
  exit 2
}

# Present but not necessarily running; "" when no such container exists.
container_state() {
  docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true
}

# Whether the app answers HTTP, as opposed to merely having a running
# container. Same distinction run_smoke_test() draws: this is liveness, not
# correctness — a framework that renders its own error page still answers.
container_responding() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS -o /dev/null --max-time 5 "http://localhost:80/" 2>/dev/null
}

cmd_status() {
  local porcelain=0
  [[ "${1:-}" == "--porcelain" ]] && porcelain=1

  local state health url created
  state="$(container_state)"
  if [[ -z "$state" ]]; then
    if [[ "$porcelain" -eq 1 ]]; then
      echo "container=$CONTAINER_NAME"
      echo "state=absent"
      echo "health=unknown"
      echo "url="
      echo "created="
    else
      echo "No dashboard is deployed yet (no container named '$CONTAINER_NAME')."
    fi
    return 0
  fi

  if [[ "$state" == "running" ]] && container_responding; then
    health="responding"
  elif [[ "$state" == "running" ]]; then
    health="not-responding"
  else
    health="stopped"
  fi

  created="$(docker inspect -f '{{.Created}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  url=""
  [[ "$health" == "responding" ]] && url="http://$(public_ip)/"

  if [[ "$porcelain" -eq 1 ]]; then
    echo "container=$CONTAINER_NAME"
    echo "state=$state"
    echo "health=$health"
    echo "url=$url"
    echo "created=$created"
  else
    echo "Container: $CONTAINER_NAME"
    echo "State:     $state"
    echo "Health:    $health"
    [[ -n "$url" ]] && echo "URL:       $url"
  fi
}

cmd_url() {
  [[ "$(container_state)" == "running" ]] || {
    echo "The dashboard isn't running." >&2
    exit 1
  }
  echo "http://$(public_ip)/"
}

cmd_logs() {
  local n="${1:-200}"
  docker logs --tail "$n" "$CONTAINER_NAME"
}

cmd_restart() {
  docker restart "$CONTAINER_NAME" >/dev/null
  echo "Restarted '$CONTAINER_NAME'."
  echo "Give it a few seconds, then reload the page in your browser."
}

cmd_stop() {
  docker stop "$CONTAINER_NAME" >/dev/null
  # Deliberately explicit: --restart unless-stopped means a manual stop
  # persists across reboots, which surprises people who expect the app to
  # come back on its own.
  echo "Stopped '$CONTAINER_NAME'. It will stay stopped, including after a"
  echo "reboot, until you start it again with:  docker start $CONTAINER_NAME"
}

[[ $# -ge 1 ]] || usage
action="$1"; shift
case "$action" in
  status)  cmd_status "${1:-}" ;;
  url)     cmd_url ;;
  logs)    cmd_logs "${1:-}" ;;
  restart) cmd_restart ;;
  stop)    cmd_stop ;;
  *)       usage ;;
esac
