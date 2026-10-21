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

# Prints "line:text" for every line of a file with its # comment removed (R,
# Python and the code chunks of an .Rmd). Only a # outside quotes starts a
# comment, so colours like "#2a78d6" survive; a trailing comment goes, so
# "x <- 1  # runApp() sets the folder" no longer reads as a runApp() call.
# One line at a time, so a string spanning lines can confuse it — advisory.
strip_code_comments() {
  awk '{
    out = ""; q = ""; n = length($0)
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (q != "") {
        out = out c
        if (c == "\\") { i++; out = out substr($0, i, 1) }
        else if (c == q) q = ""
        continue
      }
      if (c == "#") break
      if (c == "\"" || c == "'"'"'") q = c
      out = out c
    }
    print NR ":" out
  }' "$1" 2>/dev/null || true
}

# Prints "line:text" for lines whose code (comments removed) matches an ERE.
grep_code_lines() {
  strip_code_comments "$2" | grep -E "^[0-9]+:.*($1)" || true
}

# A path on someone's own computer, or anywhere the container can't see: a
# Windows drive letter, a UNC share, a Mac home or volume, a Linux home, a
# mount point, or ~. Inside the container the app sees only its own folder
# and the data folder chosen in step 2.
ABS_PATH_RE='["'"'"']([A-Za-z]:[/\\]|\\\\\\\\|/Users/|/Volumes/|/home/|/media/|/mnt/|~/)'

# A quoted relative file name with a data-ish extension — the files an app
# reads, as opposed to every string in the program.
DATA_FILE_RE='["'"'"'][^"'"'"'<>|*?]+\.(csv|tsv|txt|xlsx|xlsm|xls|shp|gpkg|geojson|json|rds|RDS|rda|RData|Rdata|parquet|feather|tif|tiff|nc|sqlite|db|dbf|kml|kmz|zip)["'"'"']'

# Every path in the project, relative to it, data folder included, listed
# once per check rather than once per name. Code commonly builds a path in
# pieces — file.path(DATA, "area", "area.geojson") — so a quoted name can
# live in any subfolder, not only where it's written.
list_project_paths() {
  find "$PROJECT_DIR" \
    \( -name .git -o -name renv -o -name node_modules -o -name .venv -o -name venv \
       -o -name __pycache__ -o -name .Rproj.user -o -name rsconnect \) -prune \
    -o -print 2>/dev/null | head -n 200000 \
    | awk -v p="$PROJECT_DIR/" 'index($0, p) == 1 { print substr($0, length(p) + 1) }' || true
}

# Where a quoted file name will be looked for, and whether it's there.
#
# A name is either a WHOLE path, read as written from the folder the app runs
# in — read.csv("counts.csv") — or one PIECE of a path built at run time —
# file.path(DATA, "area", "area.geojson") — whose leading folders the text
# doesn't say. quoted_data_files() tells them apart by what's in front of the
# quote: a whole path opens a call or follows = or <-, a piece follows a
# comma (or a + or a paste). So a whole path is checked where it will
# actually be read from, and a piece anywhere in the project, which is the
# most that can honestly be said of it.
#
# Compares strings rather than testing -e, which on a case-insensitive Mac
# would say yes to the wrong spelling — the very bug this exists to catch,
# since the server's Linux filesystem won't. Reads PROJECT_PATHS. Prints one
# of: ok | missing | case:<real spelling> | elsewhere:<path in the project>.
resolve_project_file() {
  local expected="$1" name="$2"
  printf '%s\n' "$PROJECT_PATHS" | awk -v exp_path="$expected" -v rel="$name" '
    BEGIN { lr = tolower(rel); n = length(rel); le = tolower(exp_path) }
    {
      if (exp_path != "") {
        if ($0 == exp_path) { exact = 1; exit }
        if (tolower($0) == le && casefix == "") casefix = $0
      }
      tail = substr($0, length($0) - n + 1)
      if (length($0) < n || tolower(tail) != lr) next
      if (length($0) > n && substr($0, length($0) - n, 1) != "/") next
      if (tail == rel) {
        if (exp_path == "") { exact = 1; exit }
        if (elsewhere == "") elsewhere = $0
      } else if (exp_path == "" && casefix == "") casefix = tail
    }
    END {
      if (exact) print "ok"
      else if (casefix != "") print "case:" casefix
      else if (elsewhere != "") print "elsewhere:" elsewhere
      else print "missing"
    }' || echo ok
}

# The project-relative path a whole name is read from: the app's folder
# joined to the name, with ./ and ../ resolved. Prints nothing when ../
# climbs out of the project, which leaves the name to be treated as a piece.
expected_project_path() {
  local IFS=/ part
  local -a out=()
  # shellcheck disable=SC2086  # splitting on / is the point
  for part in $1 $2; do
    case "$part" in
      ""|.) ;;
      ..) [[ "${#out[@]}" -gt 0 ]] || return 0
          unset "out[$(( ${#out[@]} - 1 ))]" ;;
      *) out+=("$part") ;;
    esac
  done
  printf '%s\n' "${out[*]}"
}

# A project-relative path as the app's own code would write it, from the
# folder it runs in: as is at the top level, with ../ in front for an app in
# a subfolder unless the file is inside that subfolder.
path_from_app_base() {
  local base="$1" path="$2" ups=""
  [[ -z "$base" ]] && { printf '%s\n' "$path"; return 0; }
  if [[ "$path" == "$base"/* ]]; then
    printf '%s\n' "${path#"$base"/}"
    return 0
  fi
  local IFS=/ part
  # shellcheck disable=SC2086  # splitting on / is the point
  for part in $base; do [[ -n "$part" ]] && ups+="../"; done
  printf '%s\n' "$ups$path"
}

# Prints "whole<TAB>name" or "piece<TAB>name" for each quoted data file name
# in a line of code (see resolve_project_file for the difference). ENVIRON
# rather than -v for the pattern, since -v would eat its backslashes.
quoted_data_files() {
  printf '%s\n' "$1" | RE="$DATA_FILE_RE" awk '{
    s = $0; re = ENVIRON["RE"]; before = ""
    while (match(s, re)) {
      pre = before substr(s, 1, RSTART - 1)
      sub(/[ \t]+$/, "", pre)
      last = substr(pre, length(pre), 1)
      kind = (pre == "" || last == "(" || last == "=" || substr(pre, length(pre) - 1) == "<-") ? "whole" : "piece"
      print kind "\t" substr(s, RSTART + 1, RLENGTH - 2)
      before = pre substr(s, RSTART, RLENGTH)
      s = substr(s, RSTART + RLENGTH)
    }
  }' 2>/dev/null || true
}

check_project_code() {
  CODE_NOTES=""
  CODE_NOTE_COUNT=0
  DATA_DIR_REFS=0
  local subdir="${DATA_SUBDIR:-data}"
  local has_data_dir=0
  [[ -d "$PROJECT_DIR/$subdir" ]] && has_data_dir=1
  PROJECT_PATHS="$(list_project_paths)"
  # The folder a whole path is read from: the main file's own folder for an R
  # app in a subfolder (Shiny runs it from there), the top level otherwise —
  # the Python servers start there too.
  local app_base="" where_app="your app folder"
  if [[ "${FRAMEWORK:-}" == "r-shiny" && "${ENTRY_FILE:-}" == */* ]]; then
    app_base="${ENTRY_FILE%/*}"
    where_app="$app_base/, where your app runs from"
  fi

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
    local kind name state expected
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      line="${hit%%:*}"
      text="${hit#*:}"
      while IFS=$'\t' read -r kind name; do
        [[ -n "$name" ]] || continue
        name="${name#./}"
        case "$name" in
          *://*|/*|~*|[A-Za-z]:*|*\\*|*%*|*\{*|*\$*) continue ;;
          # A path up out of the app's folder is a real path, checked below.
          ../*) ;;
          # One piece of a name built at run time, paste0(sp, "_meta.json"):
          # no file is called that, so there's nothing to look for.
          [_.-]*) continue ;;
        esac
        # Read from the data folder, which is mounted from elsewhere at run
        # time when the project doesn't ship one — nothing to check here.
        if [[ "$has_data_dir" -eq 0 && "$name" == "$subdir"/* ]]; then
          DATA_DIR_REFS=$((DATA_DIR_REFS + 1))
          continue
        fi
        expected=""
        [[ "$kind" == "whole" ]] && expected="$(expected_project_path "$app_base" "$name")"
        state="$(resolve_project_file "$expected" "$name")"
        case "$state" in
          ok) ;;
          missing)
            add_code_note "$rel:$line: reads \"$name\", which isn't in ${where_app}. If it's a data file, add it to the folder (or your data folder in step 2)." ;;
          elsewhere:*)
            add_code_note "$rel:$line: reads \"$name\", which isn't in ${where_app}, but there's one at \"${state#elsewhere:}\" in your project. If that's the one, write \"$(path_from_app_base "$app_base" "${state#elsewhere:}")\" instead." ;;
          case:*)
            # A whole path's spelling is reported as its code would write it.
            local real="${state#case:}"
            [[ "$kind" == "whole" ]] && real="$(path_from_app_base "$app_base" "$real")"
            add_code_note "$rel:$line: reads \"$name\", but the file is called \"$real\". Your computer ignores the difference in capital letters; the server doesn't. Make them match exactly." ;;
        esac
      done < <(quoted_data_files "$text")
    done < <(grep_code_lines "$DATA_FILE_RE" "$f")
  done < <(list_code_files)
  return 0
}
