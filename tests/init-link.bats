#!/usr/bin/env bats
# orca.sh init-link — root symlinks for the worktree's agent context.

load helpers

# make_linked_fixture <dir> — bare layout whose main worktree carries
# .claude/ and CLAUDE.md.
make_linked_fixture() {
  make_bare_layout "$1"
  mkdir -p "$1/main/.claude/rules"
  echo 'rule' >"$1/main/.claude/rules/r.md"
  echo '# guide' >"$1/main/CLAUDE.md"
}

@test "check reports LINKABLE when sources exist and the root is empty" {
  make_linked_fixture "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPTS/orca.sh" init-link check
  [ "$status" -eq 0 ]
  has_line $'BRANCH:\tmain'
  has_line $'LINK:\t.claude\tLINKABLE\tmain/.claude'
  has_line $'LINK:\tCLAUDE.md\tLINKABLE\tmain/CLAUDE.md'
}

@test "apply creates relative links; a second apply skips as already linked" {
  make_linked_fixture "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPTS/orca.sh" init-link apply
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.claude\tmain/.claude'
  has_line $'LINKED:\tCLAUDE.md\tmain/CLAUDE.md'
  [ -L .claude ] && [ "$(readlink .claude)" = "main/.claude" ]
  [ -L CLAUDE.md ] && [ "$(readlink CLAUDE.md)" = "main/CLAUDE.md" ]
  [ -f .claude/rules/r.md ]
  run bash "$SCRIPTS/orca.sh" init-link apply
  [ "$status" -eq 0 ]
  has_line $'SKIPPED:\t.claude\talready linked'
  has_line $'SKIPPED:\tCLAUDE.md\talready linked'
}

@test "a real root entry is CONFLICT and never overwritten" {
  make_linked_fixture "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  echo 'mine' >CLAUDE.md
  run bash "$SCRIPTS/orca.sh" init-link check
  [ "$status" -eq 0 ]
  has_line $'LINK:\tCLAUDE.md\tCONFLICT'
  run bash "$SCRIPTS/orca.sh" init-link apply
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.claude'
  has_line $'SKIPPED:\tCLAUDE.md'
  [ ! -L CLAUDE.md ]
  [ "$(cat CLAUDE.md)" = "mine" ]
}

@test "a root link pointing elsewhere is CONFLICT and left alone" {
  make_linked_fixture "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p elsewhere
  ln -s elsewhere .claude
  run bash "$SCRIPTS/orca.sh" init-link apply
  [ "$status" -eq 0 ]
  has_line $'SKIPPED:\t.claude'
  [ "$(readlink .claude)" = "elsewhere" ]
}

@test "missing sources report NO_SOURCE" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPTS/orca.sh" init-link check
  [ "$status" -eq 0 ]
  has_line $'LINK:\t.claude\tNO_SOURCE'
  has_line $'LINK:\tCLAUDE.md\tNO_SOURCE'
  run bash "$SCRIPTS/orca.sh" init-link apply
  [ "$status" -eq 0 ]
  refute_line 'LINKED:'
}

@test "a conventional checkout fails typed NOT_BARE" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPTS/orca.sh" init-link check
  assert_fail_reason NOT_BARE
}

@test "a bad subcommand fails typed BAD_ARGS" {
  make_linked_fixture "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPTS/orca.sh" init-link frobnicate
  assert_fail_reason BAD_ARGS
}
