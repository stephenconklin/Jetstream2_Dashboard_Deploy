#!/usr/bin/env bash
# Is a domain name ready to serve this dashboard over HTTPS? Read-only: it
# looks the name up and compares the answer with this instance's public IP,
# and changes nothing. Sourced by bootstrap.sh and common.sh for its
# functions, and run directly by the desktop app (as the ordinary user, no
# root needed) to check a name before anything is set up:
#
#   domain.sh <name>               # a sentence for people
#   domain.sh --porcelain <name>   # key=value, for the app
#
# Exit status 0 means ready. The porcelain keys, a stable contract like
# `build_and_run.sh --dry-run --porcelain`:
#   domain=<the name, lower-cased>
#   domain_ok=1|0
#   reason=ok|empty|invalid_name|is_ip|not_resolving|points_elsewhere|public_ip_unknown
#   resolves_to=<space-separated IPv4 addresses the name has, or empty>
#   public_ip=<this instance's public IPv4, or empty>
#
# Why a check at all, before asking Let's Encrypt: a name that doesn't point
# here yet fails certbot with an error about challenge files that says
# nothing about DNS, and Let's Encrypt allows only five failed validations an
# hour, so a researcher retrying a not-yet-propagated record locks themselves
# out. Checking DNS first turns that into "your name points to X, not here".
#
# DASHBOARD_PUBLIC_IP overrides the public IP lookup (as DASHBOARD_PROXY_ENV
# overrides the proxy state file): the way to exercise this on a test machine
# whose "public" address is a private one.

# This instance's public IPv4, or nothing. Not an OpenStack metadata call — a
# floating IP is NAT'd onto the instance, so its own metadata service has no
# way to know it. Asking an external "what's my IP" service is the reliable,
# provider-agnostic way; two of them, a short timeout each, in case one is
# down.
lookup_public_ip() {
  if [[ -n "${DASHBOARD_PUBLIC_IP:-}" ]]; then
    printf '%s\n' "$DASHBOARD_PUBLIC_IP"
    return 0
  fi
  local ip=""
  ip="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null)" || \
    ip="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null)" || true
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s\n' "$ip"
  return 0
}

# A hostname a certificate can be issued for: letters, digits and hyphens in
# dot-separated labels, at least one dot, no label starting or ending with a
# hyphen. Strict on purpose — the value ends up in deploy.env, which is
# sourced by bash, and in the nginx config.
domain_name_is_valid() {
  local name="$1"
  [[ ${#name} -le 253 ]] || return 1
  [[ "$name" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

# Sets DOMAIN, DOMAIN_OK, DOMAIN_REASON, DOMAIN_RESOLVES_TO, DOMAIN_PUBLIC_IP.
# Never fails its caller: everything is guarded, since callers run under
# `set -euo pipefail`.
check_domain() {
  DOMAIN="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  DOMAIN="${DOMAIN%.}"
  DOMAIN_OK=0
  DOMAIN_RESOLVES_TO=""
  DOMAIN_PUBLIC_IP=""

  if [[ -z "$DOMAIN" ]]; then
    DOMAIN_REASON="empty"; return 0
  fi
  if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    DOMAIN_REASON="is_ip"; return 0
  fi
  if ! domain_name_is_valid "$DOMAIN"; then
    DOMAIN_REASON="invalid_name"; return 0
  fi

  # getent rather than dig, which isn't installed on a stock Ubuntu image;
  # it also honours /etc/hosts, which is how the local test machine fakes a
  # name. IPv4 only: the certificate check Let's Encrypt makes is about
  # whether the name reaches this instance, and Jetstream2 floating IPs are
  # IPv4.
  DOMAIN_RESOLVES_TO="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  DOMAIN_RESOLVES_TO="${DOMAIN_RESOLVES_TO% }"
  if [[ -z "$DOMAIN_RESOLVES_TO" ]]; then
    DOMAIN_REASON="not_resolving"; return 0
  fi

  DOMAIN_PUBLIC_IP="$(lookup_public_ip)"
  if [[ -z "$DOMAIN_PUBLIC_IP" ]]; then
    DOMAIN_REASON="public_ip_unknown"; return 0
  fi

  # Every address the name has must be this instance: with a second, stale
  # A record, Let's Encrypt may validate against the wrong machine.
  local ip
  for ip in $DOMAIN_RESOLVES_TO; do
    if [[ "$ip" != "$DOMAIN_PUBLIC_IP" ]]; then
      DOMAIN_REASON="points_elsewhere"; return 0
    fi
  done
  DOMAIN_OK=1
  DOMAIN_REASON="ok"
}

# The sentence for each reason. The app has its own table (it never parses
# these); this one is for bootstrap's output and the command line.
domain_reason_text() {
  case "$DOMAIN_REASON" in
    ok)                echo "$DOMAIN points to this server ($DOMAIN_PUBLIC_IP)." ;;
    empty)             echo "No domain name given." ;;
    is_ip)             echo "$DOMAIN is an IP address. A certificate needs a domain name, such as dashboard.example.org." ;;
    invalid_name)      echo "\"$DOMAIN\" isn't a valid domain name. Use just the name, such as dashboard.example.org, without https:// or a path." ;;
    not_resolving)     echo "$DOMAIN doesn't resolve yet. Check the DNS record exists; a new record can take up to an hour to appear." ;;
    points_elsewhere)  echo "$DOMAIN points to $DOMAIN_RESOLVES_TO, not this server ($DOMAIN_PUBLIC_IP). Change its DNS record to $DOMAIN_PUBLIC_IP; changes can take up to an hour to appear." ;;
    public_ip_unknown) echo "Couldn't find this server's public IP address to compare with, which usually means no outbound internet access." ;;
    *)                 echo "$DOMAIN: $DOMAIN_REASON" ;;
  esac
}

# Run directly, not sourced.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  porcelain=0
  if [[ "${1:-}" == "--porcelain" ]]; then
    porcelain=1
    shift
  fi
  check_domain "${1:-}"
  if [[ "$porcelain" -eq 1 ]]; then
    echo "domain=$DOMAIN"
    echo "domain_ok=$DOMAIN_OK"
    echo "reason=$DOMAIN_REASON"
    echo "resolves_to=$DOMAIN_RESOLVES_TO"
    echo "public_ip=$DOMAIN_PUBLIC_IP"
  else
    domain_reason_text
  fi
  [[ "$DOMAIN_OK" -eq 1 ]]
fi
