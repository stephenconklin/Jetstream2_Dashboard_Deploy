#!/usr/bin/env bash
# Advisory checks over a project's code for habits that work on a
# researcher's own computer and break on the server: paths to their own
# disk, setwd(), file names whose capitalisation only matches on a
# case-insensitive Mac/Windows filesystem, and so on. Sourced by
# build_and_run.sh — not meant to be run directly.
#
# Strictly advisory. Every check here is a regex over source text, not an
# understanding of the program, so it can be wrong in both directions — a
# note is a "worth a look", never a reason to refuse a deploy. Read-only and
# safe above the --dry-run gate. Never fails its caller: everything that can
# fail is guarded, since build_and_run.sh runs under `set -euo pipefail`.
#
# Reads PROJECT_DIR and DATA_SUBDIR. Sets:
#   CODE_NOTES       - newline-separated "file:line: message" notes
#   CODE_NOTE_COUNT  - how many there are (capped at CODE_NOTE_MAX)
#   DATA_DIR_REFS    - how many quoted file names start with DATA_SUBDIR/
#                      while the project has no such folder: data the code
#                      expects to be attached from somewhere else. Nonzero
#                      means publishing without DATA_DIR will start an app
#                      that can't find its files.

CODE_NOTE_MAX=25

add_code_note() {
  [[ "$CODE_NOTE_COUNT" -ge "$CODE_NOTE_MAX" ]] && return 0
  # Same file:line can trip the same check twice (two strings on one line).
  case $'\n'"$CODE_NOTES" in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  CODE_NOTES+="$1"$'\n'
  CODE_NOTE_COUNT=$((CODE_NOTE_COUNT + 1))
}

# Code files worth reading: R, R Markdown and Python, a few levels deep (R
# apps commonly keep modules in R/), skipping folders that hold no code of
# the project's own and can be huge — a data/ folder especially.
list_code_files() {
  find "$PROJECT_DIR" -maxdepth 3 \
    \( -name .git -o -name renv -o -name data -o -name node_modules \
       -o -name .venv -o -name venv -o -name __pycache__ -o -name .Rproj.user \
       -o -name rsconnect \) -prune \
    -o -type f \( -name '*.R' -o -name '*.r' -o -name '*.Rmd' -o -name '*.rmd' -o -name '*.py' \) \
    -print 2>/dev/null | sort || true
}

# Prints "line:text" for lines matching an ERE, skipping lines that are
# entirely comments (# in R, Python and the code chunks of an .Rmd).
grep_code_lines() {
  grep -nE "$1" "$2" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

# A path on someone's own computer, or anywhere the container can't see: a
# Windows drive letter, a UNC share, a Mac home or volume, a Linux home, a
# mount point, or ~. Inside the container the app sees only its own folder
# and the data folder chosen in step 2.
ABS_PATH_RE='["'"'"']([A-Za-z]:[/\\]|\\\\\\\\|/Users/|/Volumes/|/home/|/media/|/mnt/|~/)'

# A quoted relative file name with a data-ish extension — the files an app
# reads, as opposed to every string in the program.
DATA_FILE_RE='["'"'"'][^"'"'"'<>|*?]+\.(csv|tsv|txt|xlsx|xlsm|xls|shp|gpkg|geojson|json|rds|RDS|rda|RData|Rdata|parquet|feather|tif|tiff|nc|sqlite|db|dbf|kml|kmz|zip)["'"'"']'

# Is a quoted file name present under PROJECT_DIR with exactly that
# spelling? Prints "ok", "missing", or the real spelling when only the
# capitalisation differs. Compares strings rather than testing -e, which on
# a case-insensitive Mac would say yes to the wrong spelling — the very bug
# this exists to catch, since the server's Linux filesystem won't.
resolve_project_file() {
  local rel="$1" depth found
  depth=$(( $(printf '%s' "$rel" | tr -cd '/' | wc -c) + 1 ))
  found="$(find "$PROJECT_DIR" -mindepth "$depth" -maxdepth "$depth" \
             -ipath "$PROJECT_DIR/$rel" 2>/dev/null | head -n 1 || true)"
  if [[ -z "$found" ]]; then
    echo missing
  elif [[ "$found" == "$PROJECT_DIR/$rel" ]]; then
    echo ok
  else
    echo "${found#"$PROJECT_DIR"/}"
  fi
}

check_project_code() {
  CODE_NOTES=""
  CODE_NOTE_COUNT=0
  DATA_DIR_REFS=0
  local subdir="${DATA_SUBDIR:-data}"
  local has_data_dir=0
  [[ -d "$PROJECT_DIR/$subdir" ]] && has_data_dir=1

  local f rel hit line text is_r
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    rel="${f#"$PROJECT_DIR"/}"
    is_r=0
    case "$f" in *.py) ;; *) is_r=1 ;; esac

    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      line="${hit%%:*}"
      local where
      where="$(printf '%s\n' "${hit#*:}" | grep -oE "${ABS_PATH_RE}[^\"']*" | head -n 1 || true)"
      add_code_note "$rel:$line: uses \"${where:1}\" — a location on your own computer (or outside the app) that the server can't see. Put the file in your app folder and use just its name, or use your data folder (step 2)."
    done < <(grep_code_lines "$ABS_PATH_RE" "$f")

    if [[ "$is_r" -eq 1 ]]; then
      while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        add_code_note "${rel}:${hit%%:*}: calls setwd(). On the server the app already runs from its own folder, and that folder won't exist there — remove this line."
      done < <(grep_code_lines '\bsetwd[[:space:]]*\(' "$f")

      while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        add_code_note "${rel}:${hit%%:*}: calls install.packages(). Publishing installs your packages for you; installing again every time the app starts is slow and can fail. Remove this line."
      done < <(grep_code_lines '\binstall\.packages[[:space:]]*\(' "$f")

      while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        add_code_note "${rel}:${hit%%:*}: calls runApp(). The server starts your app itself, and a second runApp() keeps it from ever finishing starting up. Remove this line (keep the shinyApp(...) call)."
      done < <(grep_code_lines '\brunApp[[:space:]]*\(' "$f")
    fi

    # Quoted data file names, checked against what's actually in the folder.
    local match name state
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      line="${hit%%:*}"
      text="${hit#*:}"
      while IFS= read -r match; do
        [[ -n "$match" ]] || continue
        name="${match:1:${#match}-2}"
        name="${name#./}"
        case "$name" in
          *://*|/*|~*|[A-Za-z]:*|*\\*|*%*|*\{*|*\$*) continue ;;
        esac
        # Read from the data folder, which is mounted from elsewhere at run
        # time when the project doesn't ship one — nothing to check here.
        if [[ "$has_data_dir" -eq 0 && "$name" == "$subdir"/* ]]; then
          DATA_DIR_REFS=$((DATA_DIR_REFS + 1))
          continue
        fi
        state="$(resolve_project_file "$name")"
        case "$state" in
          ok) ;;
          missing)
            add_code_note "$rel:$line: reads \"$name\", which isn't in your app folder. If it's a data file, add it to the folder (or your data folder in step 2)." ;;
          *)
            add_code_note "$rel:$line: reads \"$name\", but the file is called \"$state\". Your computer ignores the difference in capital letters; the server doesn't. Make them match exactly." ;;
        esac
      done < <(printf '%s\n' "$text" | grep -oE "$DATA_FILE_RE" || true)
    done < <(grep_code_lines "$DATA_FILE_RE" "$f")
  done < <(list_code_files)
  return 0
}
