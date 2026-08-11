#!/usr/bin/env bats
# orca.sh triage — discovery line types and the status join's slug ambiguity.

load helpers

triage() { bash "$SCRIPTS/orca.sh" triage "$@"; }

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

@test "a run dir with only brief.md is discovered as unlaunched" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-1200-feat-alpha .orca/feat-briefs
  echo '# brief' >.orca/20250101-1200-feat-alpha/brief.md
  # a queued brief that happens to be named brief.md is NOT a run dir
  echo '# queued' >.orca/feat-briefs/brief.md
  run triage discover
  [ "$status" -eq 0 ]
  has_line $'RUN:\t'"$PWD/.orca/20250101-1200-feat-alpha"$'\tunlaunched'
  refute_line $'RUN:\t'"$PWD/.orca/feat-briefs"
  has_line $'BRIEF:\t'"$PWD/.orca/feat-briefs/brief.md"
}

@test "prototype run dirs are invisible to discovery and actions" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-1200-proto-x .orca/20250102-1300-proto-y .orca/20250103-1400-feat-alpha
  echo '# brief' >.orca/20250101-1200-proto-x/brief.md
  # a finished prototype: brief plus report — still nothing to route
  echo '# brief' >.orca/20250102-1300-proto-y/brief.md
  echo '# report' >.orca/20250102-1300-proto-y/report.md
  # backstop: even a spec.md in a proto dir stays invisible
  echo '# spec' >.orca/20250102-1300-proto-y/spec.md
  # a sibling feature fixture still surfaces
  echo '# brief' >.orca/20250103-1400-feat-alpha/brief.md
  run triage snapshot
  [ "$status" -eq 0 ]
  [[ "$output" != *proto-* ]]
  has_line $'RUN:\t'"$PWD/.orca/20250103-1400-feat-alpha"$'\tunlaunched'
  has_line $'ACTION:\t1\trun-brief\tfeature\t'"$PWD/.orca/20250103-1400-feat-alpha"$'\t'
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

@test "status: slug alpha never claims slug x-alpha's run dir" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  git branch feature/alpha
  mkdir -p .orca/20250101-1200-feat-x-alpha
  run triage status
  [ "$status" -eq 0 ]
  has_line $'BRANCH:\tfeature/alpha\tmerged\tahead:0\torphan'
}

@test "a run record with an empty runId reports absent" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-1200-feat-alpha
  printf '# spec\n\n**Workflow run:**\n' >.orca/20250101-1200-feat-alpha/spec.md
  run triage discover
  [ "$status" -eq 0 ]
  has_line $'RUNID:\tabsent'
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

# ---- lease: claim/release and the LEASE: reader ----

# write_owner <run-dir> <host> <pid> <pidstart> — a hand-built lock whose
# liveness the test controls; only the claim verb may write REAL owners.
write_owner() {
  mkdir -p "$1/.lock"
  {
    printf 'runid=\n'
    printf 'host=%s\n' "$2"
    printf 'pid=%s\n' "$3"
    printf 'pidstart=%s\n' "$4"
    printf 'note=test fixture\n'
    printf 'taken=2026-01-01T00:00:00+0000\n'
  } >"$1/.lock/owner"
}

@test "claim takes the lease with machine-readable owner fields; a second claim refuses; release frees it" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-1200-feat-alpha
  run triage claim --runid wf_abc .orca/20250101-1200-feat-alpha 'orca test; slug=alpha'
  [ "$status" -eq 0 ]
  has_line $'CLAIMED:\t.orca/20250101-1200-feat-alpha\tpid:'
  local owner=.orca/20250101-1200-feat-alpha/.lock/owner
  grep -q '^runid=wf_abc$' "$owner"
  grep -q "^host=$(hostname)$" "$owner"
  grep -qE '^pid=[0-9]+$' "$owner"
  grep -q '^pidstart=' "$owner"
  grep -q '^note=orca test; slug=alpha$' "$owner"
  grep -q '^taken=' "$owner"
  # the recorded pid is a walked non-shell ancestor, alive by construction
  local pid
  pid="$(sed -n 's/^pid=//p' "$owner")"
  kill -0 "$pid"
  case "$(ps -o comm= -p "$pid")" in
    sh | bash | zsh | dash | */sh | */bash | */zsh | */dash) false ;;
  esac
  run triage claim .orca/20250101-1200-feat-alpha 'second writer'
  assert_fail_reason LEASE_HELD
  run triage release .orca/20250101-1200-feat-alpha
  [ "$status" -eq 0 ]
  has_line $'RELEASED:\t'
  [ ! -e .orca/20250101-1200-feat-alpha/.lock ]
  run triage claim .orca/20250101-1200-feat-alpha 'after release'
  [ "$status" -eq 0 ]
}

@test "claim refuses a missing run dir typed" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run triage claim .orca/does-not-exist 'note'
  assert_fail_reason NO_RUN_DIR
}

@test "discover reads the lease: none, live, stale, unknown" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-none .orca/20250102-feat-live .orca/20250103-feat-stale .orca/20250104-feat-other
  echo '# spec' >.orca/20250101-feat-none/spec.md
  echo '# spec' >.orca/20250102-feat-live/spec.md
  echo '# spec' >.orca/20250103-feat-stale/spec.md
  echo '# spec' >.orca/20250104-feat-other/spec.md
  # live: a real process whose start time matches verbatim
  sleep 60 &
  local spid=$!
  write_owner .orca/20250102-feat-live "$(hostname)" "$spid" "$(ps -o lstart= -p "$spid")"
  # stale: a live pid whose recorded start time does not match (pid reuse shape)
  write_owner .orca/20250103-feat-stale "$(hostname)" "$$" "not the real lstart"
  # unknown: another host
  write_owner .orca/20250104-feat-other "elsewhere.invalid" "$$" "whatever"
  run triage discover
  kill "$spid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  has_line $'LEASE:\tnone'
  has_line $'LEASE:\tlive\tpid:'"$spid"$'\tsince:2026-01-01T00:00:00+0000'
  has_line $'LEASE:\tstale\tpid:'"$$"
  has_line $'LEASE:\tunknown\tpid:'"$$"
}

@test "a dead pid reads stale; a pre-verb prose owner reads unknown" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-dead .orca/20250102-feat-prose
  echo '# spec' >.orca/20250101-feat-dead/spec.md
  echo '# spec' >.orca/20250102-feat-prose/spec.md
  sleep 0.01 &
  local dpid=$!
  wait "$dpid"
  write_owner .orca/20250101-feat-dead "$(hostname)" "$dpid" "long gone"
  mkdir -p .orca/20250102-feat-prose/.lock
  printf 'orca work loop; slug=prose\n2026-01-01\n' >.orca/20250102-feat-prose/.lock/owner
  run triage discover
  [ "$status" -eq 0 ]
  has_line $'LEASE:\tstale\tpid:'"$dpid"
  has_line $'LEASE:\tunknown\tpid:-'
}

@test "a DONE run carrying a stranded lock gets its LEASE line" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-a
  echo '# spec' >.orca/20250101-feat-a/spec.md
  printf '# report\n\n## Blocked\n\nNone\n' >.orca/20250101-feat-a/report.md
  sleep 0.01 &
  local dpid=$!
  wait "$dpid"
  write_owner .orca/20250101-feat-a "$(hostname)" "$dpid" "gone"
  run triage discover
  [ "$status" -eq 0 ]
  has_line $'DONE:\t'"$PWD/.orca/20250101-feat-a"$'\tclean'
  has_line $'LEASE:\tstale\tpid:'"$dpid"
}

@test "steal: takes a stale lease atomically, refuses a live one" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-alpha
  sleep 0.01 &
  local dpid=$!
  wait "$dpid"
  write_owner .orca/20250101-feat-alpha "$(hostname)" "$dpid" "gone"
  run triage claim --steal --runid wf_new .orca/20250101-feat-alpha 'resume claim'
  [ "$status" -eq 0 ]
  has_line $'CLAIMED:\t'
  grep -q '^runid=wf_new$' .orca/20250101-feat-alpha/.lock/owner
  # the renamed remnant survives until release removes it
  ls .orca/20250101-feat-alpha/.lock.stale.* >/dev/null
  # the fresh lease reads live, so a second (losing) contender's steal refuses
  run triage claim --steal .orca/20250101-feat-alpha 'second contender'
  assert_fail_reason NOT_STALE
  run triage release .orca/20250101-feat-alpha
  [ "$status" -eq 0 ]
  [ ! -e .orca/20250101-feat-alpha/.lock ]
  run bash -c 'ls .orca/20250101-feat-alpha/.lock.stale.* 2>/dev/null'
  [ -z "$output" ]
}

# ---- report enrichment: BLOCKED:/FOLLOWUP: ----

@test "DONE runs carry base64 Blocked and Follow-ups sections; missing sections emit no line" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-a .orca/20250102-feat-b
  echo '# spec' >.orca/20250101-feat-a/spec.md
  echo '# spec' >.orca/20250102-feat-b/spec.md
  printf '# report\n\n## Blocked\n\n- W3: died waiting on a decision\n\n## Follow-ups\n\n- polish the docs\n' \
    >.orca/20250101-feat-a/report.md
  printf '# report\n\nno sections at all\n' >.orca/20250102-feat-b/report.md
  run triage discover
  [ "$status" -eq 0 ]
  has_line $'BLOCKED:\t'"$PWD/.orca/20250101-feat-a"$'\t'
  has_line $'FOLLOWUP:\t'"$PWD/.orca/20250101-feat-a"$'\t'
  refute_line $'BLOCKED:\t'"$PWD/.orca/20250102-feat-b"
  refute_line $'FOLLOWUP:\t'"$PWD/.orca/20250102-feat-b"
  # the payload decodes to the section body, verbatim — never paraphrased
  local payload
  payload="$(printf '%s\n' "$output" | grep '^BLOCKED:' | cut -f3 | base64 --decode)"
  [[ "$payload" == *"W3: died waiting on a decision"* ]]
  payload="$(printf '%s\n' "$output" | grep '^FOLLOWUP:' | cut -f3 | base64 --decode)"
  [[ "$payload" == *"polish the docs"* ]]
}

# ---- snapshot: combined facts, fragment match, action list ----

@test "snapshot combines discover and status and ranks the actions" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-alpha .orca/20250102-feat-beta .orca/feat-briefs .orca/bug-cases/crash
  cat >.orca/20250101-feat-alpha/spec.md <<'EOF'
# spec

**Workflow run:** wf_abc
**Workflow args:** {"slug":"alpha"}
EOF
  echo '# spec' >.orca/20250102-feat-beta/spec.md
  echo brief >.orca/feat-briefs/idea.md
  echo case >.orca/bug-cases/crash/case.md
  run triage snapshot
  [ "$status" -eq 0 ]
  # both fact domains in one call
  has_line $'RUN:\t'"$PWD/.orca/20250101-feat-alpha"$'\tinterrupted'
  has_line $'TRUNK:\tmain'
  # ranked: interrupted -> queued -> recovery
  has_line $'ACTION:\t1\tresume-run\tfeature\t'"$PWD/.orca/20250101-feat-alpha"$'\t'
  has_line $'ACTION:\t2\trun-brief\tfeature\t'"$PWD/.orca/feat-briefs/idea.md"$'\t'
  has_line $'ACTION:\t3\tdebug-case\tdebug\tcrash\t'
  has_line $'ACTION:\t4\trequeue-brief\t-\t'"$PWD/.orca/20250102-feat-beta"$'\t'
}

@test "snapshot: a live lease suppresses the resume action" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-alpha
  cat >.orca/20250101-feat-alpha/spec.md <<'EOF'
# spec

**Workflow run:** wf_abc
**Workflow args:** {"slug":"alpha"}
EOF
  sleep 60 &
  local spid=$!
  write_owner .orca/20250101-feat-alpha "$(hostname)" "$spid" "$(ps -o lstart= -p "$spid")"
  run triage snapshot
  kill "$spid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  has_line $'RUN:\t'"$PWD/.orca/20250101-feat-alpha"$'\tinterrupted'
  has_line $'LEASE:\tlive\tpid:'"$spid"
  refute_line $'ACTION:\t1\tresume-run'
}

@test "snapshot: a consumed-brief run dir is a run-brief candidate, not a requeue" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-alpha
  echo '# brief' >.orca/20250101-feat-alpha/brief.md
  run triage snapshot
  [ "$status" -eq 0 ]
  has_line $'ACTION:\t1\trun-brief\tfeature\t'"$PWD/.orca/20250101-feat-alpha"$'\t'
  refute_line $'ACTION:\t1\trequeue-brief'
}

@test "snapshot routes finished runs: finish-unmet, review-deliverable, followup" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-stuck .orca/20250102-feat-beta .orca/20250103-feat-landed
  echo '# spec' >.orca/20250101-feat-stuck/spec.md
  echo '# spec' >.orca/20250102-feat-beta/spec.md
  echo '# spec' >.orca/20250103-feat-landed/spec.md
  printf '# report\n\n## Blocked\n\n- W2: needs a decision\n' >.orca/20250101-feat-stuck/report.md
  printf '# report\n\n## Blocked\n\nNone\n\n## Follow-ups\n\n- more polish\n' >.orca/20250102-feat-beta/report.md
  printf '# report\n\n## Blocked\n\nNone\n\n## Follow-ups\n\n- tune the cache\n' >.orca/20250103-feat-landed/report.md
  # beta's deliverable branch is unmerged -> review, not followup
  git checkout -qb feature/beta
  echo work >beta.txt
  git add beta.txt && git commit -qm work
  git checkout -q main
  run triage snapshot
  [ "$status" -eq 0 ]
  has_line $'ACTION:\t1\tfinish-unmet\tretry\t'"$PWD/.orca/20250101-feat-stuck"$'\t'
  has_line $'ACTION:\t2\treview-deliverable\treview\tfeature/beta\t'
  has_line $'ACTION:\t3\tfollowup\tfollowup\t'"$PWD/.orca/20250103-feat-landed"$'\t'
  refute_line $'ACTION:\t3\tfollowup\tfollowup\t'"$PWD/.orca/20250102-feat-beta"
}

@test "snapshot housekeeping: prune merged branches and their worktrees, inspect orphans" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-alpha
  git branch feature/alpha
  git branch feature/alpha-W1
  git worktree add orca-alpha feature/alpha >/dev/null 2>&1
  git checkout -qb feature/gamma
  echo work >g.txt
  git add g.txt && git commit -qm work
  git checkout -q main
  run triage snapshot
  [ "$status" -eq 0 ]
  has_line $'ACTION:\t1\tprune-branch\t-\tfeature/alpha\t'
  has_line $'ACTION:\t2\tprune-branch\t-\tfeature/alpha-W1\t'
  has_line $'ACTION:\t3\tinspect-orphan\t-\tfeature/gamma\t'
  has_line $'ACTION:\t4\tprune-worktree\t-\t'"$PWD/orca-alpha"$'\t'
}

@test "snapshot --run: fragment match in bash, loud miss with candidates" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .orca/20250101-feat-alpha .orca/20250102-feat-beta
  echo '# spec' >.orca/20250101-feat-alpha/spec.md
  echo '# spec' >.orca/20250102-feat-beta/spec.md
  printf '# report\n\n## Blocked\n\nNone\n' >.orca/20250102-feat-beta/report.md
  run triage snapshot --run alpha
  [ "$status" -eq 0 ]
  has_line $'MATCH:\t'"$PWD/.orca/20250101-feat-alpha"
  refute_line $'MISS:\t'
  run triage snapshot --run zulu
  [ "$status" -eq 0 ]
  has_line $'MISS:\tzulu'
  has_line $'CANDIDATE:\t'"$PWD/.orca/20250101-feat-alpha"
  has_line $'CANDIDATE:\t'"$PWD/.orca/20250102-feat-beta"
}
