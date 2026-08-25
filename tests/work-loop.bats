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
  [[ "$output" != *'unresolved after amendment'* ]]
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
