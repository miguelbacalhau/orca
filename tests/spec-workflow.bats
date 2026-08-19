#!/usr/bin/env bats
# spec.workflow.js — launch-time arg validation and the gated
# spec → review → revise sequence's return shape (one review, one final
# revise round, no re-review), run through the tests/run-workflow.js
# harness (host-style wrapping, stubbed agent()).

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

@test "rejects an empty or relative amendPath at launch" {
  run_wf '{"prompt":"p","runDir":"/run","reviewWorktree":"/wt","reviewer":"codex","amendPath":""}' '[]'
  [[ "$output" == *'args.amendPath must be a non-empty string'* ]]
  run_wf '{"prompt":"p","runDir":"/run","reviewWorktree":"/wt","reviewer":"codex","amendPath":"run/spec.amendment.md"}' '[]'
  [[ "$output" == *'args.amendPath must be an absolute path'* ]]
}

@test "amend round: spec-amend artifact name and the Amendment path line in the review message" {
  run_wf '{"prompt":"p","runDir":"/run","reviewWorktree":"/wt","reviewer":"codex","amendPath":"/run/spec.amendment.md"}' \
    '["s",'"$CLEAN"']'
  [[ "$output" == *'Amendment path: /run/spec.amendment.md'* ]]
  [[ "$output" == *'/run/reviews/spec-amend-codex.json'* ]]
  # the original run's spec-review artifact is never named
  [[ "$output" != *'/run/reviews/spec-codex.json'* ]]
}

@test "amend round: the revise prompt rewrites the amendment file, not spec.md" {
  run_wf '{"prompt":"p","runDir":"/run","reviewWorktree":"/wt","reviewer":"claude","amendPath":"/run/spec.amendment.md"}' \
    '["s1",{"written":true,"total":1,"criticalHigh":1,"reason":""},"s2"]'
  [[ "$output" == *'Rewrite /run/spec.amendment.md in place'* ]]
  [[ "$output" != *'Rewrite /run/spec.md in place'* ]]
}

@test "no amendPath: the fresh-spec path never mentions an amendment" {
  run_wf "$ARGS" '["s",'"$CLEAN"']'
  [[ "$output" != *'Amendment path:'* ]]
  [[ "$output" != *'spec-amend'* ]]
}

@test "a dead spec agent returns died:true with no review key" {
  run_wf "$ARGS" '[{"die":true}]'
  [[ "$output" == *'"result":{"summary":null,"died":true}'* ]]
}

@test "clean review: no revise, review shape on the return" {
  run_wf "$ARGS" '["spec summary",'"$CLEAN"']'
  [[ "$output" == *'"summary":"spec summary","died":false'* ]]
  [[ "$output" == *'"review":{"written":true,"total":0,"criticalHigh":0,"revised":false,"reason":""}'* ]]
  # exactly two agent calls: spec, then the codex spec reviewer with the
  # artifact path in its task message
  [ "$(grep -o '"agentType":"orca:spec-review-codex"' <<<"$output" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$output" != *'spec-revise'* ]]
  [[ "$output" == *'/run/reviews/spec-codex.json'* ]]
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

@test "Critical/High findings drive one revise spawn whose output is final — no re-review" {
  run_wf "$ARGS" \
    '["s1",{"written":true,"total":3,"criticalHigh":2,"reason":""},"s2"]'
  [[ "$output" == *'"summary":"s2","died":false'* ]]
  [[ "$output" == *'"review":{"written":true,"total":3,"criticalHigh":2,"revised":true,"reason":""}'* ]]
  # the revise spawn is an orca:spec re-spawn carrying the findings path,
  # and the one reviewer call is the only one — the revise output launches
  [[ "$output" == *'"label":"spec-revise","phase":"Revise"'* ]]
  [[ "$output" == *'REVISE ROUND'* ]]
  [[ "$output" == *'/run/reviews/spec-codex.json'* ]]
  [ "$(grep -o '"agentType":"orca:spec-review-codex"' <<<"$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "fail open: a dead then written:false reviewer returns written:false with the reason" {
  run_wf "$ARGS" '["s",{"die":true},{"written":false,"total":0,"criticalHigh":0,"reason":"boom"}]'
  [[ "$output" == *'"summary":"s","died":false'* ]]
  [[ "$output" == *'"review":{"written":false,"total":0,"criticalHigh":0,"revised":false,"reason":"boom"}'* ]]
  [[ "$output" == *'spec-review~retry'* ]]
}

@test "an impossible count (criticalHigh > total) is retried like written:false" {
  run_wf "$ARGS" \
    '["s",{"written":true,"total":0,"criticalHigh":2,"reason":""},'"$CLEAN"']'
  [[ "$output" == *'"review":{"written":true,"total":0,"criticalHigh":0,"revised":false,"reason":""}'* ]]
  [[ "$output" == *'spec-review~retry'* ]]
}

@test "a dead revise spawn leaves the findings standing (written, revised:false)" {
  run_wf "$ARGS" \
    '["s1",{"written":true,"total":2,"criticalHigh":1,"reason":""},{"die":true}]'
  [[ "$output" == *'"summary":"s1","died":false'* ]]
  [[ "$output" == *'"review":{"written":true,"total":2,"criticalHigh":1,"revised":false,"reason":"revise agent was skipped or died — the findings stand unaddressed"}'* ]]
}
