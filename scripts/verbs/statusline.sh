# shellcheck shell=bash disable=SC2154
#
# orca statusline — the run board for a custom Claude Code statusLine
# command. Sourced by orca.sh; lib.sh is already loaded. Reads the
# harness session JSON on stdin, finds the active feature run under the
# project's .orca (active = a spec-carrying *-feat-* run dir whose
# .lock/owner lease reads live), and prints two rows:
#
#   orca · <slug> · <merged>/<total> merged · <elapsed>
#   W1 ✓merged  W2 ▸implementing  W3 ▸review#2  W4 ⏸W2,W3
#
# Data sources (plans/statusline-progress.md): item order and deps come
# from the LAST `**Workflow args:**` line at the tail of spec.md; the
# in-flight stage word from <run>/status/<id> (seeded `pending`, written
# by the stage agents, terminal words by reconciliation); merged.tsv
# outranks the status word (artifact-first); the review round marker is
# the count of reviews/<id>-*.json (2 files = the round-0 artifact plus
# its archive = the second review is running); elapsed comes from the
# run directory NAME's timestamp (creation time — mtime moves on every
# write).
#
# Constraints: this runs every refreshInterval seconds, so it must be
# cheap — directory listings and a handful of small reads, no git — and
# it must never fail loudly: no active run prints nothing, a malformed
# run dir prints what parses, and the exit status is always 0. The
# renderer understands feature runs only; any other run shape prints
# nothing. It never writes anywhere.

sl_input="$(cat 2>/dev/null || true)"

# workspace.project_dir is where the session was launched — not the repo
# root, so walk upward to the first directory containing .orca (no git),
# giving up silently at $HOME or /. Absent or unparseable stdin falls
# back to the working directory (makes the verb testable by hand).
sl_project_dir="$(printf '%s' "$sl_input" | tr -d '\n' |
  sed -n 's/.*"project_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[ -n "$sl_project_dir" ] || sl_project_dir="$PWD"
[ -d "$sl_project_dir" ] || exit 0

sl_root="$sl_project_dir"
while :; do
  [ -d "$sl_root/.orca" ] && break
  case "$sl_root" in "$HOME" | "/" | "") sl_root="" && break ;; esac
  sl_root="${sl_root%/*}"
  [ -n "$sl_root" ] || sl_root="/"
done
[ -n "$sl_root" ] || exit 0

# The last live-leased feature run wins (the glob sorts by the timestamp
# prefix, so ties — which the lease's single-writer rule prevents anyway
# — resolve to the newest). Released or stale leases mean no run is in
# flight: the board goes quiet the moment the owning session lets go.
sl_run=""
for sl_d in "$sl_root/.orca"/*-feat-*; do
  [ -d "$sl_d" ] && [ -f "$sl_d/spec.md" ] || continue
  case "$(lease_read "$sl_d")" in live*) sl_run="$sl_d" ;; esac
done
[ -n "$sl_run" ] || exit 0

sl_name="${sl_run##*/}" # YYYYMMDD-HHMMSS-feat-<slug>
sl_slug="${sl_name#*-feat-}"
sl_ts="${sl_name%%-feat-*}"

sl_elapsed=""
if [[ "$sl_ts" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
  # Epoch conversion needs both spellings: BSD `date -j -f`, GNU `date -d`.
  sl_epoch="$(date -j -f '%Y%m%d-%H%M%S' "$sl_ts" +%s 2>/dev/null)" ||
    sl_epoch="$(date -d "${sl_ts:0:4}-${sl_ts:4:2}-${sl_ts:6:2} ${sl_ts:9:2}:${sl_ts:11:2}:${sl_ts:13:2}" +%s 2>/dev/null)" ||
    sl_epoch=""
  if [ -n "$sl_epoch" ]; then
    sl_mins=$((($(date +%s) - sl_epoch) / 60))
    if [ "$sl_mins" -ge 0 ]; then
      if [ "$sl_mins" -ge 60 ]; then sl_elapsed="$((sl_mins / 60))h$((sl_mins % 60))m"; else sl_elapsed="${sl_mins}m"; fi
    fi
  fi
fi

# Items as `<id><TAB><dep,dep>` lines from the args JSON: split the line
# at every `"id":` key, then read the quoted W/F token and the deps
# array out of each segment. Heuristic on purpose — a title containing a
# literal `"id":` garbles its own row and nothing else (render what
# parses). Items must keep args order, so no sorting here.
sl_args="$(grep '^\*\*Workflow args:\*\*' "$sl_run/spec.md" 2>/dev/null | tail -1)"
sl_items=""
[ -n "$sl_args" ] && sl_items="$(printf '%s' "$sl_args" | awk '
  {
    gsub(/"id"[ \t]*:/, SUBSEP "\"id\":")
    n = split($0, seg, SUBSEP)
    for (i = 2; i <= n; i++) {
      s = seg[i]
      if (!match(s, /"[WF][0-9]+"/)) continue
      id = substr(s, RSTART + 1, RLENGTH - 2)
      deps = ""
      if (match(s, /"deps"[ \t]*:[ \t]*\[[^]]*\]/)) {
        d = substr(s, RSTART, RLENGTH)
        while (match(d, /"[WF][0-9]+"/)) {
          deps = deps (deps == "" ? "" : ",") substr(d, RSTART + 1, RLENGTH - 2)
          d = substr(d, RSTART + RLENGTH)
        }
      }
      print id "\t" deps
    }
  }' 2>/dev/null || true)"
# No args line (a malformed or half-written run dir): fall back to the
# status directory's own file list — ids only, deps unknown.
if [ -z "$sl_items" ] && [ -d "$sl_run/status" ]; then
  sl_ids=""
  for sl_f in "$sl_run/status"/*; do
    sl_id="${sl_f##*/}"
    [[ "$sl_id" =~ ^[WF][0-9]+$ ]] || continue
    sl_ids="$sl_ids$sl_id
"
  done
  sl_items="$(printf '%s' "$sl_ids" | sort -k1.2n)"
fi

sl_total=0
sl_merged=0
sl_row=""
while IFS=$'\t' read -r sl_id sl_deps; do
  [ -n "$sl_id" ] || continue
  sl_total=$((sl_total + 1))
  sl_word="pending"
  sl_reason=""
  if [ -f "$sl_run/status/$sl_id" ]; then
    IFS= read -r sl_line <"$sl_run/status/$sl_id" || true
    sl_word="${sl_line%% *}"
    [ -n "$sl_word" ] || sl_word="pending"
    case "$sl_line" in
      blocked*)
        sl_reason="${sl_line#blocked}"
        sl_reason="${sl_reason# }"
        sl_reason="${sl_reason#— }"
        ;;
    esac
  fi
  # Artifact-first: a merged.tsv row outranks whatever the file says.
  grep -q "^$sl_id	" "$sl_run/merged.tsv" 2>/dev/null && sl_word="merged"
  case "$sl_word" in
    merged)
      sl_merged=$((sl_merged + 1))
      sl_cell="✓merged"
      ;;
    cut) sl_cell="✗cut" ;;
    blocked)
      sl_cell="✗blocked"
      if [ -n "$sl_reason" ]; then
        [ "${#sl_reason}" -gt 24 ] && sl_reason="${sl_reason:0:23}…"
        sl_cell="$sl_cell:$sl_reason"
      fi
      ;;
    review)
      sl_n=0
      for sl_f in "$sl_run/reviews/$sl_id"-*.json; do
        [ -f "$sl_f" ] && sl_n=$((sl_n + 1))
      done
      if [ "$sl_n" -ge 2 ]; then sl_cell="▸review#$sl_n"; else sl_cell="▸review"; fi
      ;;
    pending)
      sl_blockers=""
      if [ -n "$sl_deps" ]; then
        for sl_d in $(printf '%s' "$sl_deps" | tr ',' ' '); do
          grep -q "^$sl_d	" "$sl_run/merged.tsv" 2>/dev/null || sl_blockers="$sl_blockers,$sl_d"
        done
      fi
      if [ -n "$sl_blockers" ]; then sl_cell="⏸${sl_blockers#,}"; else sl_cell="·pending"; fi
      ;;
    *) sl_cell="▸$sl_word" ;;
  esac
  sl_row="$sl_row$sl_id $sl_cell  "
done <<<"$sl_items"

if [ "$sl_total" -gt 0 ]; then
  sl_hdr="orca · $sl_slug · $sl_merged/$sl_total merged"
else
  sl_hdr="orca · $sl_slug"
fi
[ -n "$sl_elapsed" ] && sl_hdr="$sl_hdr · $sl_elapsed"
printf '%s\n' "$sl_hdr"
if [ -n "$sl_row" ]; then
  sl_row="${sl_row%  }"
  printf '%s\n' "$sl_row"
fi
exit 0
