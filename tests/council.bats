#!/usr/bin/env bats
# orca:council — the resolve verb (who sits, against a stubbed codex CLI)
# and council.workflow.js (arg validation, identical prompts, per-seat
# outcomes) through the tests/run-workflow.js harness.

load helpers

resolve() { bash "$SCRIPTS/orca.sh" council resolve; }

# resolve_with_codex <version> <ok|denied> [legacy] — run resolve with a
# controlled codex stub first on PATH (an empty version models a binary
# that reports none: present but unusable).
resolve_with_codex() {
  make_codex_stub "$BATS_TEST_TMPDIR/stub" "$1" "$2" "${3:-modern}"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run resolve
}

# resolve_without_codex — no codex anywhere on PATH.
resolve_without_codex() {
  mkdir -p "$BATS_TEST_TMPDIR/empty-bin"
  PATH="$BATS_TEST_TMPDIR/envelope-bin:$BATS_TEST_TMPDIR/empty-bin:/usr/bin:/bin" run resolve
}

# ---- resolve ------------------------------------------------------------

@test "the default council seats opus, fable, and astra when codex is usable" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  resolve_with_codex 999.0.0 ok
  [ "$status" -eq 0 ]
  has_line $'ROOT:\t'"$BATS_TEST_TMPDIR/r"
  has_line $'SOURCE:\tdefault'
  has_line $'MEMBER:\t1\topus\tclaude\topus'
  has_line $'MEMBER:\t2\tfable\tclaude\tfable'
  has_line $'MEMBER:\t3\tastra\tcodex\tgpt-6-astra'
  refute_line 'DROPPED:'
  has_line $'SCRATCH:\t/'
  scratch="$(printf '%s\n' "$output" | sed -n 's/^SCRATCH:\t//p')"
  [ -d "$scratch" ]
  rm -rf "$scratch"
}

@test "the default council drops astra when codex is missing, and needs no scratch" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  resolve_without_codex
  [ "$status" -eq 0 ]
  has_line $'MEMBER:\t1\topus'
  has_line $'MEMBER:\t2\tfable'
  has_line $'DROPPED:\t3\tastra\tcodex not on PATH'
  refute_line $'MEMBER:\t3'
  refute_line 'SCRATCH:'
}

@test "the default council drops astra when codex is too old" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  resolve_with_codex 0.1.0 ok
  [ "$status" -eq 0 ]
  has_line $'DROPPED:\t3\tastra\tcodex 0.1.0 < required'
}

@test "a pinned astra seat with no codex fails NO_CODEX, seating nobody" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  printf 'council=opus,astra\n' >.orca/config
  resolve_without_codex
  assert_fail_reason NO_CODEX
  refute_line 'MEMBER:'
}

@test "a pinned council follows its order, repeats included, and never probes codex without astra" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  printf 'council=sonnet,opus,sonnet\n' >.orca/config
  # An unauthenticated codex would fail any council that seats it.
  resolve_with_codex 999.0.0 denied
  [ "$status" -eq 0 ]
  has_line $'SOURCE:\tpinned'
  has_line $'MEMBER:\t1\tsonnet\tclaude\tsonnet'
  has_line $'MEMBER:\t2\topus\tclaude\topus'
  has_line $'MEMBER:\t3\tsonnet\tclaude\tsonnet'
  refute_line 'SCRATCH:'
}

@test "an installed but broken codex is CODEX_UNUSABLE, never a silent drop" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  resolve_with_codex 999.0.0 denied
  assert_fail_reason CODEX_UNUSABLE
  [[ "$output" == *"codex login"* ]]
  resolve_with_codex 999.0.0 ok legacy
  assert_fail_reason CODEX_UNUSABLE
  [[ "$output" == *"--model"* ]]
}

@test "ROOT is the worktree the session stands in" {
  make_bare_layout "$BATS_TEST_TMPDIR/b"
  mkdir -p "$BATS_TEST_TMPDIR/b/main/sub"
  cd "$BATS_TEST_TMPDIR/b/main/sub"
  resolve_without_codex
  [ "$status" -eq 0 ]
  [[ "$output" == *$'ROOT:\t'"$BATS_TEST_TMPDIR/b/main"$'\n'* ]]
}

@test "the council reads the bare layout's config beside the bare repo" {
  make_bare_layout "$BATS_TEST_TMPDIR/b"
  printf 'council=haiku,fable\n' >"$BATS_TEST_TMPDIR/b/.orca/config"
  cd "$BATS_TEST_TMPDIR/b/main"
  resolve_without_codex
  [ "$status" -eq 0 ]
  has_line $'SOURCE:\tpinned'
  has_line $'MEMBER:\t1\thaiku'
}

@test "a mangled config and misuse fail typed" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  printf 'council=opus\n' >.orca/config
  resolve_without_codex
  assert_fail_reason BAD_COUNCIL
  run bash "$SCRIPTS/orca.sh" council
  assert_fail_reason BAD_ARGS
  run bash "$SCRIPTS/orca.sh" council resolve extra
  assert_fail_reason BAD_ARGS
  cd "$BATS_TEST_TMPDIR"
  run resolve
  assert_fail_reason NOT_GIT
}

# ---- council.workflow.js ------------------------------------------------

run_wf() { # <args-json> <responses-json>
  command -v node >/dev/null || skip "node not available"
  run node "$ORCA_ROOT/tests/run-workflow.js" "$SCRIPTS/council.workflow.js" "$1" "$2"
}

SEATS='[{"seat":1,"name":"opus","kind":"claude","model":"opus"},{"seat":2,"name":"fable","kind":"claude","model":"fable"},{"seat":3,"name":"astra","kind":"codex","model":"gpt-6-astra"}]'
ARGS='{"prompt":"Why is X slow?","root":"/repo","members":'"$SEATS"',"pluginRoot":"/plug","scratch":"/tmp/s"}'
ANSWER='{"summary":"s","claims":[],"open_questions":[]}'
LANDED='{"written":true,"status":"ok","reason":""}'

@test "every seat sits in parallel with the same prompt; codex is reached through its courier" {
  run_wf "$ARGS" '['"$ANSWER"','"$ANSWER"','"$LANDED"']'
  [[ "$output" == *'"ok":true'* ]]
  run node -e '
    const r = JSON.parse(process.argv[1])
    const [a, b, c] = r.calls
    const ok = r.calls.length === 3
      && a.prompt === b.prompt && a.prompt.includes("Why is X slow?") && a.prompt.includes("Repository root: /repo")
      && a.opts.agentType === "orca:council" && a.opts.model === "opus" && b.opts.model === "fable"
      && a.opts.schema && c.opts.agentType === "orca:council-codex" && c.opts.model === undefined
      && c.prompt.includes("<<<ORCA-COUNCIL-PROMPT\n" + a.prompt + "\nORCA-COUNCIL-PROMPT>>>")
      && c.prompt.includes("Codex model: gpt-6-astra") && c.prompt.includes("Plugin root: /plug")
      && c.prompt.includes("Artifact path: /tmp/s/seat-3.json")
      && r.result.members.map(m => m.status).join() === "ok,ok,ok"
      && r.result.members[0].result.summary === "s"
      && r.result.members[2].artifact === "/tmp/s/seat-3.json"
    console.log(ok ? "PASS" : JSON.stringify(r, null, 1))
  ' "$output"
  [ "$output" = PASS ]
}

@test "no brief means no context block in the prompt" {
  run_wf "$ARGS" '['"$ANSWER"','"$ANSWER"','"$LANDED"']'
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" != *'<<<CONTEXT'* ]]
  [[ "$output" != *'Context from the convening session'* ]]
}

@test "a brief reaches every seat after the question, labelled as the session's words" {
  args='{"prompt":"Is the retry ordering sound?","brief":"Session concluded: retries run in seat order (scripts/x.js:10).","root":"/repo","members":'"$SEATS"',"pluginRoot":"/plug","scratch":"/tmp/s"}'
  run_wf "$args" '['"$ANSWER"','"$ANSWER"','"$LANDED"']'
  [[ "$output" == *'"ok":true'* ]]
  run node -e '
    const r = JSON.parse(process.argv[1])
    const [a, b, c] = r.calls
    const q = a.prompt.indexOf("Is the retry ordering sound?")
    const ctx = a.prompt.indexOf("<<<CONTEXT\nSession concluded: retries run in seat order (scripts/x.js:10).\nCONTEXT>>>")
    const ok = a.prompt === b.prompt && q >= 0 && ctx > q
      && a.prompt.includes("not the user\u0027s own words")
      && c.prompt.includes("<<<ORCA-COUNCIL-PROMPT\n" + a.prompt + "\nORCA-COUNCIL-PROMPT>>>")
    console.log(ok ? "PASS" : JSON.stringify(r, null, 1))
  ' "$output"
  [ "$output" = PASS ]
}

@test "a dead seat and a failed courier are reported, never fatal" {
  run_wf "$ARGS" '[{"die":true},'"$ANSWER"',{"written":false,"status":"timeout","reason":"codex hit the 540s cap"}]'
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"seat":1,"name":"opus","kind":"claude","model":"opus","status":"died"'* ]]
  [[ "$output" == *'"status":"failed","reason":"codex hit the 540s cap"'* ]]
}

@test "a claude-only council needs neither pluginRoot nor scratch" {
  run_wf '{"prompt":"q","root":"/repo","members":[{"seat":1,"name":"opus","kind":"claude","model":"opus"},{"seat":2,"name":"opus","kind":"claude","model":"opus"}]}' \
    '['"$ANSWER"','"$ANSWER"']'
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"label":"seat-1:opus"'* ]]
  [[ "$output" == *'"label":"seat-2:opus"'* ]]
}

@test "launch validation rejects malformed args before any seat sits" {
  run_wf '{"root":"/repo","members":'"$SEATS"',"pluginRoot":"/plug","scratch":"/tmp/s"}' '[]'
  [[ "$output" == *'args.prompt must be a non-empty string'* ]]
  [[ "$output" == *'"calls":[]'* ]]
  run_wf '{"prompt":"q","brief":"  ","root":"/repo","members":'"$SEATS"',"pluginRoot":"/plug","scratch":"/tmp/s"}' '[]'
  [[ "$output" == *'args.brief, when given, must be a non-empty string'* ]]
  [[ "$output" == *'"calls":[]'* ]]
  run_wf '{"prompt":"q","root":"repo","members":'"$SEATS"',"pluginRoot":"/plug","scratch":"/tmp/s"}' '[]'
  [[ "$output" == *'args.root must be an absolute path'* ]]
  run_wf '{"prompt":"q","root":"/repo","members":[{"seat":1,"name":"opus","kind":"claude","model":"opus"}]}' '[]'
  [[ "$output" == *'args.members must be an array of 2 to 5 seats'* ]]
  run_wf '{"prompt":"q","root":"/repo","members":[{"seat":1,"name":"gpt","kind":"claude","model":"gpt"},{"seat":2,"name":"opus","kind":"claude","model":"opus"}]}' '[]'
  [[ "$output" == *"a claude seat's model must be one of haiku, sonnet, opus, fable"* ]]
  run_wf '{"prompt":"q","root":"/repo","members":[{"seat":1,"name":"x","kind":"gemini","model":"x"},{"seat":2,"name":"opus","kind":"claude","model":"opus"}]}' '[]'
  [[ "$output" == *'kind must be \"claude\" or \"codex\"'* ]]
  run_wf '{"prompt":"q","root":"/repo","members":[{"seat":1,"name":"opus","kind":"claude","model":"opus"},{"seat":1,"name":"opus","kind":"claude","model":"opus"}]}' '[]'
  [[ "$output" == *'seat 1 appears twice'* ]]
  run_wf '{"prompt":"q","root":"/repo","members":'"$SEATS"',"scratch":"/tmp/s"}' '[]'
  [[ "$output" == *'NO_PLUGIN_ROOT'* ]]
  run_wf '{"prompt":"q","root":"/repo","members":'"$SEATS"',"pluginRoot":"/plug"}' '[]'
  [[ "$output" == *'args.scratch must be an absolute path'* ]]
}
