# shellcheck shell=bash disable=SC2154
#
# orca rounds — the deterministic round engine: turns a rounds
# directory's review and response files into one next action, so the
# session never reads a findings file or applies the gate rules itself.
#
# Usage:
#   orca.sh rounds next <dir>
#   orca.sh rounds summary <findings-file>
#   orca.sh rounds tree <dir>
#   orca.sh rounds facts <dir>
#   orca.sh rounds record <dir> checks-override <reason>
#   orca.sh rounds record <dir> continue <N> <reason>
#   orca.sh rounds record <dir> decline <title> <file> <reason>
#   orca.sh rounds record <dir> rereview <N>
#
# <dir> is an absolute, existing directory inside a .orca/ (lib.sh's
# is_run_dir), laid out as:
#
#   reviews/round-<N>.json     reviewer artifacts, N from 1 (the findings
#                              schema: severity, file, line, title, body,
#                              fix_location)
#   responses/round-<N>.json   implementer dispositions, N from 0 — round
#                              0 is the initial implement, round N answers
#                              review N: {checks{commands,pass,failure},
#                              findings[{title,file,outcome,reason}],
#                              followups[], status, questions}
#   declines.md                settled declines, written by `record`
#   overrides                  recorded user rulings, written by `record`
#   action                     the last `next` result, written by `next`
#   worktree                   optional: the work tree the rounds build
#                              (written by `objective phase-start`); when
#                              present, `next` guards the tree (below)
#   trees                      the tree guard's record, written by `next`
#
# Rounds are contiguous: responses 0..P and reviews 1..M with M = P or
# M = P + 1. A gap, a reviews/round-0.json, reviews without a
# responses/round-0.json, or the two sequences out of step is
# BAD_ROUNDS. Files not named round-<N>.json (N canonical, below a
# million) are ignored.
#
# Every file is parsed through scripts/findings.awk (over
# json-tokens.awk); a malformed, truncated, or empty one, or a response
# missing any part of the schema above (findings.awk's response=1: every
# key present once and of its type, status done, needs_input, or
# infeasible, every outcome fixed, disputed, declined, or out_of_scope),
# is BAD_JSON — never a guessed action. So is a response with status
# done that has no disposition (title+file) for a finding of the review
# it answers; an unfinished one may list what it disposed of so far.
#
# A review's findings split three ways:
#   out of scope  fix_location exactly `another work item`, any severity:
#                 never gates, never counts toward a stall
#   settled       title+file in declines.md: neither gating nor minor
#   gating        severity not recognizably medium/low (unknown gates)
#   minor         medium/low
# Titles and files match after control bytes become spaces, on both the
# reading and the recording side.
#
# next — reads every round file, declines.md, and overrides; it writes
#   <dir>/action (temp file + rename; an action path that is a symlink or
#   not a regular file is WRITE_ERROR, nothing written), and with a
#   worktree file the tree guard's records (below). With
#   P the latest response and M the latest review: no
#   responses/round-0.json is `implement 0`. Otherwise the rounds are
#   walked oldest first, r = 0..P, and the first gate not resolved
#   stops the walk — so a round's gate holds whatever later reviews or
#   responses already exist:
#
#   response r status needs_input         ask-questions r — unfinished:
#                                           the session puts its questions
#                                           to the user; the answered pass
#                                           rewrites responses/round-<r>.json
#   response r status infeasible          infeasible r — the session
#                                           tells the user and stops
#   response r checks.pass=false, its     fix-checks r — the fixed pass
#     checks.failure not one a recorded     rewrites responses/round-<r>.json
#     checks-override accepted
#   r = 0 and no review 1                 review 1
#   (r >= 1, response r answering review r:)
#   response r disputes a finding that    ask-disputes r — `disputed`
#     is not settled and not a minor or     entries of response r not in
#     out-of-scope finding of review r      declines.md; a rejected
#                                           dispute's fix rewrites
#                                           responses/round-<r>.json
#   review r gating, r >= 2, no           stalled r
#     `continue r`, and gating(r) >=
#     gating(r-1) or a gating title+file
#     of review r is one a response
#     before r marked `fixed`
#   review r gating, no review r+1        review r+1
#   review r clean, no review r+1         commit r
#   otherwise                             on to round r+1
#
#   After the walk, review M = P + 1 has no response yet:
#   review M gating                       fix M
#   review M minor                        fix-minor M
#   review M clean                        commit M
#
#   Every round is judged against today's declines.md and overrides, so
#   a ruling recorded later can change an earlier round's counts — a
#   stall it opens is asked like any other, never skipped.
#   The finished minor pass is not a separate record: it is
#   responses/round-<N>.json answering a review N with no gating
#   findings (after settled declines), which rule `commit N` reads.
#   A gating pass whose every gating finding the user then settled
#   reads the same way — the only edits left unreviewed are Medium/Low
#   ones, as after any minor pass.
#   A checks-override accepts one failure: red checks pass the gate only
#   while checks.failure is byte for byte a failure an override
#   recorded; a different failure is new and goes back as fix-checks.
#
#   The tree guard — only when <dir>/worktree names a work tree (BAD_DIR
#   when it names anything else). Every check and review is of one tree:
#   the one `git add -A` would commit. `next` records, in <dir>/trees,
#   the tree each review was asked for (when it emits `review N`; the
#   latest emission counts); each response carries the tree it checked
#   in its own `tree` key (the implementer takes it from `rounds tree`
#   after its last edit and checks). The latest round file — review M
#   when it leads, else response P — is the baseline, a response with no
#   `tree` matching nothing: when the work tree's tree now differs from
#   it, the tree changed outside the loop (edits while
#   the session was stopped, a hand edit), and `next` answers
#   `drifted N` — N the round the implementer answers next, M when the
#   review leads, else P — before any other gate, and records the drift.
#   The round then stays `drifted N` until responses/round-<N>.json is
#   written again, over the tree as it is now, and a drift recorded for round N turns
#   its `commit N` into `review N+1` — so the changed tree is checked and
#   reviewed before anything commits. Lines: review<TAB>N<TAB><tree>,
#   drift<TAB>N.
#
# tree — read-only: the tree of the work tree <dir>/worktree names (the
#   one `git add -A` would commit), for the implementer's response.
#   Frame: rc, tree. BAD_DIR without a worktree file.
#
#   Output: one frame, also written verbatim to <dir>/action:
#     rc=0
#     action        implement | ask-questions | infeasible | fix-checks |
#                   review | ask-disputes | fix | stalled | fix-minor |
#                   commit | drifted
#     round         the action's round (above)
#     gating, minor, out_of_scope
#                   counts of the action's round's review — review r
#                   for a round-r action, review r for `review r+1`,
#                   none (0) at round 0 — never finding text
#   On a failure the action file is left as it was.
#
# facts — read-only, for `objective phase-done`: the phase's report facts,
#   every finding classed exactly as `next` classes it. Plain
#   key<TAB>value lines: declined (declines.md's settled rulings), rounds
#   (the reviews' count), chfixed (`fixed` answers to gating findings of
#   the review they answer), fixed_after (`fixed` titles of a response
#   answering the last review), pass and commands (the latest response's
#   checks), verdict (checks | unreviewed | unfixed — gating findings
#   left in the last review — | ok), then one
#   cand<TAB><kind><TAB><title><TAB><file><TAB><detail> line per
#   follow-up: the last review's out-of-scope findings, Medium/Low
#   findings whose latest disposition is `declined` with no ruling
#   settling them, and the latest response's followups[]. BAD_ROUNDS
#   without responses/round-0.json.
#
# summary — read-only: one frame over the file's findings, in file
#   order, at most 10 listed:
#     rc=0
#     total                    findings in the file
#     shown                    findings listed below
#     more                     findings not listed (total - shown)
#     finding.<i>.severity     i = 1..shown: critical | high | medium |
#                              low | unknown (findings.awk's rule)
#     finding.<i>.title.b64    the title, byte for byte
#
# record — appends one line, creating the file when absent. Control
#   bytes in every argument become spaces, so a line stays one line and
#   its fields stay tab-separated:
#     checks-override  overrides    checks-override<TAB><failure.b64><TAB><reason>
#     continue N       overrides    continue<TAB><N><TAB><reason>
#     decline          declines.md  - <title><TAB>· <file><TAB>— declined: <reason>
#     rereview N       trees        drift<TAB><N> — the tree changed after
#                                   round N's review (a commit hook's fix,
#                                   a reset commit), so `commit N` becomes
#                                   `review N+1`, which records its tree
#   checks-override takes the failure it accepts from the oldest
#   response whose red checks no override accepts yet — the one
#   `fix-checks` names (BAD_ROUNDS when there is no response,
#   CHECKS_GREEN when there is no such failure, BAD_JSON when a
#   response is malformed), so the session never copies failure text.
#   <file> may be empty (a cross-cutting finding). `next` reads exactly
#   these shapes back and ignores any other line, which then overrides
#   or settles nothing. A declines line settles only when its last
#   field is `— declined: ` and a non-empty reason, with no field after.
#   Frame keys: rc, kind (checks-override|continue|decline|rereview),
#   wrote (overrides|declines.md|trees).
#
#   any subcommand:
#     FAIL:<TAB><reason><TAB><detail>    exit 1
#       reasons: BAD_ARGS BAD_DIR BAD_ROUNDS BAD_JSON NO_FILE CHECKS_GREEN
#                WRITE_ERROR GIT_ERROR
#
# Sourced by orca.sh with the verb arguments in place; lib.sh is already
# loaded.

rounds_usage="usage: orca.sh rounds next <dir> | orca.sh rounds tree <dir> | orca.sh rounds facts <dir> | orca.sh rounds summary <findings-file> | orca.sh rounds record <dir> checks-override <reason> | orca.sh rounds record <dir> continue <N> <reason> | orca.sh rounds record <dir> decline <title> <file> <reason> | orca.sh rounds record <dir> rereview <N>"
rounds_nl='
'
rounds_tab='	'

rounds_require_dir() { # <dir>
  is_run_dir "$1" || fail BAD_DIR "'$1' is not an absolute, existing directory inside a .orca/"
}

rounds_plain() { # <text> — control bytes as spaces, as findings.awk's plain columns
  printf '%s' "$1" | LC_ALL=C tr '\001-\037' ' '
}

rounds_has() { # <list> <key> — <list> is newline-framed: "\nkey1\nkey2\n"
  case "$1" in
    *"$rounds_nl$2$rounds_nl"*) return 0 ;;
  esac
  return 1
}

# rounds_parse <file> <response 0|1> <plain_title 0|1> <severity_name 0|1>
# [<details 0|1>] — findings.awk's output into rounds_rows.
rounds_parse() {
  [ -f "$1" ] || fail NO_FILE "$1 is missing or not a regular file"
  rounds_rows="$(LC_ALL=C awk -v response="$2" -v plain_title="$3" -v severity_name="$4" -v details="${5:-0}" \
    -f "$orca_scripts_dir/json-tokens.awk" -f "$orca_scripts_dir/findings.awk" "$1")" \
    || fail BAD_JSON "$1 is not a complete, well-formed $( [ "$2" = 1 ] && printf 'response (checks.pass a boolean, findings an array)' || printf 'findings document')"
}

rounds_split() { # <row> — sets rounds_sev rounds_loc rounds_file rounds_outcome rounds_title
  local rest="$1"
  rounds_sev="${rest%%"$rounds_tab"*}"; rest="${rest#*"$rounds_tab"}"
  rounds_loc="${rest%%"$rounds_tab"*}"; rest="${rest#*"$rounds_tab"}"
  rounds_file="${rest%%"$rounds_tab"*}"; rest="${rest#*"$rounds_tab"}"
  rounds_outcome="${rest%%"$rounds_tab"*}"; rest="${rest#*"$rounds_tab"}"
  rounds_title="${rest%%"$rounds_tab"*}"
}

# rounds_last <subdir> <first> — the highest N with round-<first>..N all
# present (first - 1 when none); BAD_ROUNDS when a round file sits
# outside that run.
rounds_last() {
  local path name k n=$(($2 - 1)) max=$(($2 - 1))
  for path in "$rounds_dir/$1"/round-*.json; do
    name="${path##*/}"
    [[ $name =~ ^round-(0|[1-9][0-9]{0,5})\.json$ ]] || continue
    k="${BASH_REMATCH[1]}"
    [ "$k" -ge "$2" ] || fail BAD_ROUNDS "$1/$name: $1 start at round $2"
    [ "$k" -gt "$max" ] && max="$k"
  done
  while [ -f "$rounds_dir/$1/round-$((n + 1)).json" ]; do n=$((n + 1)); done
  [ "$max" -le "$n" ] || fail BAD_ROUNDS "$1/round-$((n + 1)).json is missing (or not a file) but $1/round-$max.json exists"
  rounds_last_n="$n"
}

# rounds_read_declines — sets rounds_settled (title<TAB>file keys) and
# rounds_declined (`<title> — <reason>; ...`, each key once, for the report).
rounds_read_declines() {
  local line rest title file ruling
  rounds_settled="$rounds_nl" rounds_declined=""
  [ -f "$rounds_dir/declines.md" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*"${rounds_tab}· "*"$rounds_tab"*) ;;
      *) continue ;;
    esac
    rest="${line#- }"
    title="${rest%%"$rounds_tab"*}"
    rest="${rest#*"${rounds_tab}"· }"
    file="${rest%%"$rounds_tab"*}"
    ruling="${rest#*"$rounds_tab"}"
    # Only a recorded ruling settles: the decline marker and a reason,
    # and no further field.
    case "$ruling" in
      *"$rounds_tab"*) continue ;;
      "— declined: "?*) ;;
      *) continue ;;
    esac
    rounds_has "$rounds_settled" "$title$rounds_tab$file" && continue
    rounds_settled="$rounds_settled$title$rounds_tab$file$rounds_nl"
    rounds_declined="$rounds_declined${rounds_declined:+; }$title — ${ruling#— declined: }"
  done <"$rounds_dir/declines.md"
}

rounds_read_overrides() { # sets rounds_accepted (failure.b64 keys) and rounds_continues
  local line rest
  rounds_accepted="$rounds_nl"
  rounds_continues="$rounds_nl"
  [ -f "$rounds_dir/overrides" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "checks-override$rounds_tab"*)
        rest="${line#checks-override"$rounds_tab"}"
        rounds_accepted="$rounds_accepted${rest%%"$rounds_tab"*}$rounds_nl" ;;
      "continue$rounds_tab"*)
        rest="${line#continue"$rounds_tab"}"
        rounds_continues="$rounds_continues${rest%%"$rounds_tab"*}$rounds_nl" ;;
    esac
  done <"$rounds_dir/overrides"
}

# rounds_review <N> — sets rv_gating rv_minor rv_oos, rv_gating_keys
# (the gating findings) and rv_other_keys (the minor and out-of-scope
# ones), each key title<TAB>file, and rv_classes: one
# <class><TAB><key> line per finding in file order, the class oos |
# settled | gating | medium | low.
rounds_review() {
  local row key class
  rounds_parse "$rounds_dir/reviews/round-$1.json" 0 1 0
  rv_gating=0 rv_minor=0 rv_oos=0
  rv_gating_keys="$rounds_nl" rv_other_keys="$rounds_nl" rv_all_keys="$rounds_nl" rv_classes=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    rounds_split "$row"
    key="$rounds_title$rounds_tab$rounds_file"
    rv_all_keys="$rv_all_keys$key$rounds_nl"
    if [ "$rounds_loc" = "another work item" ]; then
      class=oos
      rv_oos=$((rv_oos + 1))
      rv_other_keys="$rv_other_keys$key$rounds_nl"
    elif rounds_has "$rounds_settled" "$key"; then
      class=settled
    elif [ "$rounds_sev" = gating ]; then
      class=gating
      rv_gating=$((rv_gating + 1))
      rv_gating_keys="$rv_gating_keys$key$rounds_nl"
    else
      class="$rounds_sev"
      rv_minor=$((rv_minor + 1))
      rv_other_keys="$rv_other_keys$key$rounds_nl"
    fi
    rv_classes="$rv_classes$class$rounds_tab$key$rounds_nl"
  done <<EOF
$rounds_rows
EOF
}

# rounds_response <N> — sets rs_pass (true|false), rs_failure (base64),
# rs_status (done|needs_input|infeasible), rs_tree (the tree the response
# says it checked, empty when it names none), rs_fixed_keys, and
# rs_disputed_keys.
rounds_response() {
  local row key head
  rounds_parse "$rounds_dir/responses/round-$1.json" 1 1 0
  head="${rounds_rows%%"$rounds_nl"*}"
  head="${head#pass"$rounds_tab"}"
  rs_pass="${head%%"$rounds_tab"*}"
  head="${head#*"$rounds_tab"}"
  rs_failure="${head%%"$rounds_tab"*}"
  head="${head#*"$rounds_tab"}"
  rs_status="${head%%"$rounds_tab"*}"
  rs_tree="${head#*"$rounds_tab"}"
  rs_fixed_keys="$rounds_nl" rs_disputed_keys="$rounds_nl" rs_all_keys="$rounds_nl"
  while IFS= read -r row; do
    case "$row" in pass"$rounds_tab"*|'') continue ;; esac
    rounds_split "$row"
    key="$rounds_title$rounds_tab$rounds_file"
    rs_all_keys="$rs_all_keys$key$rounds_nl"
    case "$rounds_outcome" in
      fixed) rs_fixed_keys="$rs_fixed_keys$key$rounds_nl" ;;
      disputed) rs_disputed_keys="$rs_disputed_keys$key$rounds_nl" ;;
    esac
  done <<EOF
$rounds_rows
EOF
}

# The disputes still open: response P's disputed keys that no decline
# settles and review P does not hold as minor or out of scope.
rounds_open_disputes() { # <disputed-keys> <other-keys> — the count
  local key n=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    rounds_has "$rounds_settled" "$key" && continue
    rounds_has "$2" "$key" && continue
    n=$((n + 1))
  done <<EOF
$1
EOF
  printf '%s' "$n"
}

# rounds_unanswered <review-keys> <response-keys> — exit 0 and set
# rounds_missing to the first review finding the response has no
# disposition for.
rounds_unanswered() {
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    rounds_has "$2" "$key" && continue
    rounds_missing="$key"
    return 0
  done <<EOF
$1
EOF
  return 1
}

rounds_reappeared() { # <gating-keys> <fixed-keys> — a gating key an earlier response marked fixed
  local key
  while IFS= read -r key; do
    [ -n "$key" ] && rounds_has "$2" "$key" && return 0
  done <<EOF
$1
EOF
  return 1
}

# rounds_guard_target <path> — a file verb writes must be absent or a
# regular file, never a symlink: mv onto a directory (or a link to one)
# would move the temp file inside it, and an append through a link
# would write elsewhere.
rounds_guard_target() {
  if [ -L "$1" ] || { [ -e "$1" ] && [ ! -f "$1" ]; }; then
    fail WRITE_ERROR "$1 is a symlink or not a regular file — nothing written"
  fi
}

# rounds_emit <action> <round> — write the frame to <dir>/action, then print it.
rounds_emit() {
  local frame tmp
  # The tree a review is asked for is the tree it reviews: the latest
  # `review N` names it.
  if [ "$1" = review ] && [ -n "${rounds_tree:-}" ] && [ "$(rounds_trees_get review "$2")" != "$rounds_tree" ]; then
    rounds_append trees "review$rounds_tab$2$rounds_tab$rounds_tree"
  fi
  rounds_guard_target "$rounds_dir/action"
  frame="$(emit_frame rc=0 "action=$1" "round=$2" "gating=$rounds_gating" \
    "minor=$rounds_minor" "out_of_scope=$rounds_oos")"
  tmp="$(mktemp "$rounds_dir/.action.XXXXXX" 2>/dev/null)" \
    || fail WRITE_ERROR "could not create a temp file in $rounds_dir"
  if ! printf '%s\n' "$frame" >"$tmp" 2>/dev/null || ! mv -f "$tmp" "$rounds_dir/action" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    fail WRITE_ERROR "could not write $rounds_dir/action"
  fi
  printf '%s\n' "$frame"
  exit 0
}

# rounds_at <round> — the counts the frame carries for an action of this
# round: review <round>'s (none for round 0).
rounds_at() {
  if [ "$1" -ge 1 ]; then
    rounds_gating="${rounds_rv_gating[$1]}" rounds_minor="${rounds_rv_minor[$1]}" rounds_oos="${rounds_rv_oos[$1]}"
  else
    rounds_gating=0 rounds_minor=0 rounds_oos=0
  fi
}

rounds_stop() { # <action> <round> <counts-round> — emit with that round's counts
  rounds_at "$3"
  rounds_emit "$1" "$2"
}

# rounds_trees_get <kind> <N> — the recorded tree, empty when none.
rounds_trees_get() {
  [ -f "$rounds_dir/trees" ] || return 0
  LC_ALL=C awk -F'\t' -v k="$1" -v n="$2" '
    $1 == k && $2 == n { t = $NF }
    END { if (t != "") print t }' "$rounds_dir/trees"
}

rounds_drifts() { # <N> — how many drifts are recorded for round N
  if [ -f "$rounds_dir/trees" ]; then
    LC_ALL=C awk -F'\t' -v n="$1" '$1 == "drift" && $2 == n && NF == 2 { c++ } END { print c + 0 }' "$rounds_dir/trees"
  else
    printf '0'
  fi
}

rounds_has_drift() { # <N>
  [ "$(rounds_drifts "$1")" -gt 0 ]
}

# rounds_guard <p> <m> — the tree guard (header). Sets rounds_tree to
# the work tree's tree when <dir>/worktree names one; stops with
# `drifted N` when the latest round's tree is not it: review M's, recorded
# when `review M` was emitted, when the review leads; else the tree
# response P says it checked (its `tree`), a response naming none
# counting as drifted — so the round stays drifted until the implementer
# answers it again over the tree as it is now.
rounds_guard() {
  local base n
  rounds_tree=""
  [ -e "$rounds_dir/worktree" ] || return 0
  rounds_worktree
  rounds_tree="$worktree_tree_id"
  rounds_guard_target "$rounds_dir/trees"
  if [ "$2" -eq $(($1 + 1)) ]; then
    n="$2"
    base="$(rounds_trees_get review "$n")"
    [ -z "$base" ] && return 0
  else
    n="$1"
    base="$rs_latest_tree"
  fi
  [ "$base" = "$rounds_tree" ] && return 0
  rounds_has_drift "$n" || rounds_append trees "drift$rounds_tab$n"
  rounds_at "$n"
  rounds_emit drifted "$n"
}

# rounds_worktree — the tree of the work tree <dir>/worktree names, into
# worktree_tree_id; BAD_DIR when it names no work tree root.
rounds_worktree() {
  local wt
  wt="$(head -1 "$rounds_dir/worktree" 2>/dev/null)"
  is_worktree_root "$wt" || fail BAD_DIR "$rounds_dir/worktree names '$wt', which is not a work tree root"
  worktree_tree "$wt" || fail GIT_ERROR "could not build the tree of $wt"
}

# rounds_next — walk the rounds oldest first and stop at the first gate
# that is not resolved, so a round's gate holds whatever later files
# exist. Round r's gates, in order: response r's status, its checks,
# then (r >= 1) its disputes against review r, the stall, and whether
# review r+1 is due; a later review supersedes only a round with nothing
# left open. After the last response comes review P+1, when present.
rounds_next() {
  local p m n r fixed_before="$rounds_nl"
  local -a rounds_rv_gating rounds_rv_minor rounds_rv_oos rounds_rv_gating_keys rounds_rv_other_keys
  local -a rounds_rs_status rounds_rs_pass rounds_rs_failure rounds_rs_fixed rounds_rs_disputed rounds_rs_all rounds_rv_all
  rounds_last responses 0; p="$rounds_last_n"
  rounds_last reviews 1; m="$rounds_last_n"
  rounds_gating=0 rounds_minor=0 rounds_oos=0
  if [ "$p" -lt 0 ]; then
    [ "$m" -eq 0 ] || fail BAD_ROUNDS "reviews exist but responses/round-0.json does not"
    rounds_has_drift 0 && rounds_emit drifted 0
    rounds_emit implement 0
  fi
  [ "$m" -eq "$p" ] || [ "$m" -eq $((p + 1)) ] \
    || fail BAD_ROUNDS "responses run to round $p but reviews to round $m — reviews must equal responses or lead by one"
  rounds_read_declines
  rounds_read_overrides

  # Every file is parsed before any gate is judged, so a malformed one
  # anywhere fails the call.
  for ((n = 0; n <= p; n++)); do
    rounds_response "$n"
    rounds_rs_status[n]="$rs_status" rounds_rs_pass[n]="$rs_pass" rounds_rs_failure[n]="$rs_failure"
    rounds_rs_fixed[n]="$rs_fixed_keys" rounds_rs_disputed[n]="$rs_disputed_keys" rounds_rs_all[n]="$rs_all_keys"
    rs_latest_tree="$rs_tree"
  done
  for ((n = 1; n <= m; n++)); do
    rounds_review "$n"
    rounds_rv_gating[n]="$rv_gating" rounds_rv_minor[n]="$rv_minor" rounds_rv_oos[n]="$rv_oos"
    rounds_rv_gating_keys[n]="$rv_gating_keys" rounds_rv_other_keys[n]="$rv_other_keys"
    rounds_rv_all[n]="$rv_all_keys"
  done
  # A finished response answers every finding of the review it answers.
  for ((n = 1; n <= p; n++)); do
    [ "${rounds_rs_status[n]}" = 'done' ] || continue
    rounds_unanswered "${rounds_rv_all[n]}" "${rounds_rs_all[n]}" \
      && fail BAD_JSON "responses/round-$n.json is done but has no disposition for '${rounds_missing%%"$rounds_tab"*}' (${rounds_missing#*"$rounds_tab"}) of reviews/round-$n.json — every finding needs one, by its title and file"
  done

  rounds_guard "$p" "$m"

  for ((r = 0; r <= p; r++)); do
    # An unfinished pass is answered before anything it reported is read.
    [ "${rounds_rs_status[r]}" = needs_input ] && rounds_stop ask-questions "$r" "$r"
    [ "${rounds_rs_status[r]}" = infeasible ] && rounds_stop infeasible "$r" "$r"
    if [ "${rounds_rs_pass[r]}" = false ] && ! rounds_has "$rounds_accepted" "${rounds_rs_failure[r]}"; then
      rounds_stop fix-checks "$r" "$r"
    fi
    if [ "$r" -eq 0 ]; then
      [ "$m" -eq 0 ] && rounds_stop review 1 0
      continue
    fi
    if [ "$(rounds_open_disputes "${rounds_rs_disputed[r]}" "${rounds_rv_other_keys[r]}")" -gt 0 ]; then
      rounds_stop ask-disputes "$r" "$r"
    fi
    if [ "${rounds_rv_gating[r]}" -gt 0 ]; then
      if [ "$r" -ge 2 ] && ! rounds_has "$rounds_continues" "$r"; then
        if [ "${rounds_rv_gating[r]}" -ge "${rounds_rv_gating[r - 1]}" ] \
          || rounds_reappeared "${rounds_rv_gating_keys[r]}" "$fixed_before"; then
          rounds_stop stalled "$r" "$r"
        fi
      fi
      [ "$r" -eq "$m" ] && rounds_stop review $((r + 1)) "$r"
    else
      # No gating finding left: response r was the minor pass — unless the
      # tree drifted at r, which a review must see first.
      if [ "$r" -eq "$m" ]; then
        rounds_has_drift "$r" && rounds_stop review $((r + 1)) "$r"
        rounds_stop commit "$r" "$r"
      fi
    fi
    fixed_before="$fixed_before${rounds_rs_fixed[r]#"$rounds_nl"}"
  done

  # Review M has no response yet (M = P + 1). A drifted round M is
  # answered over the changed tree first.
  rounds_has_drift "$m" && rounds_stop drifted "$m" "$m"
  [ "${rounds_rv_gating[m]}" -gt 0 ] && rounds_stop fix "$m" "$m"
  [ "${rounds_rv_minor[m]}" -gt 0 ] && rounds_stop fix-minor "$m" "$m"
  rounds_stop commit "$m" "$m"
}

# rounds_facts_awk — aggregates rounds_facts' tagged lines (V: a review
# finding's class, S: a response's details) into the facts (header); M
# the last review, P the last response.
# shellcheck disable=SC2016  # awk fields, not expansions
rounds_facts_awk='
BEGIN { FS = "\t" }
$1 == "V" { r = $2 + 0; i = ++vn[r]; vclass[r, i] = $3; vkey[r, i] = $4 "\t" $5; vtitle[r, i] = $4; vfile[r, i] = $5; next }
$1 == "S" && $3 == "pass" { pass[$2 + 0] = $4; next }
$1 == "S" && $3 == "finding" {
  r = $2 + 0; i = ++sn[r]
  skey[r, i] = $4 "\t" $5; stitle[r, i] = $4; sfile[r, i] = $5; sout[r, i] = $6; sreason[r, i] = $7
  next
}
$1 == "S" && $3 == "command" { if ($2 + 0 == P) commands = commands (commands == "" ? "" : ", ") $4; next }
$1 == "S" && $3 == "followup" { if ($2 + 0 == P) { g = ++gn; gtitle[g] = $4; gfile[g] = $5; gwhy[g] = $6 }; next }
function class(r, key,    i) {
  for (i = 1; i <= vn[r]; i++) if (vkey[r, i] == key) return vclass[r, i]
  return ""
}
END {
  for (r = 1; r <= P && r <= M; r++)
    for (i = 1; i <= sn[r]; i++)
      if (sout[r, i] == "fixed" && class(r, skey[r, i]) == "gating") chfixed++
  if (M >= 1 && P == M)
    for (i = 1; i <= sn[P]; i++)
      if (sout[P, i] == "fixed") fixed_after = fixed_after (fixed_after == "" ? "" : "; ") stitle[P, i]
  for (i = 1; i <= vn[M]; i++) if (vclass[M, i] == "gating") gating++
  verdict = "ok"
  if (pass[P] == "false") verdict = "checks"
  else if (M == 0) verdict = "unreviewed"
  else if (gating > 0) verdict = "unfixed"
  print "rounds\t" M
  print "chfixed\t" chfixed + 0
  print "fixed_after\t" fixed_after
  print "pass\t" pass[P]
  print "commands\t" commands
  print "verdict\t" verdict
  for (i = 1; i <= vn[M]; i++)
    if (vclass[M, i] == "oos") print "cand\tout of scope\t" vtitle[M, i] "\t" vfile[M, i] "\t" vfile[M, i]
  for (r = 1; r <= P && r <= M; r++)
    for (i = 1; i <= sn[r]; i++) {
      k = skey[r, i]; latest[k] = sout[r, i]; reason[k] = sreason[r, i]
      e = class(r, k)
      if (sout[r, i] == "declined" && (e == "medium" || e == "low") && !(k in listed)) {
        listed[k] = 1; un++; ukey[un] = k; utitle[un] = stitle[r, i]; ufile[un] = sfile[r, i]; usev[un] = e
      }
    }
  for (j = 1; j <= un; j++)
    if (latest[ukey[j]] == "declined")
      print "cand\tleft unfixed (" (usev[j] == "medium" ? "Medium" : "Low") ")\t" utitle[j] "\t" ufile[j] "\t" reason[ukey[j]]
  for (g = 1; g <= gn; g++) print "cand\tgap\t" gtitle[g] "\t" gfile[g] "\t" gwhy[g]
}'

rounds_facts() {
  local p m n row stream=""
  rounds_last responses 0; p="$rounds_last_n"
  [ "$p" -ge 0 ] || fail BAD_ROUNDS "$rounds_dir/responses/round-0.json is missing — the phase never ran"
  rounds_last reviews 1; m="$rounds_last_n"
  rounds_read_declines
  for ((n = 1; n <= m; n++)); do
    rounds_review "$n"
    while IFS= read -r row; do
      [ -n "$row" ] && stream="${stream}V$rounds_tab$n$rounds_tab$row$rounds_nl"
    done <<EOF
$rv_classes
EOF
  done
  for ((n = 0; n <= p; n++)); do
    rounds_parse "$rounds_dir/responses/round-$n.json" 1 1 0 1
    while IFS= read -r row; do
      case "$row" in
        '') continue ;;
        pass"$rounds_tab"*) row="${row#pass"$rounds_tab"}"; row="pass$rounds_tab${row%%"$rounds_tab"*}" ;;
        command"$rounds_tab"* | followup"$rounds_tab"*) ;;
        *)
          rounds_split "$row"
          row="finding$rounds_tab$rounds_title$rounds_tab$rounds_file$rounds_tab$rounds_outcome$rounds_tab${row##*"$rounds_tab"}" ;;
      esac
      stream="${stream}S$rounds_tab$n$rounds_tab$row$rounds_nl"
    done <<EOF
$rounds_rows
EOF
  done
  printf 'declined\t%s\n' "$rounds_declined"
  printf '%s' "$stream" | LC_ALL=C awk -v M="$m" -v P="$p" "$rounds_facts_awk"
}

rounds_summary() { # <file> <max>
  local row severity title shown=0 total=0 listed=()
  rounds_parse "$1" 0 0 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    total=$((total + 1))
    [ "$shown" -lt "$2" ] || continue
    shown=$((shown + 1))
    severity="${row##*"$rounds_tab"}"
    title="${row%"$rounds_tab"*}"
    title="${title##*"$rounds_tab"}"
    listed+=("finding.$shown.severity=$severity" "finding.$shown.title.b64=$title")
  done <<EOF
$rounds_rows
EOF
  emit_frame rc=0 "total=$total" "shown=$shown" "more=$((total - shown))" ${listed[@]+"${listed[@]}"}
}

# rounds_append <name> <line> — append one line to <dir>/<name>, first
# closing a last line a hand edit left unterminated.
rounds_append() {
  local target="$rounds_dir/$1"
  rounds_guard_target "$target"
  if [ -s "$target" ] && [ -n "$(tail -c 1 "$target")" ]; then
    printf '\n' >>"$target" 2>/dev/null || fail WRITE_ERROR "could not write $target"
  fi
  printf '%s\n' "$2" >>"$target" 2>/dev/null || fail WRITE_ERROR "could not write $target"
}

# rounds_open_failure — sets rs_failure to the failure `next` gates on:
# the oldest response whose red checks no override accepts yet. The
# override records what it accepts from the file, never from the
# session.
rounds_open_failure() {
  local p n
  rounds_last responses 0; p="$rounds_last_n"
  [ "$p" -ge 0 ] || fail BAD_ROUNDS "no response to override: responses/round-0.json does not exist"
  rounds_read_overrides
  for ((n = 0; n <= p; n++)); do
    rounds_response "$n"
    [ "$rs_pass" = false ] && ! rounds_has "$rounds_accepted" "$rs_failure" && return 0
  done
  fail CHECKS_GREEN "no response has red checks an override does not already accept — nothing to override"
}

rounds_record() { # <kind> <args...>
  local kind="$1"
  shift
  case "$kind" in
    checks-override)
      [ $# -eq 1 ] && [ -n "$1" ] || fail BAD_ARGS "$rounds_usage"
      rounds_open_failure
      rounds_append overrides "checks-override$rounds_tab$rs_failure$rounds_tab$(rounds_plain "$1")"
      emit_frame rc=0 kind=checks-override wrote=overrides ;;
    continue)
      [ $# -eq 2 ] && [ -n "$2" ] || fail BAD_ARGS "$rounds_usage"
      [[ $1 =~ ^[1-9][0-9]{0,5}$ ]] || fail BAD_ARGS "continue takes a round number, got '$1'"
      rounds_append overrides "continue$rounds_tab$1$rounds_tab$(rounds_plain "$2")"
      emit_frame rc=0 kind=continue wrote=overrides ;;
    rereview)
      [ $# -eq 1 ] || fail BAD_ARGS "$rounds_usage"
      [[ $1 =~ ^(0|[1-9][0-9]{0,5})$ ]] || fail BAD_ARGS "rereview takes a round number, got '$1'"
      rounds_guard_target "$rounds_dir/trees"
      rounds_has_drift "$1" || rounds_append trees "drift$rounds_tab$1"
      emit_frame rc=0 kind=rereview wrote=trees ;;
    decline)
      [ $# -eq 3 ] && [ -n "$3" ] || fail BAD_ARGS "$rounds_usage"
      rounds_append declines.md "- $(rounds_plain "$1")${rounds_tab}· $(rounds_plain "$2")${rounds_tab}— declined: $(rounds_plain "$3")"
      emit_frame rc=0 kind=decline wrote=declines.md ;;
    *) fail BAD_ARGS "unknown ruling '$kind' — $rounds_usage" ;;
  esac
}

rounds_cmd="${1:-}"
case "$rounds_cmd" in
  next)
    [ $# -eq 2 ] || fail BAD_ARGS "$rounds_usage"
    rounds_require_dir "$2"
    rounds_dir="$2"
    rounds_next ;;
  summary)
    [ $# -eq 2 ] || fail BAD_ARGS "$rounds_usage"
    rounds_summary "$2" 10 ;;
  facts)
    [ $# -eq 2 ] || fail BAD_ARGS "$rounds_usage"
    rounds_require_dir "$2"
    rounds_dir="$2"
    rounds_facts ;;
  tree)
    [ $# -eq 2 ] || fail BAD_ARGS "$rounds_usage"
    rounds_require_dir "$2"
    rounds_dir="$2"
    [ -e "$rounds_dir/worktree" ] || fail BAD_DIR "$rounds_dir/worktree is missing — no work tree to read"
    rounds_worktree
    emit_frame rc=0 "tree=$worktree_tree_id" ;;
  record)
    [ $# -ge 3 ] || fail BAD_ARGS "$rounds_usage"
    rounds_require_dir "$2"
    rounds_dir="$2"
    shift 2
    rounds_record "$@" ;;
  *) fail BAD_ARGS "$rounds_usage" ;;
esac
