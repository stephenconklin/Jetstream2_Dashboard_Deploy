#!/usr/bin/env bash
# Framework auto-detection for build_and_run.sh. Content-based, never
# filename-only (an app.py alone is ambiguous across Dash/Python
# Shiny/Streamlit/Flask) — see detect_framework() for the ambiguity/override
# story. Sourced by build_and_run.sh — not meant to be run directly.
#
# Reads PROJECT_DIR, plus two optional overrides from the caller:
#   FRAMEWORK  - force the framework
#   ENTRY_FILE - force the main file (a file directly inside PROJECT_DIR)
#
# Sets on success:
#   FRAMEWORK, ENTRY_POINT_DESC
#   ENTRY_FILE       - the main file (empty only for an R ui.R/server.R pair
#                      or a Shiny .Rmd, which are served by convention)
#   ENTRY_STATE      - conventional | detected | chosen | ambiguous, where
#                      `detected` means an R main file not named app.R (the
#                      build adds an app.R that runs it), and `ambiguous`
#                      means several files could be the app and a deploy will
#                      refuse to guess until ENTRY_FILE picks one
#   ENTRY_CANDIDATES - every file that could be the main file, separated by
#                      "/" (the one character a file name can never contain)

# --- Per-file signals ----------------------------------------------------
# One predicate per framework, each answering "does THIS file look like an
# app?" — shared by auto-detection (which runs them over every file) and by
# an explicit ENTRY_FILE (which runs them over just the chosen one).

# A top-level shinyApp(...) call, ignoring commented-out lines. Matches
# `shiny::shinyApp(` too, since `::` is a word boundary.
file_calls_shiny_app() {
  grep -qE '^[^#]*\bshinyApp[[:space:]]*\(' "$1"
}

# A script that builds `ui` and `server` but never hands them to shinyApp()
# — the shape of an app written to be run with "Run App" in RStudio after
# sourcing. Only consulted for a file the user chose explicitly; too weak a
# signal to auto-detect on.
file_defines_ui_and_server() {
  grep -qE '^[[:space:]]*ui[[:space:]]*(<-|=)' "$1" \
    && grep -qE '^[[:space:]]*server[[:space:]]*(<-|=)' "$1"
}

file_is_dash() {
  # \b after `dash` matters: without it, `import dashscope` or
  # `import dashboard_utils` would false-positive as a Dash project.
  grep -qE 'import[[:space:]]+dash\b|from[[:space:]]+dash\b|Dash\(|server[[:space:]]*=[[:space:]]*app\.server' "$1"
}

# The `from shiny import` pattern is kept narrow (not bare `shiny`) so a
# Python file that merely mentions the word "shiny" in a comment/string
# doesn't false-positive; no collision risk with R's library(shiny) since the
# two are scanned from entirely different file extensions.
file_is_python_shiny() {
  grep -qE 'from[[:space:]]+shiny[[:space:]]+import' "$1" \
    && grep -qE '^[[:space:]]*app[[:space:]]*=[[:space:]]*App\(' "$1"
}

file_is_streamlit() {
  grep -qE 'import[[:space:]]+streamlit\b|from[[:space:]]+streamlit\b' "$1"
}

# Appends a file name to ENTRY_CANDIDATES.
add_entry_candidate() {
  ENTRY_CANDIDATES="${ENTRY_CANDIDATES:+$ENTRY_CANDIDATES/}$1"
}

# Top-level .R files that call shinyApp() — every file that could plausibly
# be an R Shiny app's main file. ui.R/server.R/global.R are parts of an app
# rather than a whole one, so they're never offered on their own.
list_r_entry_candidates() {
  local f
  for f in "$PROJECT_DIR"/*.R "$PROJECT_DIR"/*.r; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in
      ui.R|server.R|global.R) continue ;;
    esac
    file_calls_shiny_app "$f" && basename "$f"
  done
  return 0
}

# --- R Shiny ------------------------------------------------------------
# app.R, a ui.R/server.R pair, or an R Markdown Shiny document (runtime:
# shiny in its YAML front matter, e.g. a flexdashboard) are the conventions
# Shiny Server understands natively. Beyond those, any top-level .R file that
# calls shinyApp() is accepted under whatever name it has — researchers name
# their app after their project (cc_wq.R, not app.R), and refusing that
# outright was the single most common reason a working app couldn't deploy.
# build_image() supplies the app.R Shiny Server needs in that case.
detect_r_shiny() {
  ENTRY_CANDIDATES=""
  local candidate
  while IFS= read -r candidate; do
    add_entry_candidate "$candidate"
  done < <(list_r_entry_candidates)

  if [[ -f "$PROJECT_DIR/app.R" ]]; then
    ENTRY_FILE="app.R"
    ENTRY_STATE="conventional"
    ENTRY_POINT_DESC="app.R"
    # app.R is a candidate even if its shinyApp() call is split oddly enough
    # for the grep above to miss it, since Shiny Server will run it anyway.
    case "/$ENTRY_CANDIDATES/" in
      */app.R/*) ;;
      *) ENTRY_CANDIDATES="app.R${ENTRY_CANDIDATES:+/$ENTRY_CANDIDATES}" ;;
    esac
    return 0
  fi
  if [[ -f "$PROJECT_DIR/server.R" ]]; then
    ENTRY_STATE="conventional"
    ENTRY_POINT_DESC="ui.R/server.R"
    return 0
  fi
  local rmd
  for rmd in "$PROJECT_DIR"/*.Rmd "$PROJECT_DIR"/*.rmd; do
    [[ -f "$rmd" ]] || continue
    if grep -qE '^runtime:[[:space:]]*shiny' "$rmd"; then
      ENTRY_STATE="conventional"
      ENTRY_POINT_DESC="R Markdown Shiny document ($(basename "$rmd"))"
      return 0
    fi
  done

  case "$ENTRY_CANDIDATES" in
    "")
      return 1 ;;
    */*)
      ENTRY_STATE="ambiguous"
      ENTRY_POINT_DESC="not yet chosen — more than one file could be the app: ${ENTRY_CANDIDATES//\// }"
      ;;
    *)
      ENTRY_FILE="$ENTRY_CANDIDATES"
      ENTRY_STATE="detected"
      ENTRY_POINT_DESC="$ENTRY_FILE"
      ;;
  esac
  return 0
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

# --- Python frameworks ----------------------------------------------------
# Dash: entry file conventionally app.py, exposing `server = app.server` for
# gunicorn. Python Shiny: app.py with a top-level `app = App(...)`.
# Streamlit: conventionally streamlit_app.py (sometimes app.py) — the whole
# script is imperative, no app/server object. All three are detected by
# content, not filename.
#
# detect_python_framework <framework> sets ENTRY_FILE to the first matching
# file (streamlit_app.py first for Streamlit, since that name is a strong
# secondary signal) and appends every match to the framework's own
# candidate list. Returns 1 when nothing matched.
detect_python_framework() {
  local framework="$1" predicate pyfile found=""
  case "$framework" in
    dash)         predicate=file_is_dash ;;
    python-shiny) predicate=file_is_python_shiny ;;
    streamlit)    predicate=file_is_streamlit ;;
  esac

  local files=()
  [[ "$framework" == "streamlit" && -f "$PROJECT_DIR/streamlit_app.py" ]] \
    && files+=("$PROJECT_DIR/streamlit_app.py")
  for pyfile in "$PROJECT_DIR"/*.py; do
    [[ -f "$pyfile" ]] || continue
    [[ "$framework" == "streamlit" && "$(basename "$pyfile")" == "streamlit_app.py" ]] && continue
    files+=("$pyfile")
  done

  local candidates=""
  for pyfile in "${files[@]+"${files[@]}"}"; do
    "$predicate" "$pyfile" || continue
    [[ -z "$found" ]] && found="$(basename "$pyfile")"
    candidates="${candidates:+$candidates/}$(basename "$pyfile")"
  done
  [[ -n "$found" ]] || return 1
  ENTRY_FILE="$found"
  PY_CANDIDATES="$candidates"
  return 0
}

# --- Orchestrator ----------------------------------------------------------
# The 4 values FRAMEWORK may take, shared by the override validation below
# and the error messages that suggest setting it.
SUPPORTED_FRAMEWORKS=(r-shiny dash python-shiny streamlit)

entry_file_fail() {
  echo "ENTRY_FILE='$ENTRY_FILE': $1" >&2
  shift
  local line
  for line in "$@"; do echo "$line" >&2; done
  exit 1
}

# An explicit ENTRY_FILE: the researcher (or the GUI on their behalf) has
# said which file is the app, so validate that choice and infer the
# framework from it — rather than second-guessing it with a project-wide
# scan that may well have been what came back ambiguous in the first place.
resolve_chosen_entry_file() {
  local path="$PROJECT_DIR/$ENTRY_FILE"
  if [[ "$ENTRY_FILE" == */* ]]; then
    entry_file_fail "must be a file directly inside $PROJECT_DIR, not in a subfolder." \
      "Shiny Server and the Python servers all run the app from the project's top level."
  fi
  [[ -f "$path" ]] || entry_file_fail "no such file in $PROJECT_DIR."

  local inferred=""
  case "$ENTRY_FILE" in
    *.R|*.r)
      inferred="r-shiny"
      if ! file_calls_shiny_app "$path" && ! file_defines_ui_and_server "$path"; then
        entry_file_fail "doesn't look like a Shiny app." \
          "Expected a shinyApp(...) call, or both a 'ui <-' and a 'server <-' definition."
      fi
      # Shiny Server always runs app.R when there is one, and the build adds
      # an app.R to run any other choice — the two can't both be app.R.
      if [[ "$ENTRY_FILE" != "app.R" && -f "$PROJECT_DIR/app.R" ]]; then
        entry_file_fail "can't be used while this folder also contains an app.R." \
          "Shiny Server always runs app.R. Either choose app.R, or rename app.R" \
          "(e.g. to old_app.R) so the file you chose is the one that runs."
      fi
      ;;
    *.py)
      local matches=() fw
      for fw in dash python-shiny streamlit; do
        case "$fw" in
          dash)         file_is_dash "$path"         && matches+=("$fw") ;;
          python-shiny) file_is_python_shiny "$path" && matches+=("$fw") ;;
          streamlit)    file_is_streamlit "$path"    && matches+=("$fw") ;;
        esac
      done
      if [[ -n "$FRAMEWORK" ]]; then
        inferred="$FRAMEWORK"
      elif [[ "${#matches[@]}" -eq 1 ]]; then
        inferred="${matches[0]}"
      elif [[ "${#matches[@]}" -eq 0 ]]; then
        entry_file_fail "doesn't look like a Dash, Python Shiny or Streamlit app." \
          "If it is one, also set FRAMEWORK=dash|python-shiny|streamlit."
      else
        entry_file_fail "has signals for more than one framework (${matches[*]})." \
          "Set FRAMEWORK=dash|python-shiny|streamlit as well, to say which."
      fi
      # gunicorn and `shiny run` import the file as a Python module, so a
      # name like my-app.py can't be served under that name.
      if [[ "$inferred" != "streamlit" && ! "${ENTRY_FILE%.py}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        entry_file_fail "isn't a valid Python module name." \
          "$inferred imports the main file as a module, so its name may only use letters," \
          "digits and underscores (and not start with a digit). Rename it, e.g. to app.py."
      fi
      ;;
    *)
      entry_file_fail "must be an .R or .py file." ;;
  esac

  if [[ -n "$FRAMEWORK" && "$FRAMEWORK" != "$inferred" ]]; then
    entry_file_fail "is a $inferred file, but FRAMEWORK=$FRAMEWORK was set."
  fi
  FRAMEWORK="$inferred"
  ENTRY_STATE="chosen"
  if [[ "$FRAMEWORK" == "r-shiny" ]]; then
    ENTRY_CANDIDATES=""
    detect_r_shiny >/dev/null || true
    # detect_r_shiny may have filled in its own idea of the entry point.
    # The explicit choice wins.
    ENTRY_FILE="${path##*/}"
    ENTRY_STATE="chosen"
    ENTRY_POINT_DESC="$ENTRY_FILE"
  else
    detect_python_framework "$FRAMEWORK" || true
    ENTRY_CANDIDATES="${PY_CANDIDATES:-}"
    ENTRY_FILE="${path##*/}"
    ENTRY_POINT_DESC="$FRAMEWORK entry point ($ENTRY_FILE)"
  fi
  case "/$ENTRY_CANDIDATES/" in
    */"$ENTRY_FILE"/*) ;;
    *) add_entry_candidate "$ENTRY_FILE" ;;
  esac
}

# A forced FRAMEWORK bypasses *framework* detection, but the main file still
# has to be resolved. For the Python frameworks it becomes the ENTRY_MODULE
# build-arg, and without it the Dockerfile's ARG default silently wins — for
# Streamlit that default is `streamlit_app.py`, so forcing the framework on a
# project whose entry is `app.py` used to build successfully and then
# crash-loop with "File does not exist: streamlit_app.py". For R it decides
# whether build_image() needs to add an app.R. Try the same content-based
# detector first (it also confirms the forced choice looks right), then fall
# back to the framework's conventional filenames.
resolve_forced_entry_file() {
  local framework="$1" candidate
  if [[ "$framework" == "r-shiny" ]]; then
    detect_r_shiny && return 0
    echo "FRAMEWORK=r-shiny was forced, but no R Shiny app was found in $PROJECT_DIR —" >&2
    echo "no app.R, ui.R/server.R, Shiny .Rmd, or .R file calling shinyApp()." >&2
    echo "Set ENTRY_FILE=<your main .R file> to say which file runs the app." >&2
    exit 1
  fi

  if detect_python_framework "$framework"; then
    ENTRY_CANDIDATES="$PY_CANDIDATES"
    return 0
  fi

  local candidates=()
  case "$framework" in
    streamlit) candidates=(streamlit_app.py app.py) ;;
    *)         candidates=(app.py) ;;
  esac
  for candidate in "${candidates[@]}"; do
    if [[ -f "$PROJECT_DIR/$candidate" ]]; then
      ENTRY_FILE="$candidate"
      ENTRY_CANDIDATES="$candidate"
      echo "FRAMEWORK=$framework was forced; no $framework signal found in the project's" >&2
      echo ".py files, so falling back to $candidate as the entry point." >&2
      return 0
    fi
  done
  echo "FRAMEWORK=$framework was forced, but no usable entry point was found in" >&2
  echo "$PROJECT_DIR — expected one of: ${candidates[*]}." >&2
  echo "Set ENTRY_FILE=<your main .py file> to name it." >&2
  exit 1
}

# Sets FRAMEWORK, ENTRY_POINT_DESC, ENTRY_FILE, ENTRY_STATE and
# ENTRY_CANDIDATES (see the header).
# An explicit FRAMEWORK env var (mirroring BASE_IMAGE's override pattern)
# bypasses framework detection — the escape hatch for ambiguous projects or
# a wrong guess — but is still validated against the supported set, since a
# typo (e.g. FRAMEWORK=Dash) would otherwise surface much later as a raw
# "cp: Dockerfile.Dash: No such file" from inside build_image().
detect_framework() {
  # Read by build_and_run.sh, which the linter can't see from here (same
  # reasoning as the ENTRY_POINT_DESC disable at the bottom).
  # shellcheck disable=SC2034
  ENTRY_STATE="conventional"
  ENTRY_CANDIDATES=""
  PY_CANDIDATES=""

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
  fi

  if [[ -n "${ENTRY_FILE:-}" ]]; then
    resolve_chosen_entry_file
    return 0
  fi

  if [[ -n "${FRAMEWORK:-}" ]]; then
    resolve_forced_entry_file "$FRAMEWORK"
    if [[ "$FRAMEWORK" != "r-shiny" ]]; then
      ENTRY_POINT_DESC="$ENTRY_FILE (forced via FRAMEWORK=$FRAMEWORK)"
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
  local dash_cands="" pyshiny_cands="" streamlit_cands=""
  if detect_python_framework dash;         then dash_entry="$ENTRY_FILE";      dash_cands="$PY_CANDIDATES"; fi
  if detect_python_framework python-shiny; then pyshiny_entry="$ENTRY_FILE";   pyshiny_cands="$PY_CANDIDATES"; fi
  if detect_python_framework streamlit;    then streamlit_entry="$ENTRY_FILE"; streamlit_cands="$PY_CANDIDATES"; fi
  ENTRY_FILE=""

  local match_count=0
  [[ -n "$dash_entry" ]]      && match_count=$((match_count + 1))
  [[ -n "$pyshiny_entry" ]]   && match_count=$((match_count + 1))
  [[ -n "$streamlit_entry" ]] && match_count=$((match_count + 1))

  if [[ "$match_count" -gt 1 ]]; then
    echo "Multiple framework signals detected in $PROJECT_DIR — can't auto-detect confidently:" >&2
    [[ -n "$dash_entry" ]]      && echo "  Plotly Dash signal in $dash_entry" >&2
    [[ -n "$pyshiny_entry" ]]   && echo "  Python Shiny signal in $pyshiny_entry" >&2
    [[ -n "$streamlit_entry" ]] && echo "  Streamlit signal in $streamlit_entry" >&2
    echo "Set ENTRY_FILE=<your main .py file> (and FRAMEWORK=dash|python-shiny|streamlit" >&2
    echo "if that file alone is still ambiguous) and re-run." >&2
    exit 1
  fi

  if [[ -n "$dash_entry" ]]; then
    FRAMEWORK="dash"
    ENTRY_FILE="$dash_entry"
    ENTRY_CANDIDATES="$dash_cands"
  elif [[ -n "$pyshiny_entry" ]]; then
    FRAMEWORK="python-shiny"
    ENTRY_FILE="$pyshiny_entry"
    ENTRY_CANDIDATES="$pyshiny_cands"
  elif [[ -n "$streamlit_entry" ]]; then
    FRAMEWORK="streamlit"
    ENTRY_FILE="$streamlit_entry"
    ENTRY_CANDIDATES="$streamlit_cands"
  else
    echo "Couldn't find a dashboard's main file in $PROJECT_DIR — no .R file calling" >&2
    echo "shinyApp(), and no recognizable Dash/Python Shiny/Streamlit .py file." >&2
    echo >&2
    echo "What's looked for:" >&2
    echo "  R Shiny:       any .R file calling shinyApp(), ui.R + server.R, or an .Rmd" >&2
    echo "                 with 'runtime: shiny'" >&2
    echo "  Plotly Dash:   a .py file with 'import dash' and 'server = app.server'" >&2
    echo "  Python Shiny:  a .py file with 'from shiny import App' and a top-level App(...)" >&2
    echo "  Streamlit:     a .py file with 'import streamlit'" >&2
    echo >&2
    echo "If your app is one of these, set ENTRY_FILE=<your main file> to say which" >&2
    echo "file runs it." >&2
    exit 1
  fi

  # Consumed by build_and_run.sh (this file's documented output contract,
  # see the header), which the linter can't see when checking this file on
  # its own. Kept targeted rather than file-wide so a genuinely unused
  # variable added later still gets flagged.
  # shellcheck disable=SC2034
  ENTRY_POINT_DESC="$FRAMEWORK entry point ($ENTRY_FILE)"
}
