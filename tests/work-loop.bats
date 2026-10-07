#!/usr/bin/env bats
# work-loop.workflow.js — the plan-reconciliation gate: when it runs, where it
# runs, and what a surviving objection does. Driven through the
# tests/run-workflow.js harness (host-style wrapping, stubbed agent()), which
# records every agent call's prompt and opts, so the assertions are on the
# calls the loop actually made.
#
# Every verb call is answered the way orca's verb hook answers it (`b64:` +
# base64 of the UTF-8 JSON {v, rc, stdout, stderr}); the hook is the work
# loop's only way to orca.sh. Every scripted item build here dies at its
# first verb call (rc 1) or at a dead implement agent, and salvage is
# allowed to fail too — that keeps each
# item's post-gate call shape identical, so the response script stays
# order-independent across the two items.

load helpers

setup_file() {
  command -v node >/dev/null || skip "node not available"
}

# run_wf <args-json> <responses-json>
run_wf() {
  run node "$ORCA_ROOT/tests/run-workflow.js" "$SCRIPTS/work-loop.workflow.js" "$1" "$2"
}

# json_str <s> — <s> as a JSON string literal (frames: ASCII, newlines, tabs;
# UTF-8 passes through raw, which JSON allows).
json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}
# hook_json <answer-json> — the hook's encoded answer, as a JSON string.
hook_json() {
  printf '"b64:%s"' "$(printf '%s' "$1" | base64 | tr -d '\n')"
}
# hook_run <rc> <stdout> [stderr] — the hook's answer for a verb that ran.
hook_run() {
  hook_json "{\"v\":1,\"rc\":$1,\"stdout\":$(json_str "$2"),\"stderr\":$(json_str "${3:-}")}"
}
# frame <key=value>... — a verb's stdout frame.
frame() {
  printf '@@ORCA@@\n'; printf '%s\n' "$@"; printf '@@ORCA_END@@\n'
}
# args_frag <arg>... — how a run of verb arguments appears in the harness
# output: inside the JSON-escaped model name, one array entry each.
args_frag() {
  local out="" sep="" a
  for a in "$@"; do out+="$sep\\\"$a\\\""; sep=","; done
  printf '%s' "$out"
}
# req <verb> [arg]... — a verb request's model name (a prefix: the args
# given are the first ones), as it appears in the harness output.
req() {
  local verb=$1; shift
  printf '\\"verb\\":\\"%s\\",\\"args\\":[%s' "$verb" "$(args_frag "$@")"
}

BASE='"runDir":"/run","repoRoot":"/repo","slug":"s","integrationBranch":"feature/s","reviewer":"codex","pluginRoot":"/plug"'
ONE_ITEM='[{"id":"W1","title":"one","deps":[],"files":["a.ts"]}]'
TWO_ITEMS='[{"id":"W1","title":"one","deps":[],"files":["a.ts"]},{"id":"W2","title":"two","deps":[],"files":["b.ts"]}]'

A40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# A verb that succeeded with nothing to say (triage, secrets), and one that
# failed with its typed line.
OK="$(hook_run 0 '')"
FAIL="$(hook_run 1 $'FAIL:\tSCRIPTED\tscripted failure')"
# The spec verb's answers: a `spec mark` reading, and `spec changed` against
# an earlier one — unmoved, or moved to a new mark.
MARK_A="$(hook_run 0 "$(frame rc=0 mark=$A40)")"
SAME="$(hook_run 0 "$(frame rc=0 changed=no mark=$A40)")"
MOVED="$(hook_run 0 "$(frame rc=0 changed=yes mark=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)")"
# `archive attempt`: one call for a superseded attempt's plan and reviews.
ARCHIVED="$(hook_run 0 "$(frame rc=0 plan=archived reviews=archived)")"
# worktree-item's frame, then a dead implement agent: the shortest build that
# still reaches the implement prompt.
WT_FRAME="$(hook_run 0 "$(frame rc=0 arrival=created head=cccccccccccccccccccccccccccccccccccccccc)")"
CLEAN='{"clean":true,"issues":[]}'
# The shortest scriptable mid-build escalation: implement reports the item
# infeasible, which is thrown tagged spec-rooted, so runItem escalates once and
# rebuilds in the kept worktree.
INFEASIBLE='{"completed":false,"summary":"the loader seam does not exist"}'
REBUILD='{"action":"rebuild","reason":"the seam belongs in the spec"}'

# count_calls <substring> — occurrences of a substring in the harness output.
count_calls() {
  printf '%s' "$output" | grep -oF -- "$1" | wc -l | tr -d ' '
}

@test "a one-plan wave takes no reconciliation at all" {
  run_wf "{$BASE,\"items\":$ONE_ITEM}" \
    "[$OK,\"planned\",$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  # No reconcile prompt, and no spec.md reading to bracket one.
  [[ "$output" != *'Report ONLY a conflict'* ]]
  [[ "$output" != *"$(req spec mark)"* ]]
  [[ "$output" != *"$(req spec changed)"* ]]
  [[ "$output" == *'"reason":"worktree:W1: command exited 1'* ]]
}

@test "a clean multi-plan pass reconciles once, outside the serialized section" {
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$MARK_A,$CLEAN,$SAME,$FAIL,$FAIL,$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'reconcile:W1+W2'* ]]
  # The section is never entered: no in-section re-read, no escalation.
  [[ "$output" != *'reconcile~serial'* ]]
  [[ "$output" != *'You are resolving plan-reconciliation issues'* ]]
  [ "$(count_calls 'Report ONLY a conflict')" = 1 ]
  # Bracketed by two spec readings — a mark before the call, then a
  # comparison against that mark after it.
  [ "$(count_calls "$(req spec mark /run)")" = 1 ]
  [ "$(count_calls "$(req spec changed /run $A40)")" = 1 ]
}

@test "a spec that moves mid-read is re-reconciled inside the section" {
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$MARK_A,$CLEAN,$MOVED,$MOVED,$CLEAN,$FAIL,$FAIL,$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'reconcile~serial:W1+W2'* ]]
  [ "$(count_calls 'Report ONLY a conflict')" = 2 ]
}

@test "a dirty pass over an unmoved spec reuses its verdict — one reconcile, then escalation" {
  local dirty='{"clean":false,"issues":["W1 and W2 both define the cache key"]}'
  local esc='{"replan":[],"cut":[],"blocked":[{"id":"W1","reason":"needs a human decision"},{"id":"W2","reason":"needs a human decision"}],"addDeps":[]}'
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$MARK_A,$dirty,$SAME,$esc,$SAME,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [ "$(count_calls 'Report ONLY a conflict')" = 1 ]
  [[ "$output" != *'reconcile~serial'* ]]
  [[ "$output" == *'REPLAN alone is the whole fix'* ]]
  [[ "$output" == *'"id":"W1","reason":"needs a human decision"'* ]]
}

@test "a replan-only escalation says the spec was not amended, and the survivor builds with the objection" {
  local dirty='{"clean":false,"issues":["W1 assumes a shape the Interfaces section defines differently"]}'
  local esc='{"replan":["W1"],"cut":[],"blocked":[],"addDeps":[]}'
  local dirty2='{"clean":false,"issues":["W1 still contradicts the defined shape"]}'
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$MARK_A,$dirty,$SAME,$esc,$SAME,$ARCHIVED,\"p1b\",$dirty2,\
$WT_FRAME,$WT_FRAME,{\"die\":true},{\"die\":true},$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  # The spec hash never moved across the escalation, so the replan note must
  # not promise a Decisions bullet that was never written.
  [[ "$output" == *'spec.md was NOT amended in response'* ]]
  [[ "$output" != *'plan failed cross-plan reconciliation, and spec.md was amended'* ]]
  # The unresolved objection does not block: W1 reaches its implement prompt
  # carrying it, and W2 — named by nothing — does not.
  [ "$(count_calls 'Unresolved plan objection')" = 1 ]
  [[ "$output" == *'Unresolved plan objection: W1 still contradicts the defined shape'* ]]
  # W1 cleared the gate: the only thing that blocked it is its own scripted
  # build failure, three stages downstream of reconciliation.
  [[ "$output" == *'"id":"W1","reason":"implement:W1: agent was skipped or returned no result"'* ]]
}

@test "an escalation that does amend keeps the Decisions-log note" {
  local dirty='{"clean":false,"issues":["W1 and W2 assume different shapes for the cache key"]}'
  local esc='{"replan":["W1"],"cut":[],"blocked":[],"addDeps":[]}'
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$MARK_A,$dirty,$SAME,$esc,$MOVED,$ARCHIVED,\"p1b\",$CLEAN,$FAIL,$FAIL,$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'spec.md was amended in response'* ]]
  [[ "$output" != *'NOT amended'* ]]
  [[ "$output" != *'Unresolved plan objection'* ]]
}

@test "an unreadable spec hash falls back to the serialized re-read and the amendment note" {
  local dirty='{"clean":false,"issues":["W1 and W2 collide on the same module"]}'
  local esc='{"replan":["W1"],"cut":[],"blocked":[],"addDeps":[]}'
  # Every hash read fails (nonzero exit), so the gate assumes the spec moved.
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$FAIL,$dirty,$FAIL,$dirty,$esc,$FAIL,$ARCHIVED,\"p1b\",$CLEAN,$FAIL,$FAIL,$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'reconcile~serial:W1+W2'* ]]
  [[ "$output" == *'spec.md was amended in response'* ]]
}

@test "an issue naming only a non-live wave item seeds that item, not the innocent siblings" {
  local dirty='{"clean":false,"issues":["W1 and W2 disagree on the cache key"]}'
  local esc='{"replan":[],"cut":[],"blocked":[{"id":"W2","reason":"needs a human decision"}],"addDeps":[]}'
  # The surviving issue names only W2 — which the escalation just blocked, so
  # it is in the wave but not live. Matching against live items alone would
  # call this unattributable and broadcast it to W1, the one item it is not
  # about, while never reaching its actual subject.
  local dirty2='{"clean":false,"issues":["W2 still owns the key it should not"]}'
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$MARK_A,$dirty,$SAME,$esc,$SAME,$dirty2,\
$WT_FRAME,{\"die\":true},$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  # Recorded against W2 and returned as the run's durable trace of it.
  [[ "$output" == *'"objections":[{"id":"W2","issues":["W2 still owns the key it should not"]}]'* ]]
  # W1 builds carrying nothing: it reaches its implement prompt clean.
  [[ "$output" == *'implement:W1'* ]]
  [[ "$output" != *'Unresolved plan objection'* ]]
}

@test "a deferred item's plan is archived so its relaunch plans fresh" {
  local dirty='{"clean":false,"issues":["W2 needs the loader W1 owns"]}'
  # An added dependency and no replan at all: W2 goes back to pending with a
  # plan written before the escalation, and pump() will replan it with no
  # replan note — so the superseded plan has to be off disk.
  local esc='{"replan":[],"cut":[],"blocked":[],"addDeps":[{"id":"W2","dependsOn":["W1"]}]}'
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$MARK_A,$dirty,$SAME,$esc,$SAME,$ARCHIVED,$CLEAN,\
$WT_FRAME,{\"die\":true},$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'plan-archive:W2#deferred'* ]]
  # Its review files go with it in the same call — the verb moves them into
  # the first prev<N>/ holding nothing of W2 (tests/verbs.bats), so the
  # relaunch's round0 never overwrites them in place.
  [ "$(count_calls "$(req archive attempt /run W2)")" = 1 ]
  [[ "$output" != *'review-archive:'* ]]
  [[ "$output" == *'"id":"W2","reason":"dependency blocked: W1"'* ]]
}

@test "a mid-build rebuild that amended nothing says so, and sheds the plan objection" {
  local dirty='{"clean":false,"issues":["W1 assumes a shape the Interfaces section defines differently"]}'
  local esc='{"replan":[],"cut":[],"blocked":[{"id":"W2","reason":"needs a human decision"}],"addDeps":[]}'
  local dirty2='{"clean":false,"issues":["W1 still contradicts the defined shape"]}'
  # W1 builds with the surviving objection, reports itself infeasible, and the
  # mid-build escalation answers "rebuild" over a spec.md hash that never moved.
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$MARK_A,$dirty,$SAME,$esc,$SAME,$dirty2,\
$WT_FRAME,$INFEASIBLE,$MARK_A,$REBUILD,$SAME,$ARCHIVED,\"p1r\",$WT_FRAME,{\"die\":true},$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  # "rebuild" is the action, not evidence the file moved — the note says what
  # the hash saw, and sends nobody hunting for a Decisions bullet.
  [[ "$output" == *'spec-rooted but did NOT amend spec.md'* ]]
  [[ "$output" != *'spec-rooted and amended spec.md in response'* ]]
  # The objection reached the first implement prompt and died with the plan it
  # was raised against: the rebuild's implementer never sees it.
  [ "$(count_calls 'Unresolved plan objection')" = 1 ]
  [[ "$output" == *'"objections":[]'* ]]
}

@test "a mid-build rebuild that did amend keeps the Decisions-log note" {
  # One item, so no gate at all: the hash reads here are the escalation
  # bracket's and nothing else. The second one differs — spec.md moved.
  run_wf "{$BASE,\"items\":$ONE_ITEM}" \
    "[$OK,\"p1\",$WT_FRAME,$INFEASIBLE,$MARK_A,$REBUILD,$MOVED,$ARCHIVED,\"p1r\",\
$WT_FRAME,{\"die\":true},$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'spec-rooted and amended spec.md in response'* ]]
  [[ "$output" != *'did NOT amend'* ]]
  [ "$(count_calls 'plan:W1#rebuild')" = 1 ]
}

# ---------- the fix loop's entry gate ----------
# One item built to its first review: worktree frame, a completed implement,
# the secrets-remove verb, then the review verdict. What follows the verdict
# is the assertion.
IMPLEMENTED='{"completed":true,"summary":"done"}'

@test "medium and low findings alone do not open the fix loop" {
  local verdict='{"written":true,"total":3,"criticalHigh":0,"reason":""}'
  # After the verdict the item goes straight to commit; its first
  # commit-verify fails, which is the shortest way to end the item there.
  run_wf "{$BASE,\"items\":$ONE_ITEM}" \
    "[$OK,\"p1\",$WT_FRAME,$IMPLEMENTED,$OK,$verdict,$FAIL,$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'review:W1#0'* ]]
  [[ "$output" != *'fix:W1#1'* ]]
  [[ "$output" != *'review:W1#1'* ]]
  # Blocked three stages later, at the scripted commit failure — not at review.
  [[ "$output" == *'"id":"W1","reason":"commit'* ]]
}

@test "a critical or high finding opens the fix loop" {
  local verdict='{"written":true,"total":1,"criticalHigh":1,"reason":""}'
  # secrets-place, then a dead fix agent ends the item inside the loop.
  run_wf "{$BASE,\"items\":$ONE_ITEM}" \
    "[$OK,\"p1\",$WT_FRAME,$IMPLEMENTED,$OK,$verdict,$OK,{\"die\":true},$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'fix:W1#1'* ]]
  [[ "$output" == *'"id":"W1","reason":"fix:W1#1: agent was skipped or returned no result"'* ]]
}

# ---------- the merge section and the integration tail ----------
# One item built clean through commit: worktree, implement, secrets-remove, a
# clean review, the commit agent, and commit-verify's accepted frame. The
# merge section follows.
CLEAN_REVIEW='{"written":true,"total":0,"criticalHigh":0,"reason":""}'
CV_FRAME="$(hook_run 0 "$(frame rc=0 action=accepted hash=cccccccccccccccccccccccccccccccccccccccc message.b64=ZmVhdDogb25l)")"
BUILT="$OK,\"p1\",$WT_FRAME,$IMPLEMENTED,$OK,$CLEAN_REVIEW,\"committed\",$CV_FRAME"
D40=dddddddddddddddddddddddddddddddddddddddd
MP_FRAME="$(hook_run 0 "$(frame rc=0 reset=hard base=$D40)")"
MF_FRAME="$(hook_run 0 "$(frame rc=0 tip=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee commit=agent attribution=clean ledger=written cleanup=done)")"
MERGED='{"merged":true,"detail":"squashed"}'
MERGED_ITEM="$BUILT,$MP_FRAME,$MERGED,$MF_FRAME"

@test "merge-prepare's base reaches merge-finalize verbatim" {
  # After the merge: provisioning fails (non-fatal) and the verifier applies no fixes.
  run_wf "{$BASE,\"items\":$ONE_ITEM}" \
    "[$MERGED_ITEM,$FAIL,{\"features\":[],\"fixesApplied\":false,\"gaps\":[]},$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"label":"merge-reset:W1"'* ]]
  [ "$(count_calls "$(req merge-prepare /repo/orca-s)")" = 1 ]
  [ "$(count_calls "$(args_frag $D40 W1 --title-b64)")" = 1 ]
  [[ "$output" == *'"shipped":[{"id":"W1"'* ]]
  [[ "$output" == *'"deliverableState":"verified"'* ]]
}

@test "a malformed merge base blocks the item before the merge agent runs" {
  local garbled
  garbled="$(hook_run 0 "$(frame rc=0 reset=none 'base=dddd; rm -rf /')")"
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$BUILT,$garbled,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" != *'"label":"merge:W1"'* ]]
  [[ "$output" != *'merge-finalize'* ]]
  [[ "$output" == *'"id":"W1","reason":"merge-reset:W1: verb returned a malformed marker'* ]]
}

@test "integration fixes: archived stale reviews, persisted notes, commit-prepare's base to commit-verify" {
  local fixes='{"features":[],"fixesApplied":true,"gaps":[]}'
  local archived
  archived="$(hook_run 0 "$(frame rc=0 plan=none reviews=archived)")"
  local one_medium='{"written":true,"total":1,"criticalHigh":0,"reason":""}'
  local fixed='{"declines":["cache key — out of scope"],"escalations":[],"summary":"s"}'
  local notes prep f40=ffffffffffffffffffffffffffffffffffffffff
  notes="$(hook_run 0 "$(frame rc=0 written=/run/integration-fixes.json)")"
  prep="$(hook_run 0 "$(frame rc=0 pending=yes base=$f40)")"
  # provision FAIL, verify, archive, secrets-remove, review, secrets-place,
  # fix, secrets-remove, clean re-review, secrets-restore, notes,
  # commit-prepare, commit agent, commit-verify, lease release.
  run_wf "{$BASE,\"items\":$ONE_ITEM}" \
    "[$MERGED_ITEM,$FAIL,$fixes,$archived,$OK,$one_medium,$OK,$fixed,$OK,$CLEAN_REVIEW,$OK,$notes,$prep,\"committed\",$CV_FRAME,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"label":"integration-review-clean"'* ]]
  [ "$(count_calls "$(req archive attempt /run integration)")" = 1 ]
  [[ "$output" != *'rm -f'* ]]
  # The notes reach the verb base64-encoded and decode to the fixer's return.
  local b64
  b64="$(printf '%s' "$output" | grep -oE 'integration-fixes\\",\\"[A-Za-z0-9+/=]+' | sed 's/.*\\"//')"
  [ -n "$b64" ]
  [[ "$(printf '%s' "$b64" | base64 --decode)" == *'"cache key — out of scope"'* ]]
  [ "$(count_calls "$(args_frag $f40 integration --branch)")" = 1 ]
  [[ "$output" == *'"deliverableState":"verified"'* ]]
}

@test "integration review artifacts that cannot be archived leave the fixes uncommitted" {
  local fixes='{"features":[],"fixesApplied":true,"gaps":[]}'
  local failed
  failed="$(hook_run 0 "$(frame rc=0 plan=none reviews=failed)")"
  # provision FAIL, verify, the failed archive, secrets-restore, lease release.
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$MERGED_ITEM,$FAIL,$fixes,$failed,$OK,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" != *'"label":"review:integration#0"'* ]]
  [[ "$output" != *'commit-prepare'* ]]
  [[ "$output" == *'could not be archived'* ]]
  [[ "$output" == *'"deliverableState":"unverified"'* ]]
}

# ---------- the one call shape: orca(verb, args, keys, label, phase) ----------
# Call sites hand orca() a verb and plain-string args; the request rides in
# the model name orca's verb hook reads, `orca:{"v":1,"verb":…,"args":[…]}`.
# The shortest run that reaches four verbs: lease claim, worktree-item
# (fails), salvage (fails), lease release.

@test "every verb request is the verb and its arguments, one array entry each, under the call's label" {
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$OK,\"planned\",$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  # The lease note's `;` is data, never a separator: no shell sees it.
  [[ "$output" == *'"prompt":"","opts":{"model":"orca:{\"v\":1,\"verb\":\"triage\",\"args\":[\"claim\",\"/run\",\"orca work loop; slug=s; branch=feature/s\"]}","label":"run-lease","phase":"Plan"}'* ]]
  [[ "$output" == *'"model":"orca:{\"v\":1,\"verb\":\"worktree-item\",\"args\":[\"/repo/orca-s\",\"/repo/orca-s-W1\",\"feature/s-W1\",\"feature/s\"]}","label":"worktree:W1"'* ]]
  [[ "$output" == *'"model":"orca:{\"v\":1,\"verb\":\"salvage\",\"args\":[\"/repo/orca-s-W1\",\"/repo/orca-s\",\"W1\"]}","label":"salvage:W1"'* ]]
  [[ "$output" == *'"model":"orca:{\"v\":1,\"verb\":\"triage\",\"args\":[\"release\",\"/run\"]}","label":"run-lease-release"'* ]]
  # The run's first call is the lease claim: no ping, no other agent before it.
  [[ "$output" == *'"calls":[{"prompt":"","opts":{"model":"orca:{\"v\":1,\"verb\":\"triage\",\"args\":[\"claim\"'* ]]
  # A failed verb's typed line is the error's tail.
  [[ "$output" == *'"id":"W1","reason":"worktree:W1: command exited 1: FAIL:\tSCRIPTED\tscripted failure"'* ]]
}

@test "an argument carrying a single quote reaches the verb as one argument" {
  run_wf "{\"runDir\":\"/ru'n\",\"repoRoot\":\"/repo\",\"slug\":\"s\",\"integrationBranch\":\"feature/s\",\"reviewer\":\"codex\",\"pluginRoot\":\"/plug\",\"items\":$ONE_ITEM}" \
    "[$OK,\"planned\",$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *"$(req triage claim "/ru'n")"* ]]
  [[ "$output" == *"$(req triage release "/ru'n")]"* ]]
}

@test "a failed verb's stderr joins its stdout in the error" {
  local fail
  fail="$(hook_run 1 $'FAIL:\tBAD\tno worktree' 'stderr tail')"
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$OK,\"planned\",$fail,$FAIL,$OK]"
  [[ "$output" == *'"id":"W1","reason":"worktree:W1: command exited 1: FAIL:\tBAD\tno worktree\nstderr tail"'* ]]
}

@test "a frame that does not decode fails the caller at once, never retried" {
  local garbled undeclared
  garbled="$(hook_run 0 'no frame here')"
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$OK,\"planned\",$garbled,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [ "$(count_calls '"label":"worktree:W1"')" = 1 ]
  [[ "$output" == *'"id":"W1","reason":"worktree:W1: verb frame did not decode: frame markers missing from verb output"'* ]]
  # The decoder is strict: a line opening no declared key is a failure, not
  # a continuation of the previous value.
  undeclared="$(hook_run 0 "$(frame rc=0 arrival=created head=cccccccccccccccccccccccccccccccccccccccc surprise=1)")"
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$OK,\"planned\",$undeclared,$FAIL,$OK]"
  [[ "$output" == *'"id":"W1","reason":"worktree:W1: verb frame did not decode: frame line opens no declared key: surprise=1"'* ]]
}

@test "a malformed worktree head blocks the item before its implement agent runs" {
  local garbled
  garbled="$(hook_run 0 "$(frame rc=0 arrival=created 'head=cccc | rm -rf /')")"
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$OK,\"planned\",$garbled,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" != *'"label":"implement:W1"'* ]]
  [[ "$output" == *'"id":"W1","reason":"worktree:W1: verb returned a malformed marker'* ]]
}

@test "the hook's base64 decodes UTF-8 — frames and failures alike" {
  local held
  held="$(hook_run 1 $'FAIL:\tLEASE_HELD\tcafé — 汉字 🎉')"
  # A frame through the hook decodes: worktree-item's head reaches implement.
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$OK,\"planned\",$WT_FRAME,{\"die\":true},$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"label":"implement:W1"'* ]]
  # Non-ASCII survives the round trip into the error.
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$held]"
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *'LEASE_HELD\tcafé — 汉字 🎉'* ]]
}

# ---------- the hook failing: loud, at the call, naming the cause ----------
# The run's first verb is the lease claim, so a session whose hook is missing
# or refuses fails there — the workflow throws, before any agent has run.

@test "no answer at all: the hooks module is not loaded — the run fails at its first verb, naming the fixes" {
  run_wf "{$BASE,\"items\":$ONE_ITEM}" '[{"die":true}]'
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *"run-lease: no answer from orca's verb hook for \`orca.sh triage\`: the request went to the API instead"* ]]
  [[ "$output" == *"orca's hooks module is not loaded in this session"* ]]
  [[ "$output" == *'there is no fallback'* ]]
  [[ "$output" == *'function hooks (mods) enabled'* ]]
  [[ "$output" == *'not with --bare'* ]]
  [[ "$output" == *'disableAllHooks'* ]]
  # Nothing after it ran: one call, the claim.
  [ "$(count_calls '"prompt":')" = 1 ]
}

@test "a refusal fails the run with the hook's reason and the fix" {
  local refused
  refused="$(hook_json '{"v":1,"refused":"permission mode is default; orca runs verbs here only in bypassPermissions sessions"}')"
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$refused]"
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *"run-lease: orca's verb hook refused \`orca.sh triage\`: permission mode is default; orca runs verbs here only in bypassPermissions sessions."* ]]
  [[ "$output" == *'To fix: switch this session to bypass permissions (Shift+Tab'* ]]
  [[ "$output" == *"This answer is in the run's journal, so resuming the run replays it."* ]]
  [ "$(count_calls '"prompt":')" = 1 ]
  # A refusal that is not about the mode carries no mode advice.
  refused="$(hook_json '{"v":1,"refused":"verb \"triage\" is not on the work loop'"'"'s allow-list"}')"
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$refused]"
  [[ "$output" == *"run-lease: orca's verb hook refused \`orca.sh triage\`: verb"* ]]
  [[ "$output" != *'Shift+Tab'* ]]
}

@test "a hook error fails the run naming the verb" {
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$(hook_json '{"v":1,"error":"orca.sh triage did not run to completion: spawn bash ENOENT"}')]"
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *"run-lease: orca's verb hook failed running \`orca.sh triage\`: orca.sh triage did not run to completion: spawn bash ENOENT."* ]]
}

@test "a timeout names the verb, and for worktree setup points at .orca/setup" {
  local timeout
  timeout="$(hook_json '{"v":1,"timedOut":true,"error":"orca.sh triage was still running after 10 minutes, the longest $.process.run allows, and was stopped: timed out"}')"
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$timeout]"
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *"run-lease: \`orca.sh triage\` timed out in orca's verb hook: orca.sh triage was still running after 10 minutes"* ]]
  [[ "$output" != *'.orca/setup'* ]]
  # Mid-run, at worktree-item: the item blocks with the cause, and the
  # likely culprit is named.
  timeout="$(hook_json '{"v":1,"timedOut":true,"error":"orca.sh worktree-item was still running after 10 minutes, the longest $.process.run allows, and was stopped: timed out"}')"
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$OK,\"planned\",$timeout,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *"\"id\":\"W1\",\"reason\":\"worktree:W1: \`orca.sh worktree-item\` timed out in orca's verb hook: orca.sh worktree-item was still running after 10 minutes"* ]]
  [[ "$output" == *"The likely cause is the repository's .orca/setup script"* ]]
}

@test "malformed hook answers fail the run, each naming its cause" {
  run_wf "{$BASE,\"items\":$ONE_ITEM}" '["plain model text"]'
  [[ "$output" == *"run-lease: malformed answer from orca's verb hook for \`orca.sh triage\`: not a b64: answer (plain model text)"* ]]
  run_wf "{$BASE,\"items\":$ONE_ITEM}" '["b64:%%%"]'
  [[ "$output" == *"run-lease: malformed answer from orca's verb hook for \`orca.sh triage\`: it does not decode"* ]]
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$(hook_json '[1]')]"
  [[ "$output" == *"malformed answer from orca's verb hook for \`orca.sh triage\`: not an object"* ]]
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$(hook_json '{"v":1,"stdout":""}')]"
  [[ "$output" == *"malformed answer from orca's verb hook for \`orca.sh triage\`: it needs an integer rc and a string stdout"* ]]
  run_wf "{$BASE,\"items\":$ONE_ITEM}" "[$(hook_json '{"v":2,"rc":0,"stdout":""}')]"
  [[ "$output" == *"malformed answer from orca's verb hook for \`orca.sh triage\`: protocol version 2, this workflow speaks 1"* ]]
  [[ "$output" == *'"ok":false'* ]]
}

@test "a hook failure mid-run starts nothing more and skips verification" {
  # W1 builds and merges, but its secrets-remove meets no hook (fail-soft
  # there); W2, which waits on W1, never starts.
  local dep='[{"id":"W1","title":"one","deps":[],"files":["a.ts"]},{"id":"W2","title":"two","deps":["W1"],"files":["b.ts"]}]'
  local verdict='{"written":true,"total":0,"criticalHigh":0,"reason":""}'
  run_wf "{$BASE,\"items\":$dep}" \
    "[$OK,\"p1\",$WT_FRAME,{\"completed\":true,\"summary\":\"done\"},{\"die\":true},$verdict,\"committed\",$CV_FRAME,$MP_FRAME,{\"merged\":true,\"detail\":\"squashed\"},$MF_FRAME,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"shipped":[{"id":"W1"'* ]]
  [[ "$output" == *"\"id\":\"W2\",\"reason\":\"run stopped: orca's verb hook failed: secrets-remove:W1#0: no answer from orca's verb hook"* ]]
  [[ "$output" != *'"label":"plan:W2"'* ]]
  [[ "$output" != *'"label":"integration-verify"'* ]]
  [[ "$output" == *"integration verification did not run: orca's verb hook failed: secrets-remove:W1#0"* ]]
  [[ "$output" == *'"deliverableState":"unverified"'* ]]
}

@test "the hook's allow-list is exactly the verbs the work loop calls" {
  local called allowed
  called="$(grep -oE "orca\('[a-z-]+'" "$SCRIPTS/work-loop.workflow.js" | sed "s/orca('//; s/'//" | sort -u)"
  allowed="$(sed -n '/^export const ALLOWED/,/^}/p' "$ORCA_ROOT/hooks/relay.ts" | grep -oE "^  '[a-z-]+'" | tr -d " '" | grep -v '^self-test$' | sort -u)"
  [ -n "$called" ]
  [ "$called" = "$allowed" ]
}
