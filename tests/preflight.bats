#!/usr/bin/env bats
# orca.sh preflight — gates, reviewer resolution, codex checks (stubbed CLI).

load helpers

# Run preflight with a controlled codex stub prepended to PATH.
preflight_with_codex() { # <version> <ok|denied> [legacy]
  make_codex_stub "$BATS_TEST_TMPDIR/stub" "$1" "$2" "${3:-modern}"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" preflight
}

# The stranded-install test (a preflight copied away from orca.sh
# failing typed NO_PLUGIN_ROOT) is gone with the fold: its failure
# condition is unreachable through the only remaining entry point —
# dispatch itself proves the dispatcher exists.
@test "the plugin-shipped CLI passes the PLUGIN_ROOT gate" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  preflight_with_codex "" denied
  [ "$status" -eq 0 ]
  has_line 'PLUGIN_ROOT: PASS'
}

@test "conventional checkout fails the bare gate" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  preflight_with_codex "" denied
  [ "$status" -eq 1 ]
  has_line 'BARE_REPO: FAIL'
  has_line 'RESULT: FAIL'
}

@test "bare layout with no usable codex detects claude and passes" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  preflight_with_codex "" denied
  [ "$status" -eq 0 ]
  has_line 'BARE_REPO: PASS'
  has_line 'TRUNK_CANDIDATE: main'
  has_line 'REVIEWER: claude (detected)'
  has_line 'CODEX: SKIPPED: reviewer is claude'
  has_line 'RESULT: PASS'
}

@test "a modern codex on PATH is detected as the reviewer" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .claude
  printf '{"env":{"BASH_MAX_TIMEOUT_MS":"1200000"}}\n' >.claude/settings.json
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 0 ]
  has_line 'REVIEWER: codex (detected)'
  has_line 'CODEX: PASS'
  has_line 'RESULT: PASS'
}

@test "an outdated codex is never silently used: detection falls to claude" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  preflight_with_codex 0.1.0 ok
  [ "$status" -eq 0 ]
  has_line 'REVIEWER: claude (detected)'
}

@test "pinned codex with an outdated binary fails loud, no silent downgrade" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  preflight_with_codex 0.1.0 ok
  [ "$status" -eq 1 ]
  has_line 'REVIEWER: codex (pinned)'
  has_line 'CODEX: FAIL'
  has_line 'RESULT: FAIL'
}

@test "pinned codex without auth fails the codex gate" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  preflight_with_codex 999.0.0 denied
  [ "$status" -eq 1 ]
  has_line 'CODEX: FAIL: not authenticated'
}

@test "pinned codex without BASH_MAX_TIMEOUT_MS fails the codex gate" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 1 ]
  has_line 'CODEX: FAIL: BASH_MAX_TIMEOUT_MS'
}

# A key that is present but too small is the silent version of the same
# failure: CODEX: PASS, and every review killed seconds in.
@test "a BASH_MAX_TIMEOUT_MS below the review budget fails the codex gate" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  mkdir -p .claude
  printf '{"env":{"BASH_MAX_TIMEOUT_MS":"1000"}}\n' >.claude/settings.json
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 1 ]
  has_line 'CODEX: FAIL: BASH_MAX_TIMEOUT_MS is 1000, below the 1200000'
}

# An unquoted number is just as valid in settings.json, and must pass.
@test "an unquoted BASH_MAX_TIMEOUT_MS at the budget passes" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  mkdir -p .claude
  printf '{"env":{"BASH_MAX_TIMEOUT_MS": 1200000}}\n' >.claude/settings.json
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 0 ]
  has_line 'CODEX: PASS'
}

# The 0.155.1 regression in miniature: a new, authenticated codex whose
# `codex exec` no longer carries the flags orca.sh codex drives. Version
# and auth pass; only asking the binary what it speaks catches it.
@test "a codex whose exec interface moved fails the codex gate" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  mkdir -p .claude
  printf '{"env":{"BASH_MAX_TIMEOUT_MS":"1200000"}}\n' >.claude/settings.json
  preflight_with_codex 999.0.0 ok legacy
  [ "$status" -eq 1 ]
  has_line 'CODEX: FAIL: codex 999.0.0 has no '"'"'codex exec'"'"' --output-schema, --output-last-message, --sandbox, --cd'
  has_line 'RESULT: FAIL'
}

@test "an invalid reviewer value fails loud, gate unresolvable" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=gemini\n' >.orca/config
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 1 ]
  has_line 'REVIEWER: FAIL'
  has_line 'CODEX: SKIPPED: reviewer unresolved'
}

@test "pinned reviewer is honored from a worktree subdirectory" {
  # finding 8.3: config paths resolve from CWD, so running anywhere but
  # the repo root silently downgrades a pinned reviewer to detection
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=claude\n' >"$BATS_TEST_TMPDIR/r/.orca/config"
  mkdir -p "$BATS_TEST_TMPDIR/r/main/src"
  cd "$BATS_TEST_TMPDIR/r/main/src"
  preflight_with_codex 999.0.0 ok
  has_line 'REVIEWER: claude (pinned)'
}

@test "a leftover config.json gets the informational OBSOLETE line, never a FAIL" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf '{"reviewer":"codex"}\n' >.orca/config.json
  preflight_with_codex "" denied
  [ "$status" -eq 0 ]
  has_line 'CONFIG: OBSOLETE: .orca/config.json is no longer read'
  # nothing parses it: the pinned-looking value does not pin
  has_line 'REVIEWER: claude (detected)'
  has_line 'RESULT: PASS'
}

@test "settings env blocks are found from a worktree subdirectory" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >"$BATS_TEST_TMPDIR/r/.orca/config"
  mkdir -p "$BATS_TEST_TMPDIR/r/.claude"
  printf '{"env":{"BASH_MAX_TIMEOUT_MS":"1200000"}}\n' >"$BATS_TEST_TMPDIR/r/.claude/settings.json"
  mkdir -p "$BATS_TEST_TMPDIR/r/main/src"
  cd "$BATS_TEST_TMPDIR/r/main/src"
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 0 ]
  has_line 'CODEX: PASS'
}
