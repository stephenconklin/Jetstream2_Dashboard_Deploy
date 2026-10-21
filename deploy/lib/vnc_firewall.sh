#!/usr/bin/env bash
# Keep a desktop instance's VNC ports reachable only from this host and from
# Docker, where Guacamole runs. Root only. bootstrap.sh installs this as
# /usr/local/libexec/dashboard-deploy-vnc-firewall.sh and runs it at every
# boot from dashboard-deploy-vnc-firewall.service.
#
#   vnc_firewall.sh apply    # (re)create the rules — idempotent
#   vnc_firewall.sh remove   # take them out again
#   vnc_firewall.sh status   # prints "active" or "inactive"
#
# Why it exists: Exosphere's desktop instances run TurboVNC on 0.0.0.0:5901
# for Guacamole, and their security group doesn't necessarily block it. On
# the test instance, internet bots held all 100 of TurboVNC's connection
# slots for a week — 349,552 rejected attempts — so Guacamole, the only real
# client, couldn't connect and the desktop looked broken. Guacamole reaches
# VNC from inside the host (Docker's bridge, 172.16.0.0/12), so nothing
# legitimate needs the port from outside; an SSH tunnel arrives as localhost.
#
# The rules live in a chain of their own, reached from one INPUT rule, so
# re-applying replaces them exactly and `remove` takes out only what this
# script added — never Docker's rules or anyone else's. Ports 5900-5910 cover
# VNC displays :0 to :10. IPv6 gets the same treatment with only ::1 allowed,
# since Docker's networks are IPv4 here.

set -euo pipefail

CHAIN="DASHBOARD-VNC"
PORTS="5900:5910"
# 172.16.0.0/12 is where Docker puts its bridge networks by default: the
# 172.17.0.1 address Guacamole's config names, and Exosphere's own
# guacamole_exo-guac-net (172.18.0.0/16), where guacd connects from.
DOCKER_NETS="172.16.0.0/12"

apply_family() {
  local ipt="$1" loopback="$2" nets="$3" net
  command -v "$ipt" >/dev/null 2>&1 || return 0
  "$ipt" -w -N "$CHAIN" 2>/dev/null || true
  "$ipt" -w -F "$CHAIN"
  "$ipt" -w -A "$CHAIN" -s "$loopback" -j RETURN
  for net in $nets; do
    "$ipt" -w -A "$CHAIN" -s "$net" -j RETURN
  done
  "$ipt" -w -A "$CHAIN" -j DROP
  "$ipt" -w -C INPUT -p tcp --dport "$PORTS" -j "$CHAIN" 2>/dev/null \
    || "$ipt" -w -I INPUT 1 -p tcp --dport "$PORTS" -j "$CHAIN"
}

remove_family() {
  local ipt="$1"
  command -v "$ipt" >/dev/null 2>&1 || return 0
  while "$ipt" -w -D INPUT -p tcp --dport "$PORTS" -j "$CHAIN" 2>/dev/null; do :; done
  "$ipt" -w -F "$CHAIN" 2>/dev/null || true
  "$ipt" -w -X "$CHAIN" 2>/dev/null || true
}

case "${1:-}" in
  apply)
    apply_family iptables "127.0.0.0/8" "$DOCKER_NETS"
    apply_family ip6tables "::1/128" ""
    ;;
  remove)
    remove_family iptables
    remove_family ip6tables
    ;;
  status)
    if iptables -w -C INPUT -p tcp --dport "$PORTS" -j "$CHAIN" 2>/dev/null; then
      echo active
    else
      echo inactive
    fi
    ;;
  *)
    echo "usage: $0 apply|remove|status" >&2
    exit 2
    ;;
esac
