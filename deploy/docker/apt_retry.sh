#!/bin/sh
# Retry `apt-get update && apt-get install -y --no-install-recommends "$@"`
# up to 3 times with a 10s backoff. Transient mirror/network hiccups are
# common enough across many different builds to be worth a few retries
# before failing the whole `docker build`.
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
