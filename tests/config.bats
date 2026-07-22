#!/usr/bin/env bats
# config.sh — parse, validation, canonical writes, malformed-file handling.

load helpers

cfg() { bash "$SCRIPTS/config.sh" "$@"; }

@test "show with no config file reports absent plus defaults" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg show
  [ "$status" -eq 0 ]
  has_line $'REVIEWER:\tabsent'
  has_line $'EDITOR:\tabsent'
  has_line $'TERMINAL:\tabsent'
  has_line $'DEFAULT:\tspec'
}

@test "validate with no config file is VALID {}" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg validate
  [ "$status" -eq 0 ]
  has_line $'VALID:\t{}'
}

@test "set writes the canonical one-line shape" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg set reviewer=codex plan.model=sonnet plan.effort=high
  [ "$status" -eq 0 ]
  has_line $'REVIEWER:\tcodex\tpinned'
  has_line $'OVERRIDE:\tplan\tmodel\tsonnet'
  has_line $'OVERRIDE:\tplan\teffort\thigh'
  has_line 'WROTE:'
  [ "$(cat .orca/config.json)" = '{"reviewer":"codex","agents":{"plan":{"model":"sonnet","effort":"high"}}}' ]
}

@test "set rejects bad values with typed failures and writes nothing" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg set reviewer=gemini
  assert_fail_reason UNKNOWN_REVIEWER
  [ ! -e .orca/config.json ]
  run cfg set bogus.model=opus
  assert_fail_reason UNKNOWN_STAGE
  [ ! -e .orca/config.json ]
  run cfg set spec.effort=high
  assert_fail_reason SPEC_EFFORT
  [ ! -e .orca/config.json ]
}

@test "malformed JSON fails typed on show, validate, and set" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  echo '{not json' >.orca/config.json
  run cfg show
  assert_fail_reason PARSE_ERROR
  run cfg validate
  assert_fail_reason PARSE_ERROR
  run cfg set reviewer=codex
  assert_fail_reason PARSE_ERROR
  [ "$(cat .orca/config.json)" = '{not json' ]
}

@test "duplicate keys fail typed, never last-wins" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  printf '{"reviewer":"codex","reviewer":"claude"}\n' >.orca/config.json
  run cfg show
  assert_fail_reason DUPLICATE_KEY
}

@test "a pre-existing bad value fails a set that would preserve it" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  printf '{"reviewer":"gemini"}\n' >.orca/config.json
  run cfg set plan.model=sonnet
  assert_fail_reason UNKNOWN_REVIEWER
  [ "$(cat .orca/config.json)" = '{"reviewer":"gemini"}' ]
}

@test "value 'default' clears, and an empty result deletes the file" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg set plan.model=sonnet
  [ "$status" -eq 0 ]
  run cfg set plan.model=default
  [ "$status" -eq 0 ]
  has_line 'DELETED:'
  [ ! -e .orca/config.json ]
}

@test "full reset recovers an unparseable file without parsing it" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  echo 'garbage' >.orca/config.json
  run cfg reset
  [ "$status" -eq 0 ]
  has_line 'DELETED:'
  [ ! -e .orca/config.json ]
}

@test "reset <stage> clears only that stage" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  cfg set plan.model=sonnet implement.model=opus >/dev/null
  run cfg reset plan
  [ "$status" -eq 0 ]
  refute_line $'OVERRIDE:\tplan'
  has_line $'OVERRIDE:\timplement\tmodel\topus'
}

@test "writing in a conventional checkout excludes .orca/ from git" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg set reviewer=claude
  [ "$status" -eq 0 ]
  git check-ignore -q .orca/config.json
}
