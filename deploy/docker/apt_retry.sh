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

# `apt_retry.sh --from-file <path>` reads package names from a project's
# apt.txt instead of taking them as arguments. Centralized here rather than
# repeated in all 4 Dockerfiles, and sanitizing rather than passing the file
# through raw, because researchers' apt.txt files routinely arrive with:
#   - CRLF line endings (edited on Windows) — apt then reports "Unable to
#     locate package curl" for a correctly-spelled `curl\r`, naming the
#     package the user typed and giving no hint that the ending is at fault;
#   - `# comment` lines, which are natural to write and which apt otherwise
#     tries to install as literal packages named `#`, `a`, `comment`, ...
# Exits 0 when the file is absent or has no package names, so an empty
# apt.txt stays a no-op.
if [ "$1" = "--from-file" ]; then
  apt_txt="$2"
  [ -f "$apt_txt" ] || exit 0
  # Unquoted on purpose: word-splitting one-package-per-line into "$@".
  # shellcheck disable=SC2046
  set -- $(sed -e 's/\r$//' -e 's/#.*//' "$apt_txt")
  [ "$#" -eq 0 ] && exit 0
fi

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
