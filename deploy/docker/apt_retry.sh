#!/bin/sh
# Retry `apt-get update && apt-get install -y --no-install-recommends "$@"`
# up to 3 times with a 10s backoff. Transient mirror/network hiccups are
# common enough across many different builds to be worth a few retries
# before failing the whole `docker build`.
#
# Some Jetstream2 instances block outbound port 80 at the security-group
# level while leaving 443 open, and Ubuntu/Debian's default sources point
# at http:// mirrors — apt then hangs/times out on every attempt no matter
# how many retries. Rewrite sources to https:// first so this works
# regardless of the instance's egress rules. Covers both the classic
# sources.list format and the deb822 *.sources format newer Ubuntu/Debian
# releases use. Safe to run every invocation: "http://" isn't a substring
# of "https://", so re-running this against already-https sources is a
# no-op.
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [ -f "$f" ] && sed -i 's#http://#https://#g' "$f"
done

for i in 1 2 3; do
  if apt-get update && apt-get install -y --no-install-recommends "$@"; then
    exit 0
  fi
  echo "apt-get install failed (attempt $i/3) for: $*" >&2
  if [ "$i" -lt 3 ]; then
    echo "retrying in 10s..." >&2
    sleep 10
  fi
done
exit 1
