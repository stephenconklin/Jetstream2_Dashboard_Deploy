#!/usr/bin/env bash
# Base-image choice for build_and_run.sh: which R or Python the image is
# built on. Sourced by build_and_run.sh — not meant to be run directly.
#
# The language version comes from the project when it records one, and from
# a fixed default only when it doesn't. A project's lockfile is its own
# statement of what works: its pinned packages were resolved against that R
# or Python, and a different one fails in both directions — a package that
# requires a newer R won't install on an older one, and years-old pins often
# no longer compile against a newer one. An explicit BASE_IMAGE always wins.
#
# The pick_* functions only read files, so they run above the --dry-run gate.
# confirm_base_image_published() asks the registry, so it runs below it.
#
# Sets BASE_IMAGE, plus for the dry-run summary and --porcelain:
#   BASE_IMAGE_SOURCE - override | renv-lock | python-version | runtime-txt |
#                       requires-python | default
#   LANG_VERSION      - the R/Python version the project asked for, or empty
#   BASE_IMAGE_NOTE   - a sentence saying why, or empty

DEFAULT_R_VERSION="4.4.1"
DEFAULT_PYTHON_VERSION="3.11"

# Rocker publishes versioned images from R 4.0.0 on. Older ones exist but are
# Debian-based with a different layout, and nothing in Dockerfile.r-shiny has
# been tried on them.
MIN_LOCK_R_VERSION="4.0.0"

# Python minors with a python:<minor>-slim image, in the order tried when a
# requires-python range rules the default out: nearest the default first.
PYTHON_CANDIDATE_MINORS=(11 12 10 13 9 14 8)

BASE_IMAGE_SOURCE=""
LANG_VERSION=""
BASE_IMAGE_NOTE=""

# Whether version $1 is lower than version $2 (dotted numbers).
version_lt() {
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" == "$1" ]]
}

# The R version a renv.lock was made with: the first "Version" inside its
# top-level "R" object. A grep rather than a JSON parser, because the host has
# no JSON tool to rely on and renv writes this section first in a fixed shape.
# `"R"` with its quotes can't match a package such as R6. Prints nothing when
# it can't tell.
renv_lock_r_version() {
  awk '
    /"R"[[:space:]]*:[[:space:]]*\{/ { in_r = 1; next }
    in_r && /"Version"/ {
      if (match($0, /[0-9]+\.[0-9]+(\.[0-9]+)?/)) print substr($0, RSTART, RLENGTH)
      exit
    }
  ' "$1" 2>/dev/null || true
}

# Reads PROJECT_DIR, USES_GEOSPATIAL, and BASE_IMAGE if the caller set one.
pick_r_base_image() {
  local flavor="r-ver"
  [[ "${USES_GEOSPATIAL:-0}" -eq 1 ]] && flavor="geospatial"

  if [[ -n "${BASE_IMAGE:-}" ]]; then
    BASE_IMAGE_SOURCE="override"
    return 0
  fi

  local lock_version=""
  [[ -f "$PROJECT_DIR/renv.lock" ]] && lock_version="$(renv_lock_r_version "$PROJECT_DIR/renv.lock")"
  LANG_VERSION="$lock_version"

  if [[ -n "$lock_version" ]] && ! version_lt "$lock_version" "$MIN_LOCK_R_VERSION"; then
    BASE_IMAGE="rocker/$flavor:$lock_version"
    BASE_IMAGE_SOURCE="renv-lock"
    BASE_IMAGE_NOTE="R $lock_version, the version this project's renv.lock was made with"
    return 0
  fi

  BASE_IMAGE="rocker/$flavor:$DEFAULT_R_VERSION"
  BASE_IMAGE_SOURCE="default"
  if [[ -n "$lock_version" ]]; then
    BASE_IMAGE_NOTE="renv.lock was made with R $lock_version, older than any image this tool supports — using R $DEFAULT_R_VERSION, so some pinned packages may not install"
  elif [[ -f "$PROJECT_DIR/renv.lock" ]]; then
    BASE_IMAGE_NOTE="couldn't read an R version from renv.lock — using R $DEFAULT_R_VERSION"
  else
    BASE_IMAGE_NOTE="R $DEFAULT_R_VERSION, the default (no renv.lock yet; the one generated will record it)"
  fi
}

# Whether Python 3.<minor> satisfies one PEP 440 clause such as ">=3.10".
# Judged per minor version, since an image tag names a minor and carries its
# newest patch release. Only Python 3 is considered. Unknown shapes pass, so
# an odd specifier can't rule every version out.
python_minor_satisfies() {
  local minor="$1" clause="$2" op ver want_minor want_patch
  clause="${clause//[[:space:]]/}"
  [[ "$clause" =~ ^(~=|==|!=|<=|>=|<|>)([0-9]+)\.([0-9]+|\*)(\.([0-9]+|\*))?$ ]] || return 0
  op="${BASH_REMATCH[1]}"
  # A clause about Python 2 or 4: every 3.x is above the first and below the
  # second, so only the direction of the comparison matters.
  if [[ "${BASH_REMATCH[2]}" -gt 3 ]]; then
    [[ "$op" == "<" || "$op" == "<=" || "$op" == "!=" ]]; return
  elif [[ "${BASH_REMATCH[2]}" -lt 3 ]]; then
    [[ "$op" == ">" || "$op" == ">=" || "$op" == "!=" ]]; return
  fi
  want_minor="${BASH_REMATCH[3]}"
  want_patch="${BASH_REMATCH[5]:-}"
  [[ "$want_minor" == "*" ]] && return 0
  ver="$want_minor"
  case "$op" in
    ">=") [[ "$minor" -ge "$ver" ]] ;;
    ">")  if [[ -n "$want_patch" && "$want_patch" != "*" ]]; then [[ "$minor" -ge "$ver" ]]; else [[ "$minor" -gt "$ver" ]]; fi ;;
    "<=") [[ "$minor" -le "$ver" ]] ;;
    "<")  if [[ -n "$want_patch" && "$want_patch" != "*" && "$want_patch" -gt 0 ]]; then [[ "$minor" -le "$ver" ]]; else [[ "$minor" -lt "$ver" ]]; fi ;;
    "==") [[ "$minor" -eq "$ver" ]] ;;
    "!=") [[ -n "$want_patch" && "$want_patch" != "*" ]] || [[ "$minor" -ne "$ver" ]] ;;
    "~=") if [[ -n "$want_patch" ]]; then [[ "$minor" -eq "$ver" ]]; else [[ "$minor" -ge "$ver" ]]; fi ;;
  esac
}

python_minor_satisfies_all() {
  local minor="$1" spec="$2" clause
  local IFS=","
  for clause in $spec; do
    python_minor_satisfies "$minor" "$clause" || return 1
  done
  return 0
}

# The requires-python value from a pyproject.toml or uv.lock, or nothing.
requires_python_spec() {
  sed -nE 's/^[[:space:]]*requires-python[[:space:]]*=[[:space:]]*["'"'"']([^"'"'"']*)["'"'"'].*/\1/p' "$1" 2>/dev/null | head -n 1 || true
}

# Reads PROJECT_DIR, and BASE_IMAGE if the caller set one. Checked in order
# of how exactly each file names a version: .python-version (pyenv, uv) and
# runtime.txt (Heroku-style, python-3.10.12) name one; requires-python names
# a range, and only moves off the default when the default falls outside it.
pick_python_base_image() {
  if [[ -n "${BASE_IMAGE:-}" ]]; then
    BASE_IMAGE_SOURCE="override"
    return 0
  fi

  local version=""
  if [[ -f "$PROJECT_DIR/.python-version" ]]; then
    version="$(grep -v '^[[:space:]]*#' "$PROJECT_DIR/.python-version" | grep -oE '^[[:space:]]*(cpython-)?3\.[0-9]+' | grep -oE '3\.[0-9]+' | head -n 1 || true)"
    if [[ -n "$version" ]]; then
      BASE_IMAGE="python:$version-slim"
      BASE_IMAGE_SOURCE="python-version"
      LANG_VERSION="$version"
      BASE_IMAGE_NOTE="Python $LANG_VERSION, from .python-version"
      return 0
    fi
  fi
  if [[ -f "$PROJECT_DIR/runtime.txt" ]]; then
    version="$(grep -oE 'python-3\.[0-9]+' "$PROJECT_DIR/runtime.txt" | grep -oE '3\.[0-9]+' | head -n 1 || true)"
    if [[ -n "$version" ]]; then
      BASE_IMAGE="python:$version-slim"
      BASE_IMAGE_SOURCE="runtime-txt"
      LANG_VERSION="$version"
      BASE_IMAGE_NOTE="Python $LANG_VERSION, from runtime.txt"
      return 0
    fi
  fi

  local spec="" file
  for file in pyproject.toml uv.lock; do
    [[ -f "$PROJECT_DIR/$file" ]] || continue
    spec="$(requires_python_spec "$PROJECT_DIR/$file")"
    [[ -n "$spec" ]] && break
  done
  if [[ -n "$spec" ]]; then
    local default_minor="${DEFAULT_PYTHON_VERSION#3.}" minor
    if ! python_minor_satisfies_all "$default_minor" "$spec"; then
      for minor in "${PYTHON_CANDIDATE_MINORS[@]}"; do
        if python_minor_satisfies_all "$minor" "$spec"; then
          BASE_IMAGE="python:3.$minor-slim"
          BASE_IMAGE_SOURCE="requires-python"
          LANG_VERSION="3.$minor"
          BASE_IMAGE_NOTE="Python $LANG_VERSION, the nearest to the default that $file's requires-python \"$spec\" allows"
          return 0
        fi
      done
      BASE_IMAGE_NOTE="$file's requires-python \"$spec\" rules out every Python this tool knows — using the default"
    fi
  fi

  BASE_IMAGE="python:$DEFAULT_PYTHON_VERSION-slim"
  BASE_IMAGE_SOURCE="default"
  [[ -n "$BASE_IMAGE_NOTE" ]] || BASE_IMAGE_NOTE="Python $DEFAULT_PYTHON_VERSION, the default"
}

# Below the dry-run gate. A version taken from the project may name an image
# Rocker hasn't published, such as an R patch release from last week. Docker
# would then fail the build three times over with "manifest unknown", which
# says nothing about R. So check the tag first, and fall back to the newest
# image of the same minor version (rocker/r-ver:4.5), which is what a
# patch-level difference almost never matters for. Only for versions the
# project chose: a default or an override is used as given. A registry that
# can't be reached is not treated as a missing image — the build reports
# that itself.
confirm_base_image_published() {
  case "$BASE_IMAGE_SOURCE" in
    renv-lock|python-version|runtime-txt|requires-python) ;;
    *) return 0 ;;
  esac
  docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 && return 0

  local out
  out="$(docker manifest inspect "$BASE_IMAGE" 2>&1 >/dev/null)" && return 0
  grep -qiE 'no such manifest|manifest unknown|not found' <<< "$out" || return 0

  local repo="${BASE_IMAGE%:*}" tag="${BASE_IMAGE##*:}" fallback
  if [[ "$tag" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
    fallback="$repo:${BASH_REMATCH[1]}"
    if docker manifest inspect "$fallback" >/dev/null 2>&1; then
      echo "Note: $BASE_IMAGE hasn't been published, so using $fallback (the newest" >&2
      echo "R ${BASH_REMATCH[1]}.x there is) instead." >&2
      BASE_IMAGE="$fallback"
      return 0
    fi
  fi
  echo "There's no $BASE_IMAGE image to build on: $BASE_IMAGE_NOTE," >&2
  echo "but that version hasn't been published as an image." >&2
  echo "Set BASE_IMAGE to the nearest version that has (in the application: tab 3," >&2
  echo "Advanced, Base image), and re-run." >&2
  exit 1
}
