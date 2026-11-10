#!/usr/bin/env bats
# orca.sh rounds — next (the action table, the stall rules, the
# overrides, the action file), summary (the bounded list), and record
# (the rulings next reads back).

load helpers

orca() { bash "$SCRIPTS/orca.sh" "$@"; }

# helpers.bash's setup, then a fresh rounds directory inside a .orca/.
eval "helpers_$(declare -f setup)"
setup() {
  helpers_setup
  D="$BATS_TEST_TMPDIR/repo/.orca/objectives/20260101-000000-x/phases/P1"
  mkdir -p "$D/reviews" "$D/responses"
}

# f <severity> <title> [file] [fix_location] — one review finding.
f() {
  printf '{"severity":"%s","file":"%s","line":1,"title":"%s","body":"b","fix_location":"%s"}' \
    "$1" "${3:-a.sh}" "$2" "${4:-local code}"
}

# d <title> <outcome> [file] — one response disposition.
d() {
  printf '{"title":"%s","file":"%s","outcome":"%s","reason":"r"}' "$1" "${3:-a.sh}" "$2"
}

# review <N> [finding...] — reviews/round-<N>.json.
review() {
  local n="$1" IFS=,
  shift
  printf '{"findings":[%s]}\n' "$*" >"$D/reviews/round-$n.json"
}

# response <N> <true|false> [disposition...] — responses/round-<N>.json;
# red checks carry $FAILURE (default "suite red"), green ones ""; the
# status is $STATUS (default done), with one question unless done.
response() {
  local n="$1" pass="$2" failure="" status="${STATUS:-done}" questions="" IFS=,
  shift 2
  [ "$pass" = true ] || failure="${FAILURE:-suite red}"
  [ "$status" = 'done' ] || questions='"which way?"'
  printf '{"checks":{"commands":["bats tests/"],"pass":%s,"failure":"%s"},"findings":[%s],"followups":[],"status":"%s","questions":[%s]%s}\n' \
    "$pass" "$failure" "$*" "$status" "$questions" "${TREE:+,\"tree\":\"$TREE\"}" >"$D/responses/round-$n.json"
}

# next_is <action> <round> <gating> <minor> <out_of_scope> — runs next,
# asserts the whole frame, and that <dir>/action holds exactly it.
next_is() {
  run orca rounds next "$D"
  local want
  want="$(printf '@@ORCA@@\nrc=0\naction=%s\nround=%s\ngating=%s\nminor=%s\nout_of_scope=%s\n@@ORCA_END@@' "$@")"
  if [ "$status" -ne 0 ] || [ "$output" != "$want" ]; then
    printf 'expected:\n%s\nactual (status %s):\n%s\n' "$want" "$status" "$output" >&2
    return 1
  fi
  [ "$(cat "$D/action")" = "$output" ] || { echo "action file differs: $(cat "$D/action")" >&2; return 1; }
}

# next_fails <reason> — a typed failure that leaves the action file alone.
next_fails() {
  printf 'sentinel\n' >"$D/action"
  run orca rounds next "$D"
  assert_fail_reason "$1"
  refute_line '@@ORCA@@'
  [ "$(cat "$D/action")" = sentinel ]
}

# ---- the action table -------------------------------------------------

@test "implement: no responses/round-0.json, round files or not" {
  next_is implement 0 0 0 0
  rm -rf "$D/reviews" "$D/responses"
  next_is implement 0 0 0 0
}

@test "review 1: the initial implement is in with green checks" {
  response 0 true
  next_is review 1 0 0 0
}

@test "fix-checks: the latest response has red checks, at round 0 and later" {
  response 0 false
  next_is fix-checks 0 0 0 0
  response 0 true
  review 1 "$(f High bug)"
  response 1 false "$(d bug fixed)"
  next_is fix-checks 1 1 0 0
}

@test "fix-checks comes before a dispute, a stall, and the next review" {
  response 0 true
  review 1 "$(f High bug)"
  response 1 false "$(d bug disputed)"
  next_is fix-checks 1 1 0 0
}

@test "fix N: review N has gating findings; Medium/Low ride along in the counts" {
  response 0 true
  review 1 "$(f Critical one)" "$(f High two)" "$(f Medium three)" "$(f Low four)"
  next_is fix 1 2 2 0
}

@test "review N+1: response N is in after a gating review" {
  response 0 true
  review 1 "$(f High bug)"
  response 1 true "$(d bug fixed)"
  next_is review 2 1 0 0
}

@test "ask-disputes N: response N disputes a gating finding no decline settles" {
  response 0 true
  review 1 "$(f High bug)" "$(f High other)"
  response 1 true "$(d bug disputed)" "$(d other fixed)"
  next_is ask-disputes 1 2 0 0
}

@test "a settled dispute stops gating; the round moves on to the next review" {
  response 0 true
  review 1 "$(f High bug)" "$(f High other)"
  response 1 true "$(d bug disputed)" "$(d other fixed)"
  run orca rounds record "$D" decline bug a.sh "the user agreed"
  [ "$status" -eq 0 ]
  next_is review 2 1 0 0
}

@test "a disputed Medium/Low or out-of-scope entry is not a dispute to ask" {
  response 0 true
  review 1 "$(f High bug)" "$(f Low nit)" "$(f High far x.sh 'another work item')"
  response 1 true "$(d bug fixed)" "$(d nit disputed)" "$(d far disputed x.sh)"
  next_is review 2 1 1 1
}

@test "a disputed entry review N does not hold is asked, never ignored" {
  response 0 true
  review 1 "$(f High bug)"
  response 1 true "$(d bug fixed)" "$(d 'renamed bug' disputed)"
  next_is ask-disputes 1 1 0 0
}

@test "fix-minor N: review N is clean of gating findings and Medium/Low remain" {
  response 0 true
  review 1 "$(f Medium three)" "$(f Low four)"
  next_is fix-minor 1 0 2 0
}

@test "commit after the minor pass: response N answers a gating-free review N" {
  response 0 true
  review 1 "$(f Medium three)" "$(f Low four)"
  response 1 true "$(d three fixed)" "$(d four declined)"
  next_is commit 1 0 2 0
}

@test "commit when review N is clean and no minor pass is needed" {
  response 0 true
  review 1 "$(f High bug)"
  response 1 true "$(d bug fixed)"
  review 2
  next_is commit 2 0 0 0
}

@test "red checks after the minor pass go back as fix-checks before the commit" {
  response 0 true
  review 1 "$(f Low four)"
  response 1 false "$(d four fixed)"
  next_is fix-checks 1 0 1 0
}

@test "a gating pass whose every gating finding is settled reads as done" {
  response 0 true
  review 1 "$(f High bug)" "$(f Low nit)"
  response 1 true "$(d bug disputed)" "$(d nit fixed)"
  orca rounds record "$D" decline bug a.sh "accepted" >/dev/null
  next_is commit 1 0 1 0
}

# ---- unfinished responses ---------------------------------------------

@test "ask-questions N: a needs_input minor pass never reads as done" {
  response 0 true
  review 1 "$(f Low nit)"
  STATUS=needs_input response 1 true
  next_is ask-questions 1 0 1 0
  response 1 true "$(d nit fixed)"
  next_is commit 1 0 1 0
}

@test "ask-questions holds on every path: round 0, red checks, a gating pass, a stall" {
  STATUS=needs_input response 0 true
  next_is ask-questions 0 0 0 0
  STATUS=needs_input response 0 false
  next_is ask-questions 0 0 0 0
  response 0 true
  review 1 "$(f High a)"
  STATUS=needs_input response 1 true "$(d a fixed)"
  next_is ask-questions 1 1 0 0
  STATUS=needs_input response 1 true "$(d a disputed)"
  next_is ask-questions 1 1 0 0
  response 1 true "$(d a fixed)"
  review 2 "$(f High a)"
  STATUS=needs_input response 2 true "$(d a fixed)"
  next_is ask-questions 2 1 0 0
  response 2 true "$(d a fixed)"
  next_is stalled 2 1 0 0
}

@test "infeasible N: the latest response gave up, whatever else is on disk" {
  STATUS=infeasible response 0 true
  next_is infeasible 0 0 0 0
  response 0 true
  review 1 "$(f High a)"
  STATUS=infeasible response 1 false
  next_is infeasible 1 1 0 0
  review 2
  next_is infeasible 1 1 0 0
}

# ---- a round's gates hold whatever later files exist ---------------------

@test "an open dispute holds its round although a later clean review exists" {
  response 0 true
  review 1 "$(f High bug)"
  response 1 true "$(d bug disputed)"
  review 2
  next_is ask-disputes 1 1 0 0
  orca rounds record "$D" decline bug a.sh "agreed" >/dev/null
  next_is commit 2 0 0 0
}

@test "an open dispute holds its round although a later review and response exist" {
  response 0 true
  review 1 "$(f High bug)" "$(f High other)"
  response 1 true "$(d bug disputed)" "$(d other fixed)"
  review 2 "$(f High third)"
  response 2 true "$(d third fixed)"
  next_is ask-disputes 1 2 0 0
}

@test "red checks hold their round although a later review exists" {
  response 0 true
  review 1 "$(f High bug)"
  response 1 false "$(d bug fixed)"
  review 2
  next_is fix-checks 1 1 0 0
  review 2 "$(f High new)"
  response 2 true "$(d new fixed)"
  next_is fix-checks 1 1 0 0
}

@test "red checks at round 0 hold although review 1 exists" {
  response 0 false
  review 1
  next_is fix-checks 0 0 0 0
}

@test "an unfinished response holds its round although later rounds exist" {
  response 0 true
  review 1 "$(f High bug)"
  STATUS=needs_input response 1 true "$(d bug fixed)"
  review 2
  response 2 true
  next_is ask-questions 1 1 0 0
  STATUS=infeasible response 1 true "$(d bug fixed)"
  next_is infeasible 1 1 0 0
  STATUS=needs_input response 0 true
  next_is ask-questions 0 0 0 0
}

@test "a stall holds its round although a later review exists; continue N releases it" {
  response 0 true
  review 1 "$(f High a)"
  response 1 true "$(d a fixed)"
  review 2 "$(f High b)"
  response 2 true "$(d b fixed)"
  review 3
  next_is stalled 2 1 0 0
  orca rounds record "$D" continue 2 "go on" >/dev/null
  next_is commit 3 0 0 0
}

@test "a round with nothing open is superseded by the later review" {
  response 0 true
  review 1 "$(f High a)"
  response 1 true "$(d a disputed)"
  review 2 "$(f High b)" "$(f Low nit)"
  orca rounds record "$D" decline a a.sh "agreed" >/dev/null
  next_is fix 2 1 1 0
  response 2 true "$(d b fixed)" "$(d nit fixed)"
  next_is stalled 2 1 1 0
}

@test "a fixed gating round moves on to the later review's own gates" {
  response 0 true
  review 1 "$(f High a)" "$(f High b)"
  response 1 true "$(d a fixed)" "$(d b fixed)"
  review 2 "$(f Medium m)"
  next_is fix-minor 2 0 1 0
  response 2 true "$(d m declined)"
  next_is commit 2 0 1 0
}

# ---- stall rules ------------------------------------------------------

@test "stalled N by count: round 2's gating count is not lower than round 1's" {
  response 0 true
  review 1 "$(f High a)" "$(f High b)"
  response 1 true "$(d a fixed)" "$(d b fixed)"
  review 2 "$(f High c)" "$(f High d)"
  response 2 true "$(d c fixed)" "$(d d fixed)"
  next_is stalled 2 2 0 0
  review 2 "$(f High c)" "$(f High d)" "$(f High e)"
  response 2 true "$(d c fixed)" "$(d d fixed)" "$(d e fixed)"
  next_is stalled 2 3 0 0
}

@test "a shrinking gating count does not stall" {
  response 0 true
  review 1 "$(f High a)" "$(f High b)"
  response 1 true "$(d a fixed)" "$(d b fixed)"
  review 2 "$(f High c)"
  response 2 true "$(d c fixed)"
  next_is review 3 1 0 0
}

@test "stalled N by reappearance: a finding an earlier response marked fixed is back" {
  response 0 true
  review 1 "$(f High a)" "$(f High b)" "$(f High c)"
  response 1 true "$(d a fixed)" "$(d b fixed)" "$(d c fixed)"
  review 2 "$(f High d)" "$(f High e)"
  response 2 true "$(d d fixed)" "$(d e fixed)"
  review 3 "$(f High a)"
  response 3 true "$(d a fixed)"
  next_is stalled 3 1 0 0
}

@test "reappearance needs the same title and the same file" {
  response 0 true
  review 1 "$(f High a)" "$(f High b)"
  response 1 true "$(d a fixed)" "$(d b fixed)"
  review 2 "$(f High a other.sh)"
  response 2 true "$(d a fixed other.sh)"
  next_is review 3 1 0 0
}

@test "round 1 never stalls" {
  response 0 true
  review 1 "$(f High a)" "$(f High b)"
  response 1 true "$(d a fixed)" "$(d b fixed)"
  next_is review 2 2 0 0
}

@test "a continue override for round N clears that stall only" {
  response 0 true
  review 1 "$(f High a)"
  response 1 true "$(d a fixed)"
  review 2 "$(f High a)"
  response 2 true "$(d a fixed)"
  run orca rounds record "$D" continue 5 "a later round"
  [ "$status" -eq 0 ]
  next_is stalled 2 1 0 0
  run orca rounds record "$D" continue 2 "keep going"
  [ "$status" -eq 0 ]
  next_is review 3 1 0 0
  review 3 "$(f High a)"
  response 3 true "$(d a fixed)"
  next_is stalled 3 1 0 0
}

# ---- out of scope and severity ----------------------------------------

@test "out of scope never gates: a Critical in another work item still commits" {
  response 0 true
  review 1 "$(f Critical far x.sh 'another work item')" "$(f Blocker far2 y.sh 'another work item')"
  next_is commit 1 0 0 2
}

@test "out of scope never counts toward a stall, by count or by reappearance" {
  response 0 true
  review 1 "$(f High a)" "$(f High b)" "$(f High far x.sh 'another work item')"
  response 1 true "$(d a fixed)" "$(d b fixed)" "$(d far fixed x.sh)"
  review 2 "$(f High c)" "$(f High far x.sh 'another work item')" "$(f High far2 x.sh 'another work item')"
  response 2 true "$(d c fixed)" "$(d far out_of_scope x.sh)" "$(d far2 out_of_scope x.sh)"
  next_is review 3 1 0 2
}

@test "unknown severity gates: an unrecognized, empty, or missing severity" {
  response 0 true
  review 1 "$(f Blocker one)" "$(f '' two)" '{"title":"three","file":"a.sh","fix_location":"local code"}' "$(f ' LOW ' four)"
  next_is fix 1 3 1 0
}

@test "a fix_location that is not exactly another work item stays in scope" {
  response 0 true
  review 1 "$(f High near a.sh 'Another work item')"
  next_is fix 1 1 0 0
}

# ---- overrides --------------------------------------------------------

@test "checks-override: the accepted failure no longer gates a review or the commit" {
  response 0 false
  next_is fix-checks 0 0 0 0
  run orca rounds record "$D" checks-override "the flaky suite predates the change"
  [ "$status" -eq 0 ]
  next_is review 1 0 0 0
  review 1 "$(f High bug)"
  response 1 false "$(d bug fixed)"
  next_is review 2 1 0 0
  review 2
  next_is commit 2 0 0 0
}

@test "checks-override: a different failure is new and goes back as fix-checks" {
  FAILURE="lint: 3 warnings" response 0 false
  orca rounds record "$D" checks-override "known lint debt" >/dev/null
  next_is review 1 0 0 0
  review 1 "$(f High bug)"
  FAILURE="tests/rounds.bats: 2 failed" response 1 false "$(d bug fixed)"
  next_is fix-checks 1 1 0 0
  run orca rounds record "$D" checks-override "accepted as well"
  [ "$status" -eq 0 ]
  next_is review 2 1 0 0
  FAILURE="lint: 3 warnings" response 1 false "$(d bug fixed)"
  next_is review 2 1 0 0
}

@test "checks-override reads the failure it accepts from the latest response" {
  run orca rounds record "$D" checks-override "nothing yet"
  assert_fail_reason BAD_ROUNDS
  response 0 true
  run orca rounds record "$D" checks-override "green"
  assert_fail_reason CHECKS_GREEN
  printf '{"checks":{"pass":false},"findings":[]}' >"$D/responses/round-0.json"
  run orca rounds record "$D" checks-override "partial"
  assert_fail_reason BAD_JSON
  [ ! -e "$D/overrides" ]
}

@test "checks-override accepts the failure fix-checks names, an earlier round's included" {
  response 0 true
  review 1 "$(f High bug)"
  FAILURE="old red" response 1 false "$(d bug fixed)"
  review 2
  response 2 true
  next_is fix-checks 1 1 0 0
  run orca rounds record "$D" checks-override "accept the old failure"
  [ "$status" -eq 0 ]
  [ "$(cut -f2 "$D/overrides")" = "$(printf 'old red' | base64)" ]
  next_is commit 2 0 0 0
  run orca rounds record "$D" checks-override "again"
  assert_fail_reason CHECKS_GREEN
}

@test "record writes each ruling in the format next reads back" {
  FAILURE="red suite" response 0 false
  run orca rounds record "$D" checks-override "red is fine"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '@@ORCA@@\nrc=0\nkind=checks-override\nwrote=overrides\n@@ORCA_END@@')" ]
  run orca rounds record "$D" continue 4 "go on"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '@@ORCA@@\nrc=0\nkind=continue\nwrote=overrides\n@@ORCA_END@@')" ]
  run orca rounds record "$D" decline "a title" "" "cross-cutting"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '@@ORCA@@\nrc=0\nkind=decline\nwrote=declines.md\n@@ORCA_END@@')" ]
  [ "$(cat "$D/overrides")" = "$(printf 'checks-override\t%s\tred is fine\ncontinue\t4\tgo on' "$(printf 'red suite' | base64)")" ]
  [ "$(cat "$D/declines.md")" = "$(printf -- '- a title\t· \t— declined: cross-cutting')" ]
}


@test "a decline with an empty file settles a cross-cutting finding" {
  response 0 true
  review 1 '{"severity":"High","file":null,"line":null,"title":"design","body":"b","fix_location":"local code"}'
  response 1 true '{"title":"design","file":null,"outcome":"disputed","reason":"r"}'
  next_is ask-disputes 1 1 0 0
  orca rounds record "$D" decline design "" "agreed" >/dev/null
  next_is commit 1 0 0 0
}

@test "control bytes match after normalization on both sides of a decline" {
  response 0 true
  review 1 "$(f High 'tab\there')"
  response 1 true "$(d 'tab\there' disputed)"
  next_is ask-disputes 1 1 0 0
  orca rounds record "$D" decline "$(printf 'tab\there')" a.sh "$(printf 'line one\nline two')" >/dev/null
  [ "$(wc -l <"$D/declines.md" | tr -d ' ')" -eq 1 ]
  next_is commit 1 0 0 0
}

@test "record closes an unterminated last line before appending" {
  printf '# hand note' >"$D/declines.md"
  orca rounds record "$D" decline bug a.sh "ok" >/dev/null
  [ "$(sed -n 2p "$D/declines.md")" = "$(printf -- '- bug\t· a.sh\t— declined: ok')" ]
}

@test "lines next cannot read settle or override nothing" {
  response 0 false
  printf 'checks override: yes\ncontinue 2\n' >"$D/overrides"
  next_is fix-checks 0 0 0 0
  response 0 true
  review 1 "$(f High bug)"
  response 1 true "$(d bug disputed)"
  printf -- '- High · bug · a.sh — declined: old format\n' >"$D/declines.md"
  next_is ask-disputes 1 1 0 0
}

@test "a declines line settles only with the decline marker and a reason" {
  response 0 true
  review 1 "$(f High bug)"
  response 1 true "$(d bug disputed)"
  local ruling
  for ruling in 'still under discussion' '— declined: ' $'— declined: ok\textra' '— declined:ok' '-- declined: ok'; do
    printf -- '- bug\t· a.sh\t%s\n' "$ruling" >"$D/declines.md"
    next_is ask-disputes 1 1 0 0
  done
  printf -- '- bug\t· a.sh\t— declined: ok\n' >"$D/declines.md"
  next_is commit 1 0 0 0
}

@test "record refuses bad arguments" {
  run orca rounds record "$D" continue two "why"
  assert_fail_reason BAD_ARGS
  run orca rounds record "$D" continue 0 "why"
  assert_fail_reason BAD_ARGS
  run orca rounds record "$D" continue 2 ""
  assert_fail_reason BAD_ARGS
  run orca rounds record "$D" checks-override
  assert_fail_reason BAD_ARGS
  run orca rounds record "$D" decline bug a.sh
  assert_fail_reason BAD_ARGS
  run orca rounds record "$D" commit-anyway "why"
  assert_fail_reason BAD_ARGS
  run orca rounds record "$BATS_TEST_TMPDIR" checks-override "why"
  assert_fail_reason BAD_DIR
  [ ! -e "$D/overrides" ] && [ ! -e "$D/declines.md" ]
}

# ---- malformed, missing, partial --------------------------------------

@test "malformed or truncated review JSON fails typed, never a guessed action" {
  response 0 true
  printf '{"findings":[{"severity":"High","title":"x"' >"$D/reviews/round-1.json"
  next_fails BAD_JSON
  : >"$D/reviews/round-1.json"
  next_fails BAD_JSON
  printf '{"findings":[]} trailing' >"$D/reviews/round-1.json"
  next_fails BAD_JSON
  printf '{"notfindings":[]}' >"$D/reviews/round-1.json"
  next_fails BAD_JSON
}

@test "a malformed earlier round fails the call too" {
  response 0 true
  printf '{"findings":[' >"$D/reviews/round-1.json"
  response 1 true
  review 2
  next_fails BAD_JSON
}

@test "a partial response fails typed: missing or mistyped schema parts" {
  local rest='"followups":[],"status":"done","questions":[]' payload
  for payload in \
    "{\"findings\":[],$rest}" \
    "{\"checks\":{\"pass\":true},\"findings\":[],$rest}" \
    "{\"checks\":{\"pass\":true},\"findings\":[]}" \
    "{\"checks\":{\"commands\":[],\"pass\":\"true\",\"failure\":\"\"},\"findings\":[],$rest}" \
    "{\"checks\":{\"commands\":[],\"pass\":true,\"pass\":false,\"failure\":\"\"},\"findings\":[],$rest}" \
    "{\"checks\":{\"commands\":[],\"pass\":true,\"failure\":\"\"},$rest}" \
    "{\"checks\":{\"commands\":[],\"pass\":true,\"failure\":\"\"},\"findings\":[],\"status\":\"done\"}" \
    "{\"checks\":{\"commands\":[],\"pass\":true,\"failure\":\"\"},\"findings\":[],\"followups\":[],\"status\":\"finished\",\"questions\":[]}" \
    "{\"checks\":{\"commands\":[],\"pass\":true,\"failure\":\"\"},\"findings\":[{\"title\":\"t\",\"outcome\":\"fixed\"}],$rest}" \
    "{\"checks\":{\"commands\":[],\"pass\":true,\"failure\":\"\"},\"findings\":[" ; do
    printf '%s' "$payload" >"$D/responses/round-0.json"
    next_fails BAD_JSON
  done
}

@test "an incomplete minor-pass response fails typed instead of committing" {
  response 0 true
  review 1 "$(f Low nit)"
  printf '{"checks":{"pass":true},"findings":[]}' >"$D/responses/round-1.json"
  next_fails BAD_JSON
  printf '{"checks":{"commands":[],"pass":true,"failure":""},"findings":[{"title":"nit","file":"a.sh","outcome":"skipped","reason":"r"}],"followups":[],"status":"done","questions":[]}' \
    >"$D/responses/round-1.json"
  next_fails BAD_JSON
  response 1 true "$(d nit fixed)"
  next_is commit 1 0 1 0
}

@test "an action path that is a directory or a symlink fails typed, nothing written" {
  response 0 true
  mkdir "$D/action"
  run orca rounds next "$D"
  assert_fail_reason WRITE_ERROR
  refute_line '@@ORCA@@'
  [ -z "$(ls -A "$D/action")" ]
  [ -z "$(find "$D" -maxdepth 1 -name '.action.*')" ]
  rmdir "$D/action"
  mkdir "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$D/action"
  run orca rounds next "$D"
  assert_fail_reason WRITE_ERROR
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
  rm "$D/action"
  : >"$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$D/action"
  run orca rounds next "$D"
  assert_fail_reason WRITE_ERROR
  [ ! -s "$BATS_TEST_TMPDIR/target" ]
}

@test "record refuses a ruling file that is a symlink or a directory" {
  : >"$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$D/declines.md"
  run orca rounds record "$D" decline bug a.sh "ok"
  assert_fail_reason WRITE_ERROR
  [ ! -s "$BATS_TEST_TMPDIR/target" ]
  mkdir "$D/overrides"
  run orca rounds record "$D" continue 2 "go"
  assert_fail_reason WRITE_ERROR
}

@test "missing rounds fail typed" {
  # reviews without the initial implement
  review 1
  next_fails BAD_ROUNDS
  # a gap in the reviews
  response 0 true
  review 2
  next_fails BAD_ROUNDS
  # a review numbered 0
  rm "$D"/reviews/*
  review 0
  next_fails BAD_ROUNDS
  # a response with no review to answer
  rm "$D"/reviews/*
  response 1 true
  next_fails BAD_ROUNDS
  # reviews two ahead of the responses
  review 1
  review 2
  review 3
  next_fails BAD_ROUNDS
  # a gap in the responses
  rm "$D"/reviews/* "$D"/responses/*
  response 0 true
  response 2 true
  review 1
  review 2
  next_fails BAD_ROUNDS
  # a round "file" that is a directory
  rm "$D"/reviews/* "$D"/responses/*
  response 0 true
  mkdir "$D/reviews/round-1.json"
  review 2
  next_fails BAD_ROUNDS
}

@test "next refuses a directory outside a .orca/, relative, or missing" {
  run orca rounds next "$BATS_TEST_TMPDIR"
  assert_fail_reason BAD_DIR
  run orca rounds next repo/.orca/objectives/20260101-000000-x/phases/P1
  assert_fail_reason BAD_DIR
  run orca rounds next "$D/nope"
  assert_fail_reason BAD_DIR
  run orca rounds
  assert_fail_reason BAD_ARGS
  run orca rounds next
  assert_fail_reason BAD_ARGS
}

# ---- summary ----------------------------------------------------------

@test "summary: at most 10 by default, the remainder counted, in one frame" {
  local all="" i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    all="$all${all:+,}$(f High "t$i")"
  done
  printf '{"findings":[%s]}' "$all" >"$BATS_TEST_TMPDIR/r.json"
  run orca rounds summary "$BATS_TEST_TMPDIR/r.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p;$p' | tr '\n' ' ')" = "@@ORCA@@ @@ORCA_END@@ " ]
  has_line "total=12"
  has_line "shown=10"
  has_line "more=2"
  [ "$(printf '%s\n' "$output" | grep -c '^finding\.[0-9]*\.title\.b64=')" -eq 10 ]
  has_line "finding.10.title.b64=$(printf t10 | base64)"
  refute_line "finding.11."
}

@test "summary: severity names and base64 titles" {
  review 1 "$(f Critical 'one: a title')" "$(f ' low ' two)" "$(f Blocker three)" "$(f High four)"
  run orca rounds summary "$D/reviews/round-1.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '@@ORCA@@\nrc=0\ntotal=4\nshown=4\nmore=0\nfinding.1.severity=critical\nfinding.1.title.b64=%s\nfinding.2.severity=low\nfinding.2.title.b64=%s\nfinding.3.severity=unknown\nfinding.3.title.b64=%s\nfinding.4.severity=high\nfinding.4.title.b64=%s\n@@ORCA_END@@' \
    "$(printf 'one: a title' | base64)" "$(printf two | base64)" "$(printf three | base64)" "$(printf four | base64)")" ]
}

@test "summary: malformed, missing, and bad arguments fail typed" {
  printf '{"findings":[' >"$BATS_TEST_TMPDIR/bad.json"
  run orca rounds summary "$BATS_TEST_TMPDIR/bad.json"
  assert_fail_reason BAD_JSON
  refute_line '@@ORCA@@'
  run orca rounds summary "$BATS_TEST_TMPDIR/absent.json"
  assert_fail_reason NO_FILE
  printf '{"findings":[]}' >"$BATS_TEST_TMPDIR/ok.json"
  run orca rounds summary "$BATS_TEST_TMPDIR/ok.json" --max 3
  assert_fail_reason BAD_ARGS
}

# ---- the implementer's documented response ----------------------------

# The response example agents/objective-implement.md gives its rounds mode —
# the first json block after the "**The response file.**" paragraph.
documented_response() {
  awk '/^\*\*The response file\.\*\*/ { found = 1; next }
       found && /^```json$/ { inside = 1; next }
       inside && /^```$/ { exit }
       inside { print }' "$ORCA_ROOT/agents/objective-implement.md"
}

@test "the implementer's documented response is one next validates and matches" {
  documented_response >"$D/responses/round-1.json"
  [ -s "$D/responses/round-1.json" ]
  response 0 true
  review 1 "$(f critical 'Empty input crashes the parser' src/parse.c)" "$(f high 'Unterminated quote loops forever' src/parse.c)"
  next_is review 2 2 0 0
  # Its fixed finding matched review 1's by title and file: back in a
  # smaller review 2, it is a stall by reappearance, not by count.
  review 2 "$(f high 'Empty input crashes the parser' src/parse.c)"
  response 2 true "$(d 'Empty input crashes the parser' fixed src/parse.c)"
  next_is stalled 2 1 0 0
}

# ---- the commit turn's round ------------------------------------------

# A commit after a clean review the implementer never answered: the
# commit request names round N, so the commit turn writes
# responses/round-N.json. A hook failing that commit then lands in round
# N, and the re-review after its fix is round N+1 — a sequence the
# engine accepts. Answering it in the older round instead would leave
# reviews two ahead of responses.
@test "a commit hook failing after a clean, unanswered review: the commit turn answers that round and N+1 follows" {
  response 0 true
  review 1 "$(f low 'Nit' a.sh 'another work item')"
  next_is commit 1 0 0 1
  # the commit turn: response 1, the hook's failure in its checks
  FAILURE='pre-commit: lint failed' response 1 false "$(d 'Nit' out_of_scope)"
  next_is fix-checks 1 0 0 1
  # the checks request stays on round 1; then the re-review
  response 1 true "$(d 'Nit' out_of_scope)"
  review 2
  next_is commit 2 0 0 0
  # the same recovery answered in round 0 is the state the engine refuses
  rm "$D/responses/round-1.json"
  next_fails BAD_ROUNDS
}

@test "a content_reset after the commit turn: the checks request keeps round N, review N+1 is accepted" {
  response 0 true
  review 1
  next_is commit 1 0 0 0
  response 1 true
  next_is commit 1 0 0 0
  response 1 true
  review 2 "$(f high 'Hook rewrote the parser' src/parse.c)"
  next_is fix 2 1 0 0
}

# ---- the tree guard -----------------------------------------------------

# guarded — a work tree for the rounds, named in <dir>/worktree.
guarded() {
  make_repo "$BATS_TEST_TMPDIR/wt"
  WT="$BATS_TEST_TMPDIR/wt"
  printf '%s\n' "$WT" >"$D/worktree"
}

# checked <N> <true|false> [disposition...] — response N carrying the tree
# the work tree has now, as the implementer writes it from `rounds tree`.
checked() {
  run orca rounds tree "$D"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  TREE="$(printf '%s\n' "$output" | sed -n 's/^tree=//p')" response "$@"
}

@test "rounds tree: the tree the worktree file's work tree would commit; BAD_DIR without one" {
  run orca rounds tree "$D"
  assert_fail_reason BAD_DIR
  guarded
  run orca rounds tree "$D"
  [ "$status" -eq 0 ]
  local t
  t="$(printf '%s\n' "$output" | sed -n 's/^tree=//p')"
  [ "$t" = "$(git -C "$WT" rev-parse 'HEAD^{tree}')" ]
  echo new >"$WT/new.txt"
  run orca rounds tree "$D"
  [ "$(printf '%s\n' "$output" | sed -n 's/^tree=//p')" != "$t" ]
}

@test "tree guard: edits after a clean review and before the commit are drifted, then checked and reviewed before commit" {
  guarded
  checked 0 true
  next_is review 1 0 0 0
  grep -q $'^review\t1\t' "$D/trees"
  review 1
  next_is commit 1 0 0 0
  # the session stops before its snapshot; the tree changes while stopped
  echo edited-while-stopped >>"$WT/seed.txt"
  next_is drifted 1 0 0 0
  next_is drifted 1 0 0 0
  grep -qx $'drift\t1' "$D/trees"
  # the implementer answers round 1 over the changed tree; a review must follow
  checked 1 true
  next_is review 2 0 0 0
  review 2
  next_is commit 2 0 0 0
}

@test "tree guard: an edit after the response was written and before next first read it is drifted, never committed" {
  guarded
  checked 0 true
  next_is review 1 0 0 0
  review 1 "$(f low 'Nit' a.sh)"
  next_is fix-minor 1 0 1 0
  # the minor pass: fixed, checked, response written over that tree...
  checked 1 true "$(d 'Nit' fixed a.sh)"
  # ...then the session stops before next, and the tree changes
  echo hand-edit >>"$WT/seed.txt"
  next_is drifted 1 0 1 0
  next_is drifted 1 0 1 0
  checked 1 true "$(d 'Nit' fixed a.sh)"
  next_is review 2 0 1 0
}

@test "tree guard: a response under the guard that names no tree is drifted" {
  guarded
  response 0 true
  next_is drifted 0 0 0 0
  next_is drifted 0 0 0 0
  checked 0 true
  next_is review 1 0 0 0
}

@test "tree guard: a new untracked file counts, an ignored one does not" {
  guarded
  printf 'build/\n' >"$WT/.gitignore"
  git -C "$WT" add .gitignore && git -C "$WT" commit -qm ignore
  checked 0 true
  next_is review 1 0 0 0
  mkdir -p "$WT/build" && echo artifact >"$WT/build/out.o"
  next_is review 1 0 0 0
  echo new >"$WT/new.txt"
  # the review was asked for a tree without new.txt
  review 1 "$(f high 'Bug')"
  next_is drifted 1 1 0 0
}

@test "tree guard: a response rewritten over the changed tree takes it as its baseline, byte-identical or not" {
  guarded
  checked 0 true
  next_is review 1 0 0 0
  echo second >>"$WT/seed.txt"
  next_is drifted 0 0 0 0
  next_is drifted 0 0 0 0
  checked 0 true
  next_is review 1 0 0 0
  next_is review 1 0 0 0
}

@test "tree guard: a drifted fix round is answered again before its next review" {
  guarded
  checked 0 true
  next_is review 1 0 0 0
  review 1 "$(f high 'Bug')"
  checked 1 true "$(d 'Bug' fixed)"
  next_is review 2 1 0 0
  echo edited-while-stopped >>"$WT/seed.txt"
  next_is drifted 1 1 0 0
  next_is drifted 1 1 0 0
  checked 1 true "$(d 'Bug' fixed)"
  next_is review 2 1 0 0
  review 2
  next_is commit 2 0 0 0
}

@test "tree guard: a worktree file naming no work tree fails typed; without one nothing is guarded" {
  response 0 true
  next_is review 1 0 0 0
  [ ! -e "$D/trees" ]
  printf '%s\n' "$BATS_TEST_TMPDIR/not-a-tree" >"$D/worktree"
  next_fails BAD_DIR
}

@test "record rereview N: a clean round N is reviewed again before it commits" {
  guarded
  checked 0 true
  next_is review 1 0 0 0
  review 1
  next_is commit 1 0 0 0
  # a commit hook failed; its fix rewrote the response for round 1
  FAILURE='hook: lint' checked 1 false
  next_is fix-checks 1 0 0 0
  checked 1 true
  run orca rounds record "$D" rereview 1
  [ "$status" -eq 0 ]
  has_line 'kind=rereview'
  has_line 'wrote=trees'
  next_is review 2 0 0 0
  run orca rounds record "$D" rereview x
  assert_fail_reason BAD_ARGS
}

@test "a done response must answer every finding of its review, by title and file; an unfinished one need not" {
  response 0 true
  review 1 "$(f high 'Bug' a.sh)" "$(f low 'Nit' b.sh)" "$(f low 'Far' c.sh 'another work item')"
  # minor and out-of-scope findings need a disposition too
  response 1 true "$(d 'Bug' fixed a.sh)"
  next_fails BAD_JSON
  [[ "$output" == *"responses/round-1.json is done but has no disposition for 'Nit' (b.sh)"* ]] || return 1
  # a disposition whose file differs does not answer the finding
  response 1 true "$(d 'Bug' fixed a.sh)" "$(d 'Nit' declined other.sh)" "$(d 'Far' out_of_scope c.sh)"
  next_fails BAD_JSON
  # an unfinished response lists what it disposed of so far
  STATUS=needs_input response 1 true "$(d 'Bug' fixed a.sh)"
  next_is ask-questions 1 1 1 1
  response 1 true "$(d 'Bug' fixed a.sh)" "$(d 'Nit' declined b.sh)" "$(d 'Far' out_of_scope c.sh)"
  next_is review 2 1 1 1
}

@test "the implementer records each response's checked tree through rounds tree, and the loop hands it the plugin root" {
  grep -qF '`tree` — the tree this turn'"'"'s checks were of' "$ORCA_ROOT/agents/objective-implement.md"
  grep -qF 'bash "<plugin-root>/scripts/orca.sh" rounds tree <rounds-dir>' "$ORCA_ROOT/agents/objective-implement.md"
  grep -qx 'Plugin root: ${CLAUDE_PLUGIN_ROOT}' "$ORCA_ROOT/skills/new/loop.md"
  # the documented example carries one
  documented_response | grep -q '"tree": "[0-9a-f]\{40\}"'
}
