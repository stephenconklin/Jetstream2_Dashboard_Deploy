#!/usr/bin/env bash
# Look after an already-deployed dashboard: status, logs, restart, stop.
#
#   ./deploy/manage.sh status [--porcelain]
#   ./deploy/manage.sh health [--porcelain]
#   ./deploy/manage.sh url
#   ./deploy/manage.sh logs [N]
#   ./deploy/manage.sh restart
#   ./deploy/manage.sh stop
#   ./deploy/manage.sh disk [--porcelain]
#   ./deploy/manage.sh cleanup [--porcelain]
#   ./deploy/manage.sh report [path]
#
# These are thin wrappers over plain `docker` commands, which still work
# directly and are documented in docs/user-guide/reference/deployment.md — nothing here is
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
# Free space, and reclaiming it. Shared with bootstrap.sh so the threshold it
# warns at and the one reported here cannot drift apart.
# shellcheck source-path=SCRIPTDIR
source "$TOOLING_DIR/lib/disk.sh"

CONTAINER_NAME="${CONTAINER_NAME:-dashboard-app}"

# Sets PROXY_ENABLED / APP_BIND_ADDR / APP_HOST_PORT / PROXY_SERVER_NAME, so
# every probe below aims at the port this deployment actually uses instead of
# assuming 80.
resolve_app_bind

usage() {
  echo "usage: manage.sh {status [--porcelain]|health [--porcelain]|url|logs [N]|" >&2
  echo "                  restart|stop|disk [--porcelain]|cleanup [--porcelain]|report [path]}" >&2
  exit 2
}

# Present but not necessarily running; "" when no such container exists (and
# also when the Docker daemon isn't reachable — see docker_field below, which
# is what keeps those two from returning subtly different empty values).
container_state() {
  docker_field "" -f '{{.State.Status}}' "$CONTAINER_NAME"
}

# Whether the app answers HTTP, as opposed to merely having a running
# container. Same distinction run_smoke_test() draws: this is liveness, not
# correctness — a framework that renders its own error page still answers.
#
# Probes the app directly rather than through nginx, deliberately: this
# question is about the app, and routing it through the proxy would report a
# healthy app as broken whenever nginx is the thing that's down. The proxy
# gets its own probe in cmd_health().
container_responding() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS -o /dev/null --max-time 5 "$(app_direct_url)" 2>/dev/null
}

# One `dashboard.*` provenance label off the container, or "" when the label
# isn't there — which is the case for anything deployed before run_container()
# started writing them. An absent label is a fact to report, not an error: the
# GUI simply doesn't restore what it can't learn.
container_label() {
  docker_field "" -f "{{index .Config.Labels \"dashboard.$1\"}}" "$CONTAINER_NAME"
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
      echo "project_dir="
      echo "project_dir_exists=0"
      echo "data_dir="
      echo "framework="
      echo "deployed_at="
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
  [[ "$health" == "responding" ]] && url="$(public_url)"

  # Where this deployment came from. Written as labels by run_container(); see
  # the comment there for why the container rather than a state file.
  local project_dir data_dir framework deployed_at project_exists
  project_dir="$(container_label project_dir)"
  data_dir="$(container_label data_dir)"
  framework="$(container_label framework)"
  deployed_at="$(container_label deployed_at)"
  # Reported separately because the folder can be renamed, moved or deleted
  # after a deploy while the container carries on serving perfectly well from
  # the image. A caller offering to re-publish from that path needs to know.
  project_exists=0
  [[ -n "$project_dir" && -d "$project_dir" ]] && project_exists=1

  if [[ "$porcelain" -eq 1 ]]; then
    echo "container=$CONTAINER_NAME"
    echo "state=$state"
    echo "health=$health"
    echo "url=$url"
    echo "created=$created"
    echo "project_dir=$project_dir"
    echo "project_dir_exists=$project_exists"
    echo "data_dir=$data_dir"
    echo "framework=$framework"
    echo "deployed_at=$deployed_at"
  else
    echo "Container: $CONTAINER_NAME"
    echo "State:     $state"
    echo "Health:    $health"
    # `if`, not `[[ … ]] && echo`: under `set -e` a failed test as the last
    # command of a function makes the whole script exit non-zero, and one in
    # the middle of a block stops the rest of the output entirely.
    if [[ -n "$url" ]]; then
      echo "URL:       $url"
    fi
    if [[ -n "$project_dir" ]]; then
      local missing=""
      if [[ "$project_exists" -ne 1 ]]; then
        missing="  (no longer there)"
      fi
      echo "Published from:"
      echo "  project   ${project_dir}${missing}"
      if [[ -n "$data_dir" ]];    then echo "  data      $data_dir"; fi
      if [[ -n "$framework" ]];   then echo "  framework $framework"; fi
      if [[ -n "$deployed_at" ]]; then echo "  published $deployed_at"; fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# health
#
# `status` answers "is it up?". This answers "which layer is broken?", which
# is a different question the moment nginx sits in front: a browser showing
# nothing looks identical whether the proxy is down, the container is down, or
# the app inside it is wedged, and each needs a different fix.
#
# Everything is probed live rather than read from a log. There is no sampler
# daemon in this design, so a stale reading is impossible — the cost is that
# this cannot tell you about a problem that has already passed, only the one
# happening now. `docker logs` remains the record of what happened earlier.
# ---------------------------------------------------------------------------

# HTTP status for a URL, or 000 if nothing answered at all. Never fails: the
# whole point is to report unreachability, not to exit on it.
#
# The `|| echo` fallback that would be the obvious way to write this is a
# trap: on a refused connection curl prints "000" via -w AND exits non-zero,
# so the fallback appends a second one and the result reads "000000".
http_code() {
  command -v curl >/dev/null 2>&1 || { echo "000"; return 0; }
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "${2:-8}" "$1" 2>/dev/null)" || true
  echo "${code:-000}"
}

# First non-empty line of a `docker inspect` field, or a caller-supplied
# default. The plain `cmd || echo default` form is not enough: when the Docker
# daemon isn't reachable, the client writes an empty line to stdout *and*
# exits non-zero, so the result comes back as a blank line followed by the
# default rather than the default alone.
docker_field() {
  local default="$1"; shift
  local out
  out="$(docker inspect "$@" 2>/dev/null | grep -m1 -v '^[[:space:]]*$')" || true
  echo "${out:-$default}"
}

# Docker's own health verdict for the container. "none" when the container
# was started without a health check — which is the case for anything
# deployed before this existed, and is a fact worth reporting rather than
# quietly rendering as unhealthy.
container_health_status() {
  docker_field unknown \
    -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME"
}

cmd_health() {
  local porcelain=0
  [[ "${1:-}" == "--porcelain" ]] && porcelain=1

  local state health_status restarts started
  state="$(container_state)"
  state="${state:-absent}"
  health_status="none"
  restarts="0"
  started=""
  if [[ "$state" != "absent" ]]; then
    health_status="$(container_health_status)"
    restarts="$(docker_field 0 -f '{{.RestartCount}}' "$CONTAINER_NAME")"
    started="$(docker_field "" -f '{{.State.StartedAt}}' "$CONTAINER_NAME")"
  fi

  # Probe the app directly, and — separately — whatever the public actually
  # reaches. When there's no proxy these are the same URL and the same answer;
  # when there is one, the difference between them is the whole diagnosis.
  local app_code public_code nginx_code="skipped"
  app_code="$(http_code "$(app_direct_url)")"
  public_code="$(http_code "$(public_local_url)")"
  if [[ "$PROXY_ENABLED" -eq 1 ]]; then
    nginx_code="$(http_code "http://127.0.0.1${DEPLOY_RESERVED_PREFIX}health" 5)"
  fi

  local nginx_service="not-installed"
  if command -v nginx >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
      nginx_service="$(systemctl is-active nginx 2>/dev/null || echo inactive)"
    else
      nginx_service="installed"
    fi
  fi

  local autoheal_state
  autoheal_state="$(docker_field absent -f '{{.State.Status}}' "$AUTOHEAL_CONTAINER")"

  # Resource lines, best-effort. `docker stats --no-stream` costs a second or
  # two, which is acceptable for a command a human runs on purpose.
  local mem_usage="unknown" cpu_pct="unknown"
  if [[ "$state" == "running" ]]; then
    local stats
    stats="$(docker stats --no-stream --format '{{.MemUsage}}|{{.CPUPerc}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    if [[ -n "$stats" ]]; then
      mem_usage="${stats%%|*}"
      cpu_pct="${stats##*|}"
    fi
  fi
  local root_disk
  root_disk="$(df -h / 2>/dev/null | awk 'NR==2{print $5" used, "$4" free"}')"

  # One verdict, in the order a person would actually diagnose it: is there a
  # container, is it running, does the app answer, does the proxy answer, does
  # the proxy reach the app.
  local verdict detail
  if [[ "$state" == "absent" ]]; then
    verdict="not-deployed"
    detail="No dashboard has been published on this instance yet."
  elif [[ "$state" != "running" ]]; then
    verdict="stopped"
    detail="The container exists but is $state. Start it with: docker start $CONTAINER_NAME"
  elif [[ "$app_code" == "000" ]]; then
    verdict="app-not-responding"
    detail="The container is running but the app inside it isn't answering. Check 'manage.sh logs'."
  elif [[ "$PROXY_ENABLED" -eq 1 && "$nginx_code" != "200" ]]; then
    verdict="proxy-down"
    detail="The app is fine, but nginx isn't serving. Try: sudo nginx -t && sudo systemctl restart nginx"
  elif [[ "$public_code" == "000" || "$public_code" -ge 500 ]]; then
    verdict="proxy-cannot-reach-app"
    detail="nginx is up and the app is up, but the proxy can't reach it (HTTP $public_code). Check /var/log/nginx/dashboard.error.log."
  elif [[ "$health_status" == "unhealthy" ]]; then
    verdict="unhealthy"
    detail="The app answers, but Docker's health check is failing. It may be partly wedged."
  else
    verdict="ok"
    detail="The dashboard is up and reachable."
  fi

  if [[ "$porcelain" -eq 1 ]]; then
    echo "verdict=$verdict"
    echo "container=$CONTAINER_NAME"
    echo "state=$state"
    echo "docker_health=$health_status"
    echo "restarts=$restarts"
    echo "started=$started"
    echo "app_http=$app_code"
    echo "public_http=$public_code"
    echo "nginx_http=$nginx_code"
    echo "nginx_service=$nginx_service"
    echo "proxy_enabled=$PROXY_ENABLED"
    echo "app_bind=$APP_BIND_ADDR:$APP_HOST_PORT"
    echo "autoheal=$autoheal_state"
    echo "mem_usage=$mem_usage"
    echo "cpu_pct=$cpu_pct"
    echo "root_disk=$root_disk"
    echo "url=$(public_url)"
    echo "detail=$detail"
    return 0
  fi

  echo "Dashboard health"
  echo "================"
  echo "Verdict:        $verdict — $detail"
  echo
  echo "Container:      $CONTAINER_NAME ($state)"
  echo "  Docker health $health_status"
  echo "  Restarts      $restarts"
  [[ -n "$started" ]] && echo "  Started       $started"
  echo "  Memory        $mem_usage"
  echo "  CPU           $cpu_pct"
  echo
  if [[ "$PROXY_ENABLED" -eq 1 ]]; then
    echo "Serving:        nginx on port 80  ->  app on $APP_BIND_ADDR:$APP_HOST_PORT"
    echo "  nginx service $nginx_service"
    echo "  nginx itself  HTTP $nginx_code  (${DEPLOY_RESERVED_PREFIX}health)"
  else
    echo "Serving:        app published directly on $APP_BIND_ADDR:$APP_HOST_PORT (no proxy)"
    echo "                run 'sudo ./deploy/bootstrap.sh' to put nginx in front"
  fi
  echo "  app direct    HTTP $app_code  ($(app_direct_url))"
  echo "  public path   HTTP $public_code  ($(public_local_url))"
  echo "  autoheal      $autoheal_state"
  echo
  echo "Host:"
  echo "  root disk     ${root_disk:-unknown}"
  echo
  echo "URL:            $(public_url)"
  echo
  # Said explicitly because it is the single most common misreading of a
  # green result, and the same caveat run_smoke_test() carries.
  echo "Note: 'ok' means the dashboard is reachable and answering — not that it is"
  echo "showing the right thing. Shiny and Streamlit render their own errors as a"
  echo "page and still answer 200. Open it in a browser to check that."
}

cmd_url() {
  [[ "$(container_state)" == "running" ]] || {
    echo "The dashboard isn't running." >&2
    exit 1
  }
  public_url
}

cmd_logs() {
  local n="${1:-200}"
  # 2>&1 because `docker logs` forwards the container's stdout and stderr to
  # its own, and most app servers (gunicorn, Shiny Server, Streamlit) log to
  # stderr. Without this, anything capturing only stdout — including the
  # GUI — gets an empty log and looks broken.
  docker logs --tail "$n" "$CONTAINER_NAME" 2>&1
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

# ---------------------------------------------------------------------------
# disk / cleanup
#
# Running out of disk is the failure researchers are least equipped to
# recognise: it surfaces as a compile or extraction error hundreds of lines
# into a build log, naming a file rather than the disk. bootstrap.sh warns
# about it at provision time; these two verbs are how it stays visible (and
# fixable) afterwards, without anyone needing to know what a dangling image
# is.
# ---------------------------------------------------------------------------

cmd_disk() {
  if [[ "${1:-}" == "--porcelain" ]]; then
    print_disk_porcelain "$CONTAINER_NAME"
  else
    print_disk_human "$CONTAINER_NAME"
  fi
}

cmd_cleanup() {
  local porcelain=0
  [[ "${1:-}" == "--porcelain" ]] && porcelain=1

  local result before after freed
  result="$(reclaim_disk_space)"
  before="${result%%|*}"
  after="$(echo "$result" | cut -d'|' -f2)"
  freed="${result##*|}"

  if [[ "$porcelain" -eq 1 ]]; then
    echo "before_free_gb=$before"
    echo "after_free_gb=$after"
    echo "freed_gb=$freed"
    echo "root_summary=$(disk_root_summary)"
    echo "low_disk=$(disk_is_low)"
    return 0
  fi

  if [[ -n "$freed" ]]; then
    echo "Reclaimed about ${freed}GB — now $(disk_root_summary)."
  else
    echo "Cleanup finished. Now $(disk_root_summary)."
  fi
  echo
  echo "Removed leftover build layers and the build cache. Your dashboard's own"
  echo "image was not touched, so it is still running and can still be restarted."
  echo "The next publish will be slower, because the build cache has to be rebuilt."
}

# ---------------------------------------------------------------------------
# report
#
# One file to attach when asking for help. It exists because the alternative
# is asking a researcher to run six commands over a remote desktop and paste
# the output back, which in practice yields a screenshot of part of one of
# them.
#
# Deliberately assembled from the verbs above rather than collecting anything
# new: whatever this reports is something they could have read themselves in
# the GUI, which keeps it honest and keeps it from drifting.
# ---------------------------------------------------------------------------
cmd_report() {
  local out="${1:-}"
  [[ -n "$out" ]] || out="$HOME/dashboard-deploy-logs/report-$(date +%Y%m%d-%H%M%S).txt"
  mkdir -p "$(dirname "$out")"

  {
    echo "Dashboard deploy report"
    echo "Generated: $(date)"
    echo "Host:      $(uname -srm)"
    echo "User:      ${USER:-unknown}"
    echo
    echo "=== health ==="
    cmd_health || true
    echo
    echo "=== disk ==="
    print_disk_human "$CONTAINER_NAME" || true
    echo
    echo "=== containers ==="
    docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null || true
    echo
    echo "=== proxy state ==="
    if [[ -r "$PROXY_ENV_FILE" ]]; then
      cat "$PROXY_ENV_FILE"
    else
      echo "(none — the app publishes directly on port 80)"
    fi
    echo
    echo "=== nginx ==="
    if command -v nginx >/dev/null 2>&1; then
      nginx -v 2>&1 || true
      # Root-owned on a provisioned host. Absent output here is itself a fact
      # worth having, so failure is not an error.
      tail -n 40 /var/log/nginx/dashboard.error.log 2>/dev/null \
        || echo "(could not read /var/log/nginx/dashboard.error.log)"
    else
      echo "(nginx is not installed)"
    fi
    echo
    echo "=== app log (last 200 lines) ==="
    cmd_logs 200 2>&1 || true
  } > "$out" 2>&1

  echo "$out"
}

[[ $# -ge 1 ]] || usage
action="$1"; shift
case "$action" in
  status)  cmd_status "${1:-}" ;;
  health)  cmd_health "${1:-}" ;;
  url)     cmd_url ;;
  logs)    cmd_logs "${1:-}" ;;
  restart) cmd_restart ;;
  stop)    cmd_stop ;;
  disk)    cmd_disk "${1:-}" ;;
  cleanup) cmd_cleanup "${1:-}" ;;
  report)  cmd_report "${1:-}" ;;
  *)       usage ;;
esac
