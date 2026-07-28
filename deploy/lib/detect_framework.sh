#!/usr/bin/env bash
# Framework auto-detection for build_and_run.sh. Content-based, never
# filename-only (an app.py alone is ambiguous across Dash/Python
# Shiny/Streamlit/Flask) — see detect_framework() for the ambiguity/override
# story. Sourced by build_and_run.sh — not meant to be run directly.
#
# Sets on success: FRAMEWORK, ENTRY_POINT_DESC, and (Python frameworks only)
# ENTRY_FILE (the actual filename detected, e.g. "app.py" or
# "streamlit_app.py"). Reads PROJECT_DIR from the caller.

# --- R Shiny ------------------------------------------------------------
# Unchanged from the original single-framework detection: app.R, or a
# ui.R/server.R pair, or an R Markdown Shiny document (runtime: shiny in its
# YAML front matter, e.g. a flexdashboard).
detect_r_shiny() {
  if [[ -f "$PROJECT_DIR/app.R" ]]; then
    ENTRY_POINT_DESC="app.R"
    return 0
  fi
  if [[ -f "$PROJECT_DIR/server.R" ]]; then
    ENTRY_POINT_DESC="ui.R/server.R"
    return 0
  fi
  local rmd
  for rmd in "$PROJECT_DIR"/*.Rmd "$PROJECT_DIR"/*.rmd; do
    [[ -f "$rmd" ]] || continue
    if grep -qE '^runtime:[[:space:]]*shiny' "$rmd"; then
      ENTRY_POINT_DESC="R Markdown Shiny document ($(basename "$rmd"))"
      return 0
    fi
  done
  return 1
}

# Auto-detect a geospatial base image from the project's code, unless the
# caller already set BASE_IMAGE explicitly. Best-effort heuristic (a regex
# over source files, not a real dependency graph) — no equivalent concept
# exists for the 3 Python frameworks, since they declare system deps via
# apt.txt / a heavier BASE_IMAGE override rather than a swappable "flavor"
# of a shared R ecosystem image.
GEOSPATIAL_PACKAGES=(sf terra raster stars rgdal rgeos)

uses_geospatial_packages() {
  local pkg
  for pkg in "${GEOSPATIAL_PACKAGES[@]}"; do
    if grep -rlE "(library|require)\\(['\"]?${pkg}['\"]?\\)|\\b${pkg}::" \
         --include='*.R' --include='*.Rmd' "$PROJECT_DIR" >/dev/null 2>&1; then
      return 0
    fi
  done
  # A project's own code may only call library(leaflet) etc. while a
  # geospatial package rides in transitively (e.g. leaflet Imports sf) —
  # invisible to the source-file scan above. If a renv.lock is present,
  # also check its resolved package list directly, since that's the actual
  # set of things that will get compiled regardless of what the app calls.
  if [[ -f "$PROJECT_DIR/renv.lock" ]]; then
    for pkg in "${GEOSPATIAL_PACKAGES[@]}"; do
      if grep -qE "\"Package\": *\"${pkg}\"" "$PROJECT_DIR/renv.lock"; then
        return 0
      fi
    done
  fi
  return 1
}

# --- Plotly Dash ----------------------------------------------------------
# Entry file conventionally app.py, exposing `server = app.server` for a
# WSGI server (gunicorn). Detected via content, not filename.
detect_dash() {
  local pyfile
  for pyfile in "$PROJECT_DIR"/*.py; do
    [[ -f "$pyfile" ]] || continue
    # \b after `dash` matters: without it, `import dashscope` or
    # `import dashboard_utils` would false-positive as a Dash project.
    if grep -qE 'import[[:space:]]+dash\b|from[[:space:]]+dash\b|Dash\(|server[[:space:]]*=[[:space:]]*app\.server' "$pyfile"; then
      ENTRY_FILE="$(basename "$pyfile")"
      return 0
    fi
  done
  return 1
}

# --- Python Shiny (the `shiny` PyPI package) ------------------------------
# Entry file conventionally app.py, with a top-level `app = App(...)`. The
# `from shiny import` pattern is kept narrow (not bare `shiny`) so a Python
# file that merely mentions the word "shiny" in a comment/string doesn't
# false-positive; no collision risk with R's library(shiny) since the two
# are scanned from entirely different file extensions.
detect_python_shiny() {
  local pyfile
  for pyfile in "$PROJECT_DIR"/*.py; do
    [[ -f "$pyfile" ]] || continue
    if grep -qE 'from[[:space:]]+shiny[[:space:]]+import' "$pyfile" \
       && grep -qE '^[[:space:]]*app[[:space:]]*=[[:space:]]*App\(' "$pyfile"; then
      ENTRY_FILE="$(basename "$pyfile")"
      return 0
    fi
  done
  return 1
}

# --- Streamlit -------------------------------------------------------------
# Conventionally streamlit_app.py (sometimes app.py) — the whole script is
# imperative, no app/server object. streamlit_app.py as a filename is a
# reasonably strong secondary signal, but the content check still runs
# first so an unrelated file with that name doesn't false-positive.
detect_streamlit() {
  if [[ -f "$PROJECT_DIR/streamlit_app.py" ]] \
     && grep -qE 'import[[:space:]]+streamlit\b|from[[:space:]]+streamlit\b' "$PROJECT_DIR/streamlit_app.py"; then
    ENTRY_FILE="streamlit_app.py"
    return 0
  fi
  local pyfile
  for pyfile in "$PROJECT_DIR"/*.py; do
    [[ -f "$pyfile" ]] || continue
    if grep -qE 'import[[:space:]]+streamlit\b|from[[:space:]]+streamlit\b' "$pyfile"; then
      ENTRY_FILE="$(basename "$pyfile")"
      return 0
    fi
  done
  return 1
}

# --- Orchestrator ----------------------------------------------------------
# The 4 values FRAMEWORK may take, shared by the override validation below
# and the error messages that suggest setting it.
SUPPORTED_FRAMEWORKS=(r-shiny dash python-shiny streamlit)

# A forced FRAMEWORK bypasses *framework* detection, but the Python
# frameworks still need ENTRY_FILE resolved — it becomes the ENTRY_MODULE
# build-arg, and without it the Dockerfile's ARG default silently wins. For
# Streamlit that default is `streamlit_app.py`, so forcing the framework on
# a project whose entry is `app.py` used to build successfully and then
# crash-loop with "File does not exist: streamlit_app.py". Try the same
# content-based detector first (it also confirms the forced choice looks
# right), then fall back to the framework's conventional filenames.
resolve_forced_entry_file() {
  local framework="$1" candidate
  case "$framework" in
    dash)         detect_dash         || true ;;
    python-shiny) detect_python_shiny || true ;;
    streamlit)    detect_streamlit    || true ;;
    r-shiny)      return 0 ;;   # entry point is a convention, not a build-arg
  esac

  if [[ -z "$ENTRY_FILE" ]]; then
    local candidates=()
    case "$framework" in
      streamlit) candidates=(streamlit_app.py app.py) ;;
      *)         candidates=(app.py) ;;
    esac
    for candidate in "${candidates[@]}"; do
      if [[ -f "$PROJECT_DIR/$candidate" ]]; then
        ENTRY_FILE="$candidate"
        echo "FRAMEWORK=$framework was forced; no $framework signal found in the project's" >&2
        echo ".py files, so falling back to $candidate as the entry point." >&2
        return 0
      fi
    done
    echo "FRAMEWORK=$framework was forced, but no usable entry point was found in" >&2
    echo "$PROJECT_DIR — expected one of: ${candidates[*]}." >&2
    exit 1
  fi
}

# Sets FRAMEWORK, ENTRY_POINT_DESC, and (Python frameworks) ENTRY_FILE.
# An explicit FRAMEWORK env var (mirroring BASE_IMAGE's override pattern)
# bypasses framework detection — the escape hatch for ambiguous projects or
# a wrong guess — but is still validated against the supported set, since a
# typo (e.g. FRAMEWORK=Dash) would otherwise surface much later as a raw
# "cp: Dockerfile.Dash: No such file" from inside build_image().
detect_framework() {
  if [[ -n "${FRAMEWORK:-}" ]]; then
    local supported valid=0
    for supported in "${SUPPORTED_FRAMEWORKS[@]}"; do
      [[ "$FRAMEWORK" == "$supported" ]] && valid=1
    done
    if [[ "$valid" -ne 1 ]]; then
      echo "Unknown FRAMEWORK='$FRAMEWORK'." >&2
      echo "Supported values: ${SUPPORTED_FRAMEWORKS[*]}" >&2
      exit 1
    fi
    resolve_forced_entry_file "$FRAMEWORK"
    if [[ -n "$ENTRY_FILE" ]]; then
      ENTRY_POINT_DESC="$ENTRY_FILE (forced via FRAMEWORK=$FRAMEWORK)"
    else
      ENTRY_POINT_DESC="(forced via FRAMEWORK=$FRAMEWORK)"
    fi
    return 0
  fi

  if detect_r_shiny; then
    FRAMEWORK="r-shiny"
    return 0
  fi

  if [[ -f "$PROJECT_DIR/DESCRIPTION" && -f "$PROJECT_DIR/inst/app.R" ]]; then
    echo "This looks like a golem-packaged app (DESCRIPTION + inst/app.R found), but" >&2
    echo "Shiny Server needs an entry point at the project root, not under inst/." >&2
    echo "Add a root-level app.R that loads and runs the package, e.g.:" >&2
    echo "  pkgload::load_all()" >&2
    echo "  <pkgname>::run_app()" >&2
    exit 1
  fi

  local dash_entry="" pyshiny_entry="" streamlit_entry=""
  if detect_dash;         then dash_entry="$ENTRY_FILE"; fi
  if detect_python_shiny; then pyshiny_entry="$ENTRY_FILE"; fi
  if detect_streamlit;    then streamlit_entry="$ENTRY_FILE"; fi

  local match_count=0
  [[ -n "$dash_entry" ]]      && match_count=$((match_count + 1))
  [[ -n "$pyshiny_entry" ]]   && match_count=$((match_count + 1))
  [[ -n "$streamlit_entry" ]] && match_count=$((match_count + 1))

  if [[ "$match_count" -gt 1 ]]; then
    echo "Multiple framework signals detected in $PROJECT_DIR — can't auto-detect confidently:" >&2
    [[ -n "$dash_entry" ]]      && echo "  Plotly Dash signal in $dash_entry" >&2
    [[ -n "$pyshiny_entry" ]]   && echo "  Python Shiny signal in $pyshiny_entry" >&2
    [[ -n "$streamlit_entry" ]] && echo "  Streamlit signal in $streamlit_entry" >&2
    echo "Set FRAMEWORK=dash|python-shiny|streamlit|r-shiny to force a choice and re-run." >&2
    exit 1
  fi

  if [[ -n "$dash_entry" ]]; then
    FRAMEWORK="dash"
    ENTRY_FILE="$dash_entry"
  elif [[ -n "$pyshiny_entry" ]]; then
    FRAMEWORK="python-shiny"
    ENTRY_FILE="$pyshiny_entry"
  elif [[ -n "$streamlit_entry" ]]; then
    FRAMEWORK="streamlit"
    ENTRY_FILE="$streamlit_entry"
  else
    echo "No app.R, ui.R/server.R, R Markdown Shiny document (runtime: shiny), or a" >&2
    echo "recognizable Dash/Python Shiny/Streamlit app.py/streamlit_app.py found in" >&2
    echo "$PROJECT_DIR — nothing to deploy." >&2
    echo >&2
    echo "Supported conventions:" >&2
    echo "  R Shiny:       app.R, or ui.R + server.R, or an .Rmd with 'runtime: shiny'" >&2
    echo "  Plotly Dash:   app.py with 'import dash' and 'server = app.server'" >&2
    echo "  Python Shiny:  app.py with 'from shiny import App' and a top-level App(...)" >&2
    echo "  Streamlit:     streamlit_app.py (or app.py) with 'import streamlit'" >&2
    echo >&2
    echo "If this IS one of the above, set FRAMEWORK=r-shiny|dash|python-shiny|streamlit" >&2
    echo "to force selection and bypass detection." >&2
    exit 1
  fi

  # Consumed by build_and_run.sh (this file's documented output contract,
  # see the header), which the linter can't see when checking this file on
  # its own. Kept targeted rather than file-wide so a genuinely unused
  # variable added later still gets flagged.
  # shellcheck disable=SC2034
  ENTRY_POINT_DESC="$FRAMEWORK entry point ($ENTRY_FILE)"
}
