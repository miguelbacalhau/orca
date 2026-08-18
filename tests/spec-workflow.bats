#!/usr/bin/env bats
# spec.workflow.js — launch-time arg validation and the gated
# spec → review → revise sequence's return shape, run through the
# tests/run-workflow.js harness (host-style wrapping, stubbed agent()).

load helpers

setup_file() {
  command -v node >/dev/null || skip "node not available"
}

# run_wf <args-json> <responses-json>
run_wf() {
  run node "$ORCA_ROOT/tests/run-workflow.js" "$SCRIPTS/spec.workflow.js" "$1" "$2"
}

ARGS='{"prompt":"SPEC TASK","runDir":"/run","reviewWorktree":"/wt","reviewer":"codex"}'
CLEAN='{"written":true,"total":0,"criticalHigh":0,"reason":""}'

@test "rejects a missing prompt at launch" {
  run_wf '{"runDir":"/run","reviewWorktree":"/wt","reviewer":"codex"}' '[]'
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *'args.prompt must be a non-empty string'* ]]
  [[ "$output" == *'"calls":[]'* ]]
}

@test "rejects a relative runDir and reviewWorktree at launch" {
  run_wf '{"prompt":"p","runDir":"run","reviewWorktree":"/wt","reviewer":"codex"}' '[]'
  [[ "$output" == *'args.runDir must be an absolute path'* ]]
  run_wf '{"prompt":"p","runDir":"/run","reviewWorktree":"wt","reviewer":"codex"}' '[]'
  [[ "$output" == *'args.reviewWorktree must be an absolute path'* ]]
}

@test "rejects a reviewer outside codex|claude at launch" {
  run_wf '{"prompt":"p","runDir":"/run","reviewWorktree":"/wt","reviewer":"gemini"}' '[]'
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *'args.reviewer must be \"codex\" or \"claude\"'* ]]
}

@test "rejects a model or effort outside the shared vocabulary" {
  run_wf '{"prompt":"p","runDir":"/run","reviewWorktree":"/wt","reviewer":"codex","model":"gpt5"}' '[]'
  [[ "$output" == *'args.model must be one of'* ]]
  run_wf '{"prompt":"p","runDir":"/run","reviewWorktree":"/wt","reviewer":"codex","effort":"extreme"}' '[]'
  [[ "$output" == *'args.effort must be one of'* ]]
}

@test "a dead spec agent returns died:true with no review key" {
  run_wf "$ARGS" '[{"die":true}]'
  [[ "$output" == *'"result":{"summary":null,"died":true}'* ]]
}

@test "clean round 1: one review round, no revise, review shape on the return" {
  run_wf "$ARGS" '["spec summary",'"$CLEAN"']'
  [[ "$output" == *'"summary":"spec summary","died":false'* ]]
  [[ "$output" == *'"review":{"written":true,"total":0,"criticalHigh":0,"rounds":1,"reason":""}'* ]]
  # exactly two agent calls: spec, then the codex spec reviewer with the
  # artifact and round-1 archive paths in its task message
  [[ "$output" != *'spec-review#2'* ]]
  [[ "$output" == *'"agentType":"orca:spec-review-codex"'* ]]
  [[ "$output" == *'/run/reviews/spec-codex.json'* ]]
  [[ "$output" == *'/run/reviews/spec-codex.round1.json'* ]]
}

@test "reviewer claude selects the claude spec reviewer and its artifact paths" {
  run_wf '{"prompt":"p","runDir":"/run","reviewWorktree":"/wt","reviewer":"claude"}' '["s",'"$CLEAN"']'
  [[ "$output" == *'"agentType":"orca:spec-review-claude"'* ]]
  [[ "$output" == *'/run/reviews/spec-claude.json'* ]]
}

@test "spec overrides tune the spec agent, never the reviewer" {
  run_wf '{"prompt":"p","runDir":"/run","reviewWorktree":"/wt","reviewer":"codex","model":"opus","effort":"max"}' \
    '["s",'"$CLEAN"']'
  [[ "$output" == *'"label":"spec","phase":"Spec","model":"opus","effort":"max"'* ]]
  # the override appears exactly once — on the spec call, never the reviewer's
  [ "$(grep -o '"model":"opus"' <<<"$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "Critical/High findings drive one revise spawn and a round-2 re-review" {
  run_wf "$ARGS" \
    '["s1",{"written":true,"total":3,"criticalHigh":2,"reason":""},"s2",{"written":true,"total":1,"criticalHigh":0,"reason":""}]'
  [[ "$output" == *'"summary":"s2","died":false'* ]]
  [[ "$output" == *'"review":{"written":true,"total":1,"criticalHigh":0,"rounds":2,"reason":""}'* ]]
  # the revise spawn is an orca:spec re-spawn carrying the findings path
  [[ "$output" == *'"label":"spec-revise","phase":"Revise"'* ]]
  [[ "$output" == *'REVISE ROUND'* ]]
  [[ "$output" == *'/run/reviews/spec-codex.round2.json'* ]]
}

@test "gate exhausted: round 2 still Critical/High comes back written with the counts" {
  run_wf "$ARGS" \
    '["s1",{"written":true,"total":2,"criticalHigh":2,"reason":""},"s2",{"written":true,"total":1,"criticalHigh":1,"reason":""}]'
  [[ "$output" == *'"review":{"written":true,"total":1,"criticalHigh":1,"rounds":2,"reason":""}'* ]]
}

@test "fail open: a dead then written:false reviewer returns written:false with the reason" {
  run_wf "$ARGS" '["s",{"die":true},{"written":false,"total":0,"criticalHigh":0,"reason":"boom"}]'
  [[ "$output" == *'"summary":"s","died":false'* ]]
  [[ "$output" == *'"review":{"written":false,"total":0,"criticalHigh":0,"rounds":0,"reason":"boom"}'* ]]
  [[ "$output" == *'spec-review#1~retry'* ]]
}

@test "an impossible count (criticalHigh > total) is retried like written:false" {
  run_wf "$ARGS" \
    '["s",{"written":true,"total":0,"criticalHigh":2,"reason":""},'"$CLEAN"']'
  [[ "$output" == *'"review":{"written":true,"total":0,"criticalHigh":0,"rounds":1,"reason":""}'* ]]
  [[ "$output" == *'spec-review#1~retry'* ]]
}

@test "a dead revise spawn leaves the round-1 findings standing (written, rounds:1)" {
  run_wf "$ARGS" \
    '["s1",{"written":true,"total":2,"criticalHigh":1,"reason":""},{"die":true}]'
  [[ "$output" == *'"summary":"s1","died":false'* ]]
  [[ "$output" == *'"review":{"written":true,"total":2,"criticalHigh":1,"rounds":1,"reason":"revise agent was skipped or died — the round-1 findings stand unaddressed"}'* ]]
}

@test "a failed re-review after a revise fails open with rounds:1" {
  run_wf "$ARGS" \
    '["s1",{"written":true,"total":2,"criticalHigh":1,"reason":""},"s2",{"die":true},{"die":true}]'
  [[ "$output" == *'"summary":"s2","died":false'* ]]
  [[ "$output" == *'"review":{"written":false,"total":0,"criticalHigh":0,"rounds":1,"reason":"revise round ran; the re-review failed: review agent was skipped or died"}'* ]]
}
