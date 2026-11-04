#!/usr/bin/env bats
# orca.sh review — deliverable discovery, review-notes counting, key sanitization.

load helpers

# A bare layout with a deliverable: feature/foo checked out at orca-foo,
# one commit ahead of main.
make_deliverable() { # <dir>
  make_bare_layout "$1"
  ( cd "$1" &&
    git -C main worktree add ../orca-foo -b feature/foo >/dev/null 2>&1 &&
    echo work >orca-foo/foo.txt &&
    git -C orca-foo add foo.txt &&
    git -C orca-foo commit -qm "feat: foo" )
}

@test "discover on a fresh layout lists the trunk and nothing else" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r/main"
  run bash "$SCRIPTS/orca.sh" review discover
  [ "$status" -eq 0 ]
  has_line $'TRUNK:\tmain'
  refute_line 'DELIVERABLE:'
}

@test "discover fails typed outside the bare layout" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPTS/orca.sh" review discover
  assert_fail_reason NOT_BARE
}

@test "an unmerged branch with a worktree is a deliverable, ok" {
  make_deliverable "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r/main"
  run bash "$SCRIPTS/orca.sh" review discover
  [ "$status" -eq 0 ]
  has_line $'DELIVERABLE:\tfeature/foo\t'"$BATS_TEST_TMPDIR/r/orca-foo"$'\tok'
}

@test "an unmerged branch without a worktree is missing, path derived" {
  make_deliverable "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  git -C main worktree remove --force ../orca-foo
  cd main
  run bash "$SCRIPTS/orca.sh" review discover
  [ "$status" -eq 0 ]
  has_line $'DELIVERABLE:\tfeature/foo\t'"$BATS_TEST_TMPDIR/r/orca-foo"$'\tmissing'
}

@test "item branches (-W<n>) are not deliverables" {
  make_deliverable "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r/main"
  git branch feature/foo-W1 feature/foo
  run bash "$SCRIPTS/orca.sh" review discover
  [ "$status" -eq 0 ]
  refute_line $'DELIVERABLE:\tfeature/foo-W1'
}

@test "notes counts comments by status, key sanitized from the branch" {
  make_deliverable "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r/main"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/review-notes"
  # feature/foo sanitizes to feature-foo — '/' is outside [A-Za-z0-9._-]
  printf '{"version":1,"comments":[{"status":"open"},{"status":"open"},{"status":"addressed"}]}\n' \
    >"$BATS_TEST_TMPDIR/r/.orca/review-notes/feature-foo.json"
  run bash "$SCRIPTS/orca.sh" review notes "$BATS_TEST_TMPDIR/r/orca-foo"
  [ "$status" -eq 0 ]
  has_line $'NOTES:\t'"$BATS_TEST_TMPDIR/r/.orca/review-notes/feature-foo.json"$'\t2,1,0'
}

@test "notes with no file is NOTES_NONE" {
  make_deliverable "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r/main"
  run bash "$SCRIPTS/orca.sh" review notes "$BATS_TEST_TMPDIR/r/orca-foo"
  [ "$status" -eq 0 ]
  has_line 'NOTES_NONE:'
}

@test "an unspoken notes version refuses to count" {
  make_deliverable "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r/main"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/review-notes"
  printf '{"version":2,"comments":[{"status":"open"}]}\n' \
    >"$BATS_TEST_TMPDIR/r/.orca/review-notes/feature-foo.json"
  run bash "$SCRIPTS/orca.sh" review notes "$BATS_TEST_TMPDIR/r/orca-foo"
  [ "$status" -eq 1 ]
  has_line $'NOTES_VERSION:\t2\t1'
}

@test "discover surfaces open comments beside their deliverable" {
  make_deliverable "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r/main"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/review-notes"
  printf '{"version":1,"comments":[{"status":"open"}]}\n' \
    >"$BATS_TEST_TMPDIR/r/.orca/review-notes/feature-foo.json"
  run bash "$SCRIPTS/orca.sh" review discover
  [ "$status" -eq 0 ]
  has_line $'NOTES:\t'"$BATS_TEST_TMPDIR/r/.orca/review-notes/feature-foo.json"$'\t1,0,0'
}

@test "discover suppresses notes with zero open comments" {
  make_deliverable "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r/main"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/review-notes"
  printf '{"version":1,"comments":[{"status":"answered"}]}\n' \
    >"$BATS_TEST_TMPDIR/r/.orca/review-notes/feature-foo.json"
  run bash "$SCRIPTS/orca.sh" review discover
  [ "$status" -eq 0 ]
  refute_line 'NOTES:'
}

@test "comment text cannot forge status counts" {
  make_deliverable "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r/main"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/review-notes"
  # inside a JSON string every quote is \" — the raw bytes "status":"open"
  # cannot appear in a body the sole writer (vim.json.encode) produced
  printf '{"version":1,"comments":[{"status":"answered","body":"try \\"status\\":\\"open\\" here"}]}\n' \
    >"$BATS_TEST_TMPDIR/r/.orca/review-notes/feature-foo.json"
  run bash "$SCRIPTS/orca.sh" review notes "$BATS_TEST_TMPDIR/r/orca-foo"
  [ "$status" -eq 0 ]
  has_line $'NOTES:\t'"$BATS_TEST_TMPDIR/r/.orca/review-notes/feature-foo.json"$'\t0,0,1'
}

# report_for <dir> <branch> — a report.md in <dir> naming <branch> its deliverable.
report_for() {
  mkdir -p "$1"
  printf '# Report: x\n\n**Deliverable:** `%s`\n**Deliverable state:** verified\n' "$2" >"$1/report.md"
}

@test "discover names the report behind a deliverable: a run's, or an objective's first" {
  make_deliverable "$BATS_TEST_TMPDIR/r"
  local orca="$BATS_TEST_TMPDIR/r/.orca"
  cd "$BATS_TEST_TMPDIR/r/main"
  run bash "$SCRIPTS/orca.sh" review discover
  [ "$status" -eq 0 ]
  refute_line 'REPORT:'
  report_for "$orca/20250101-1200-feat-foo" feature/foo
  report_for "$orca/20250101-1200-feat-bar" feature/bar
  run bash "$SCRIPTS/orca.sh" review discover
  [ "$status" -eq 0 ]
  has_line $'REPORT:\t'"$orca/20250101-1200-feat-foo/report.md"$'\trun'
  report_for "$orca/objectives/20261103-120000-foo" feature/foo
  run bash "$SCRIPTS/orca.sh" review discover
  [ "$status" -eq 0 ]
  has_line $'REPORT:\t'"$orca/objectives/20261103-120000-foo/report.md"$'\tobjective'
  [ "$(printf '%s\n' "$output" | grep -c '^REPORT:')" -eq 1 ]
  # REPORT: follows its DELIVERABLE: line
  [ "$(printf '%s\n' "$output" | grep -A1 '^DELIVERABLE:' | sed -n 2p | cut -f1)" = REPORT: ]
  # an archived objective's report no longer speaks for the branch
  printf 'state=abandoned\n' >"$orca/objectives/20261103-120000-foo/archived"
  run bash "$SCRIPTS/orca.sh" review discover
  has_line $'REPORT:\t'"$orca/20250101-1200-feat-foo/report.md"$'\trun'
}

@test "discover: a report naming another branch, or the slug only in prose, is not the deliverable's" {
  make_deliverable "$BATS_TEST_TMPDIR/r"
  local orca="$BATS_TEST_TMPDIR/r/.orca"
  cd "$BATS_TEST_TMPDIR/r/main"
  report_for "$orca/objectives/20261103-120000-foobar" feature/foobar
  mkdir -p "$orca/objectives/20261103-130000-other"
  printf '# Report\n\nworks on `feature/foo` too\n' >"$orca/objectives/20261103-130000-other/report.md"
  run bash "$SCRIPTS/orca.sh" review discover
  [ "$status" -eq 0 ]
  refute_line 'REPORT:'
}
