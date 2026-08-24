#!/usr/bin/env bats
# statusline verb — the run board for a custom statusLine command.
# Fail-soft contract: exit 0 always; no active run prints nothing; a
# malformed run dir prints what parses. No git in the fixtures — the
# verb reads only the run directory and the lease.

load helpers

# make_run <project-root> <run-name> — a feature run dir with a spec
# carrying the Workflow args line for three items (W2 and W3 depend on
# W1), a merged W1, and status files for the rest.
make_run() {
  RUN="$1/.orca/$2"
  mkdir -p "$RUN/status" "$RUN/reviews"
  cat >"$RUN/spec.md" <<SPEC
# Spec

**Workflow run:** wf_test
**Workflow args:** {"runDir":"/x","slug":"demo","items":[{"id":"W1","title":"first","deps":[],"files":["a"]},{"id":"W2","title":"second","deps":["W1"],"files":["b"]},{"id":"W3","title":"third","deps":["W1","W2"],"files":["c"]}],"reviewer":"codex"}
SPEC
  printf 'W1\tsha\n' >"$RUN/merged.tsv"
  printf 'merged' >"$RUN/status/W1"
  printf 'implementing' >"$RUN/status/W2"
  printf 'pending' >"$RUN/status/W3"
}

# live_lock <run-dir> — a lease this test process provably owns.
live_lock() {
  mkdir -p "$1/.lock"
  {
    echo "host=$(hostname)"
    echo "pid=$$"
    echo "pidstart=$(ps -o lstart= -p $$)"
    echo "taken=2026-01-01T00:00:00Z"
  } >"$1/.lock/owner"
}

statusline() { # <project-dir> — run the verb as the harness would
  run bash -c "printf '{\"workspace\":{\"project_dir\":\"%s\"}}' '$1' | bash '$SCRIPTS/orca.sh' statusline"
}

@test "statusline: no .orca anywhere prints nothing, exit 0" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  statusline "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "statusline: run without a live lease (finished or unlaunched) prints nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.orca"
  make_run "$BATS_TEST_TMPDIR/proj" "20260101-000000-feat-demo"
  statusline "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "statusline: stale lease prints nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.orca"
  make_run "$BATS_TEST_TMPDIR/proj" "20260101-000000-feat-demo"
  live_lock "$RUN"
  sed_i_compat() { sed "s/^pidstart=.*/pidstart=NOT THE REAL START/" "$1/.lock/owner" >"$1/.lock/owner.new" && mv "$1/.lock/owner.new" "$1/.lock/owner"; }
  sed_i_compat "$RUN"
  statusline "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "statusline: active run renders header and per-item board" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.orca"
  make_run "$BATS_TEST_TMPDIR/proj" "20260101-000000-feat-demo"
  live_lock "$RUN"
  statusline "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  has_line "orca · demo · 1/3 merged"
  has_line "W1 ✓merged  W2 ▸implementing  W3 ⏸W2"
}

@test "statusline: found from a subdirectory of the project, walking up to .orca" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.orca" "$BATS_TEST_TMPDIR/proj/main/src"
  make_run "$BATS_TEST_TMPDIR/proj" "20260101-000000-feat-demo"
  live_lock "$RUN"
  statusline "$BATS_TEST_TMPDIR/proj/main/src"
  [ "$status" -eq 0 ]
  has_line "orca · demo · 1/3 merged"
}

@test "statusline: review round marker counts the reviews files" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.orca"
  make_run "$BATS_TEST_TMPDIR/proj" "20260101-000000-feat-demo"
  printf 'review' >"$RUN/status/W2"
  touch "$RUN/reviews/W2-codex.json" "$RUN/reviews/W2-codex.round0.json"
  live_lock "$RUN"
  statusline "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  has_line "W1 ✓merged  W2 ▸review#2  W3 ⏸W2"
}

@test "statusline: terminal words — cut, and blocked with its reason" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.orca"
  make_run "$BATS_TEST_TMPDIR/proj" "20260101-000000-feat-demo"
  printf 'cut' >"$RUN/status/W2"
  printf 'blocked — needs a user decision' >"$RUN/status/W3"
  live_lock "$RUN"
  statusline "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  has_line "W1 ✓merged  W2 ✗cut  W3 ✗blocked:needs a user decision"
}

@test "statusline: malformed run dir (no args line) renders from the status files" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.orca"
  make_run "$BATS_TEST_TMPDIR/proj" "20260101-000000-feat-demo"
  printf '# Spec with no args line\n' >"$RUN/spec.md"
  live_lock "$RUN"
  statusline "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  has_line "orca · demo · 1/3 merged"
  has_line "W1 ✓merged  W2 ▸implementing  W3 ·pending"
}

@test "statusline: merged.tsv outranks a stale status word" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.orca"
  make_run "$BATS_TEST_TMPDIR/proj" "20260101-000000-feat-demo"
  printf 'merging' >"$RUN/status/W1"
  live_lock "$RUN"
  statusline "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  has_line "W1 ✓merged"
}

@test "statusline: non-feature run shapes print nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.orca/20260101-000000-bug-crash"
  printf '# case\n' >"$BATS_TEST_TMPDIR/proj/.orca/20260101-000000-bug-crash/case.md"
  live_lock "$BATS_TEST_TMPDIR/proj/.orca/20260101-000000-bug-crash"
  statusline "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
