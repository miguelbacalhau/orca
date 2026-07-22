#!/usr/bin/env bats
# triage.sh — discovery line types and the status join's slug ambiguity.

load helpers

triage() { bash "$SCRIPTS/triage.sh" "$@"; }

@test "discover with no .orca is silent success" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run triage discover
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spec without a run record is unlaunched" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-1200-feat-alpha
  echo '# spec' >.orca/20250101-1200-feat-alpha/spec.md
  run triage discover
  [ "$status" -eq 0 ]
  has_line $'RUN:\t'"$PWD/.orca/20250101-1200-feat-alpha"$'\tunlaunched'
}

@test "interrupted run reports the LAST record's id and args" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-1200-feat-alpha
  cat >.orca/20250101-1200-feat-alpha/spec.md <<'EOF'
# spec

**Workflow run:** wf_old123
**Workflow args:** {"slug":"alpha","old":true}

**Workflow run:** wf_new456
**Workflow args:** {"slug":"alpha","new":true}
EOF
  run triage discover
  [ "$status" -eq 0 ]
  has_line $'RUN:\t'"$PWD/.orca/20250101-1200-feat-alpha"$'\tinterrupted'
  has_line $'RUNID:\twf_new456'
  has_line $'ARGS:\t{"slug":"alpha","new":true}'
  refute_line $'RUNID:\twf_old123'
}

@test "a record cut short reports absent, never an older launch's args" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-1200-feat-alpha
  cat >.orca/20250101-1200-feat-alpha/spec.md <<'EOF'
# spec

**Workflow run:** wf_old123
**Workflow args:** {"slug":"alpha","old":true}

**Workflow run:** wf_new456
EOF
  run triage discover
  [ "$status" -eq 0 ]
  has_line $'RUNID:\twf_new456'
  has_line $'ARGS:\tabsent'
}

@test "finished runs are DONE, routed by the report's Blocked section" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-a .orca/20250102-feat-b .orca/20250103-feat-c
  echo '# spec' >.orca/20250101-feat-a/spec.md
  echo '# spec' >.orca/20250102-feat-b/spec.md
  echo '# spec' >.orca/20250103-feat-c/spec.md
  printf '# report\n\n## Blocked\n\nNone\n' >.orca/20250101-feat-a/report.md
  printf '# report\n\n## Blocked\n\n- W3: died\n' >.orca/20250102-feat-b/report.md
  printf '# report\n\nno blocked section\n' >.orca/20250103-feat-c/report.md
  run triage discover
  [ "$status" -eq 0 ]
  has_line $'DONE:\t'"$PWD/.orca/20250101-feat-a"$'\tclean'
  has_line $'DONE:\t'"$PWD/.orca/20250102-feat-b"$'\tleftovers'
  has_line $'DONE:\t'"$PWD/.orca/20250103-feat-c"$'\tunknown'
}

@test "briefs surface from feat-briefs top level only" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/feat-briefs/drafts
  echo brief >.orca/feat-briefs/one.md
  echo draft >.orca/feat-briefs/drafts/two.md
  run triage discover
  [ "$status" -eq 0 ]
  has_line $'BRIEF:\t'"$PWD/.orca/feat-briefs/one.md"
  refute_line $'BRIEF:\t'"$PWD/.orca/feat-briefs/drafts/two.md"
}

@test "cases: ready when never launched or last run reported" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/bug-cases/crash .orca/20250101-bug-done
  echo case >.orca/bug-cases/crash/case.md
  run triage discover
  has_line $'CASE:\tcrash\tready'
  # launched, run dir has a report -> still ready
  cat >.orca/bug-cases/crash/case.md <<EOF
# case

**Workflow run:** wf_abc
**Workflow args:** {"runDir":"$PWD/.orca/20250101-bug-done"}
EOF
  echo report >.orca/20250101-bug-done/report.md
  run triage discover
  has_line $'CASE:\tcrash\tready'
}

@test "cases: interrupted when the last run dir lacks a report" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/bug-cases/crash .orca/20250101-bug-crash
  cat >.orca/bug-cases/crash/case.md <<EOF
# case

**Workflow run:** wf_abc
**Workflow args:** {"runDir":"$PWD/.orca/20250101-bug-crash"}
EOF
  run triage discover
  [ "$status" -eq 0 ]
  has_line $'CASE:\tcrash\tinterrupted'
  has_line $'RUNID:\twf_abc'
}

@test "status joins branches to run dirs without cross-slug bleed" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  git branch feature/alpha
  git branch feature/alpha-W1
  mkdir -p .orca/20250101-feat-alpha .orca/20250201-bug-alpha
  run triage status
  [ "$status" -eq 0 ]
  has_line $'TRUNK:\tmain'
  # the feat run dir wins; the bug dir with the same slug never joins
  has_line $'BRANCH:\tfeature/alpha\tmerged\tahead:0\t'"$PWD/.orca/20250101-feat-alpha"
  has_line $'ITEMBR:\tfeature/alpha-W1\tmerged\t'"$PWD/.orca/20250101-feat-alpha"
}

@test "status: a bare-suffix run dir joins only when no verb-marked dir exists" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  git branch feature/alpha
  mkdir -p .orca/20250101-alpha
  run triage status
  has_line $'BRANCH:\tfeature/alpha\tmerged\tahead:0\t'"$PWD/.orca/20250101-alpha"
  # a bug-marked dir carrying a longer slug that merely ends in -alpha
  # must not be claimed by the fallback
  rm -r .orca/20250101-alpha
  mkdir -p .orca/20250101-bug-x-alpha
  run triage status
  has_line $'BRANCH:\tfeature/alpha\tmerged\tahead:0\torphan'
}

@test "status reports unmerged branches with ahead counts" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  git checkout -qb feature/beta
  echo work >beta.txt
  git add beta.txt && git commit -qm work
  echo more >>beta.txt
  git add beta.txt && git commit -qm more
  git checkout -q main
  run triage status
  [ "$status" -eq 0 ]
  has_line $'BRANCH:\tfeature/beta\tunmerged\tahead:2\torphan'
}
