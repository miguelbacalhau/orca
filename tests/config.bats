#!/usr/bin/env bats
# orca.sh config — flat-file parse, validation, canonical writes, recovery.

load helpers

cfg() { bash "$SCRIPTS/orca.sh" config "$@"; }

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

@test "an empty file (comments and blanks only) is a valid absent state" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  printf '# just a comment\n\n' >.orca/config
  run cfg show
  [ "$status" -eq 0 ]
  has_line $'REVIEWER:\tabsent'
  run cfg validate
  [ "$status" -eq 0 ]
  has_line $'VALID:\t{}'
}

@test "set writes the canonical flat shape in vocabulary order" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg set plan.effort=high reviewer=codex plan.model=sonnet
  [ "$status" -eq 0 ]
  has_line $'REVIEWER:\tcodex\tpinned'
  has_line $'OVERRIDE:\tplan\tmodel\tsonnet'
  has_line $'OVERRIDE:\tplan\teffort\thigh'
  has_line 'WROTE:'
  [ "$(cat .orca/config)" = 'reviewer=codex
agents.plan.model=sonnet
agents.plan.effort=high' ]
}

@test "canonical order survives a merge: stages in vocabulary order, model before effort" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  # a hand-written file in scrambled (but valid) order
  printf 'agents.implement.model=opus\nreviewer=codex\n' >.orca/config
  run cfg set plan.effort=high editor=nvim
  [ "$status" -eq 0 ]
  [ "$(cat .orca/config)" = 'reviewer=codex
editor=nvim
agents.plan.effort=high
agents.implement.model=opus' ]
}

@test "validate emits the launch block byte-compatible with the JSON wire format" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  cfg set reviewer=codex plan.model=sonnet plan.effort=high editor=nvim >/dev/null
  run cfg validate
  [ "$status" -eq 0 ]
  # editor/terminal are validated but excluded — orca:review preferences,
  # not launch args
  has_line $'VALID:\t{"reviewer":"codex","agents":{"plan":{"model":"sonnet","effort":"high"}}}'
}

@test "set rejects bad values with typed failures and writes nothing" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg set reviewer=gemini
  assert_fail_reason UNKNOWN_REVIEWER
  [ ! -e .orca/config ]
  run cfg set bogus.model=opus
  assert_fail_reason UNKNOWN_STAGE
  [ ! -e .orca/config ]
  run cfg set spec.effort=turbo
  assert_fail_reason UNKNOWN_EFFORT
  [ ! -e .orca/config ]
}

@test "spec.effort is an ordinary override: set, shown, cleared" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg set spec.effort=high
  [ "$status" -eq 0 ]
  has_line $'OVERRIDE:\tspec\teffort\thigh'
  run cfg show
  [ "$status" -eq 0 ]
  has_line $'OVERRIDE:\tspec\teffort\thigh'
  run cfg set spec.effort=default
  [ "$status" -eq 0 ]
  refute_line $'OVERRIDE:\tspec'
}

@test "a malformed line fails typed on show, validate, and set" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  printf 'reviewer = codex\n' >.orca/config
  run cfg show
  assert_fail_reason PARSE_ERROR
  run cfg validate
  assert_fail_reason PARSE_ERROR
  run cfg set reviewer=codex
  assert_fail_reason PARSE_ERROR
  [ "$(cat .orca/config)" = 'reviewer = codex' ]
}

@test "an unknown key in the file fails typed" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  printf 'flavour=vanilla\n' >.orca/config
  run cfg show
  assert_fail_reason UNKNOWN_KEY
  printf 'agents.plan.extra.model=opus\n' >.orca/config
  run cfg show
  assert_fail_reason UNKNOWN_KEY
}

@test "duplicate keys fail typed, never last-wins" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  printf 'reviewer=codex\nreviewer=claude\n' >.orca/config
  run cfg show
  assert_fail_reason DUPLICATE_KEY
}

@test "a value outside the vocabulary fails typed from the file" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  printf 'agents.plan.model=gemini\n' >.orca/config
  run cfg show
  assert_fail_reason UNKNOWN_MODEL
  printf 'terminal=screen\n' >.orca/config
  run cfg show
  assert_fail_reason UNKNOWN_TERMINAL
}

@test "a pre-existing bad value fails a set that would preserve it" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  printf 'reviewer=gemini\n' >.orca/config
  run cfg set plan.model=sonnet
  assert_fail_reason UNKNOWN_REVIEWER
  [ "$(cat .orca/config)" = 'reviewer=gemini' ]
}

@test "every bad assignment in a batch gets its own FAIL line" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg set reviewer=gemini plan.model=gpt
  assert_fail_reason UNKNOWN_REVIEWER
  has_line $'FAIL:\tUNKNOWN_MODEL'
  [ ! -e .orca/config ]
}

@test "writes are atomic: temp file renamed in, none left behind" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg set reviewer=codex
  [ "$status" -eq 0 ]
  [ "$(cat .orca/config)" = 'reviewer=codex' ]
  # no stray temp files from the write
  [ -z "$(find .orca -name '.config.*' -print -quit)" ]
  # the implementation must go through the temp-file + rename pattern
  grep -q 'mktemp' "$SCRIPTS/lib.sh"
}

@test "value 'default' clears, and an empty result deletes the file" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run cfg set plan.model=sonnet
  [ "$status" -eq 0 ]
  run cfg set plan.model=default
  [ "$status" -eq 0 ]
  has_line 'DELETED:'
  [ ! -e .orca/config ]
}

@test "clear removes bare fields" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  cfg set reviewer=codex plan.model=sonnet >/dev/null
  run cfg clear plan.model
  [ "$status" -eq 0 ]
  refute_line $'OVERRIDE:\tplan'
  has_line $'REVIEWER:\tcodex\tpinned'
  [ "$(cat .orca/config)" = 'reviewer=codex' ]
}

@test "full reset recovers an unparseable file without parsing it" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca
  echo 'garbage garbage' >.orca/config
  run cfg reset
  [ "$status" -eq 0 ]
  has_line 'DELETED:'
  [ ! -e .orca/config ]
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
  git check-ignore -q .orca/config
}
