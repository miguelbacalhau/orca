#!/usr/bin/env bats
# work-loop.workflow.js — the plan-reconciliation gate: when it runs, where it
# runs, and what a surviving objection does. Driven through the
# tests/run-workflow.js harness (host-style wrapping, stubbed agent()), which
# records every agent call's prompt and opts, so the assertions are on the
# calls the loop actually made.
#
# Every scripted item build here dies at its first relay call (SH_RC=1) or at
# a dead implement agent, and salvage is allowed to fail too — that keeps each
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

BASE='"runDir":"/run","repoRoot":"/repo","slug":"s","integrationBranch":"feature/s","reviewer":"codex","pluginRoot":"/plug"'
ONE_ITEM='[{"id":"W1","title":"one","deps":[],"files":["a.ts"]}]'
TWO_ITEMS='[{"id":"W1","title":"one","deps":[],"files":["a.ts"]},{"id":"W2","title":"two","deps":[],"files":["b.ts"]}]'

# A relayed spec.md hash read: shMarked's markers around a 40-hex value.
HASH_A='"@@OUT@@\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n@@OUT_END@@\nSH_RC=0"'
HASH_B='"@@OUT@@\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n@@OUT_END@@\nSH_RC=0"'
# worktree-item's frame, then a dead implement agent: the shortest build that
# still reaches the implement prompt.
WT_FRAME='"@@ORCA@@\nrc=0\narrival=created\nhead=cccccccccccccccccccccccccccccccccccccccc\n@@ORCA_END@@\nSH_RC=0"'
CLEAN='{"clean":true,"issues":[]}'
OK='"SH_RC=0"'
FAIL='"SH_RC=1"'
# The shortest scriptable mid-build escalation: implement reports the item
# infeasible, which is thrown tagged spec-rooted, so runItem escalates once and
# rebuilds in the kept worktree.
INFEASIBLE='{"completed":false,"summary":"the loader seam does not exist"}'
REBUILD='{"action":"rebuild","reason":"the seam belongs in the spec"}'

# count_calls <substring> — occurrences of a substring in the harness output.
count_calls() {
  printf '%s' "$output" | grep -o "$1" | wc -l | tr -d ' '
}

@test "a one-plan wave takes no reconciliation at all" {
  run_wf "{$BASE,\"items\":$ONE_ITEM}" \
    "[$OK,\"planned\",$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  # No reconcile prompt, and no spec.md hash read to bracket one.
  [[ "$output" != *'Report ONLY a conflict'* ]]
  [[ "$output" != *'hash-object'* ]]
  [[ "$output" == *'"reason":"worktree:W1: command exited 1'* ]]
}

@test "a clean multi-plan pass reconciles once, outside the serialized section" {
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$HASH_A,$CLEAN,$HASH_A,$FAIL,$FAIL,$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'reconcile:W1+W2'* ]]
  # The section is never entered: no in-section re-read, no escalation.
  [[ "$output" != *'reconcile~serial'* ]]
  [[ "$output" != *'You are resolving plan-reconciliation issues'* ]]
  [ "$(count_calls 'Report ONLY a conflict')" = 1 ]
  # Bracketed by two hash reads — before the call and after it.
  [ "$(count_calls 'hash-object')" = 2 ]
}

@test "a spec that moves mid-read is re-reconciled inside the section" {
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$HASH_A,$CLEAN,$HASH_B,$HASH_B,$CLEAN,$FAIL,$FAIL,$FAIL,$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'reconcile~serial:W1+W2'* ]]
  [ "$(count_calls 'Report ONLY a conflict')" = 2 ]
}

@test "a dirty pass over an unmoved spec reuses its verdict — one reconcile, then escalation" {
  local dirty='{"clean":false,"issues":["W1 and W2 both define the cache key"]}'
  local esc='{"replan":[],"cut":[],"blocked":[{"id":"W1","reason":"needs a human decision"},{"id":"W2","reason":"needs a human decision"}],"addDeps":[]}'
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$HASH_A,$dirty,$HASH_A,$esc,$HASH_A,$OK]"
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
    "[$OK,\"p1\",\"p2\",$HASH_A,$dirty,$HASH_A,$esc,$HASH_A,$OK,\"p1b\",$dirty2,\
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
    "[$OK,\"p1\",\"p2\",$HASH_A,$dirty,$HASH_A,$esc,$HASH_B,$OK,\"p1b\",$CLEAN,$FAIL,$FAIL,$FAIL,$FAIL,$OK]"
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
    "[$OK,\"p1\",\"p2\",$FAIL,$dirty,$FAIL,$dirty,$esc,$FAIL,$OK,\"p1b\",$CLEAN,$FAIL,$FAIL,$FAIL,$FAIL,$OK]"
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
    "[$OK,\"p1\",\"p2\",$HASH_A,$dirty,$HASH_A,$esc,$HASH_A,$dirty2,\
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
    "[$OK,\"p1\",\"p2\",$HASH_A,$dirty,$HASH_A,$esc,$HASH_A,$OK,$CLEAN,\
$WT_FRAME,{\"die\":true},$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'plan-archive:W2#deferred'* ]]
  [[ "$output" == *'"id":"W2","reason":"dependency blocked: W1"'* ]]
}

@test "a mid-build rebuild that amended nothing says so, and sheds the plan objection" {
  local dirty='{"clean":false,"issues":["W1 assumes a shape the Interfaces section defines differently"]}'
  local esc='{"replan":[],"cut":[],"blocked":[{"id":"W2","reason":"needs a human decision"}],"addDeps":[]}'
  local dirty2='{"clean":false,"issues":["W1 still contradicts the defined shape"]}'
  # W1 builds with the surviving objection, reports itself infeasible, and the
  # mid-build escalation answers "rebuild" over a spec.md hash that never moved.
  run_wf "{$BASE,\"items\":$TWO_ITEMS}" \
    "[$OK,\"p1\",\"p2\",$HASH_A,$dirty,$HASH_A,$esc,$HASH_A,$dirty2,\
$WT_FRAME,$INFEASIBLE,$HASH_A,$REBUILD,$HASH_A,$OK,\"p1r\",$WT_FRAME,{\"die\":true},$FAIL,$OK]"
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
    "[$OK,\"p1\",$WT_FRAME,$INFEASIBLE,$HASH_A,$REBUILD,$HASH_B,$OK,\"p1r\",\
$WT_FRAME,{\"die\":true},$FAIL,$OK]"
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'spec-rooted and amended spec.md in response'* ]]
  [[ "$output" != *'did NOT amend'* ]]
  [ "$(count_calls 'plan:W1#rebuild')" = 1 ]
}
