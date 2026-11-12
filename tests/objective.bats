#!/usr/bin/env bats
# orca.sh objective — new (the files and its refusals), open (the claim,
# worktree arrival without provisioning, idempotence), current, list (derived
# states, counts, owner verdicts), and digest (its bound, never a body).

load helpers

orca() { bash "$SCRIPTS/orca.sh" "$@"; }

# helpers.bash's setup, then a bare-layout repository and a session id
# the test controls (the developer's own session must never leak in).
eval "helpers_$(declare -f setup)"
setup() {
  helpers_setup
  R="$BATS_TEST_TMPDIR/r"
  make_bare_layout "$R"
  export CLAUDE_CODE_SESSION_ID=sess-mine
}

teardown() {
  [ -z "${SPID:-}" ] || kill "$SPID" 2>/dev/null || true
}

# frame_value <key> — the value of <key>= in $output's frame.
frame_value() {
  printf '%s\n' "$output" | sed -n "s/^$1=//p" | head -1
}

# new_objective <slug> — `objective new` off main; sets D to its directory.
new_objective() {
  run orca objective new "$R" "$1" main
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  D="$(frame_value dir)"
}

# decision <id> <state> <question> [source] — one decisions.md entry.
decision() {
  printf '\n## %s — %s\n**State:** %s\n**Source:** %s\n**Options:** a · b\n**Why:** BODY-TEXT-why-%s\n' \
    "$1" "$3" "$2" "${4:-discussion}" "$1" >>"$D/decisions.md"
}

# phase <id> <state> <title> [commit|blocked-on] — one phases.md entry.
phase() {
  {
    printf '\n## %s — %s\n**State:** %s\n**Source:** plan\n**Decisions:** D1\n' "$1" "$3" "$2"
    printf '**Goal:** BODY-TEXT-goal-%s\n**Acceptance:**\n- BODY-TEXT-acceptance\n' "$1"
    case "$2" in
      done) printf '**Commit:** %s\n' "${4:-0123456789abcdef0123456789abcdef01234567}" ;;
      blocked) printf '**Blocked on:** %s\n' "${4:-D9}" ;;
    esac
  } >>"$D/phases.md"
}

# write_owner <dir> <session> <pid> <pidstart> — a hand-built claim whose
# liveness the test controls.
write_owner() {
  printf 'session=%s\nhost=%s\npid=%s\npidstart=%s\ntaken=2026-01-01T00:00:00+0000\n' \
    "$2" "$(hostname)" "$3" "$4" >"$1/owner"
}

# list_line — the OBJECTIVE: line for $D from `list --all`.
list_line() {
  run orca objective list "$R" --all
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F "OBJECTIVE:	$D	"
}

state_is() { # <state> — $D's derived state in `list --all`
  local line
  line="$(list_line)"
  [ "$(printf '%s' "$line" | cut -f4)" = "$1" ] || { echo "expected $1, got: $line" >&2; return 1; }
}

# ---- new --------------------------------------------------------------

@test "new: writes the skeleton files and the branch at the base, frames dir/worktree/branch/base, creates no worktree" {
  new_objective rate-limit
  [[ "${D##*/}" =~ ^[0-9]{8}-[0-9]{6}-rate-limit$ ]] || return 1
  [ "$(dirname "$D")" = "$R/.orca/objectives" ]
  [ "$(frame_value worktree)" = "$R/orca-rate-limit" ]
  [ "$(frame_value branch)" = feature/rate-limit ]
  grep -qx '# rate-limit' "$D/objective.md"
  grep -qx '\*\*Base:\*\* `main`' "$D/objective.md"
  grep -qx "\*\*Base commit:\*\* \`$(git -C "$R" rev-parse main)\`" "$D/objective.md"
  grep -qx '\*\*Branch:\*\* `feature/rate-limit`' "$D/objective.md"
  grep -qx "\*\*Worktree:\*\* \`$R/orca-rate-limit\`" "$D/objective.md"
  grep -qx '## Outcome' "$D/objective.md"
  grep -qx '# Decisions' "$D/decisions.md"
  grep -qx '# Phases' "$D/phases.md"
  [ ! -e "$D/owner" ]
  [ ! -e "$R/orca-rate-limit" ]
  # the branch is born at the base commit, owned by this objective
  [ "$(frame_value base)" = "$(git -C "$R" rev-parse main)" ]
  [ "$(git -C "$R" rev-parse refs/heads/feature/rate-limit)" = "$(git -C "$R" rev-parse main)" ]
}

@test "new: a branch that appears after new and before open cannot be another's — it exists already; an unrelated one is BRANCH_FOREIGN" {
  new_objective alpha
  # another run trying to take the name now collides
  ! git -C "$R/main" branch feature/alpha main 2>/dev/null
  # someone replaces it with an unrelated history before the first open
  git -C "$R/main" branch -D feature/alpha >/dev/null
  git -C "$R/main" checkout -q --orphan other
  git -C "$R/main" commit -q --allow-empty -m 'unrelated'
  git -C "$R/main" branch feature/alpha other
  git -C "$R/main" checkout -q main
  run orca objective open "$D"
  assert_fail_reason BRANCH_FOREIGN
  [ ! -e "$R/orca-alpha" ]
  decision D1 decided 'Per key?'
  phase P1 pending 'Bucket'
  run orca objective phase-start "$D" P1
  assert_fail_reason BRANCH_FOREIGN
  grep -qx '\*\*State:\*\* pending' "$D/phases.md"
  # put back at (or past) the base, it is the objective's again
  git -C "$R/main" branch -f feature/alpha main
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value arrival)" = branch_resumed ]
}

@test "new: refuses a conventional checkout typed" {
  make_repo "$BATS_TEST_TMPDIR/conv"
  run orca objective new "$BATS_TEST_TMPDIR/conv" alpha main
  assert_fail_reason NOT_BARE
  [ ! -e "$BATS_TEST_TMPDIR/conv/.orca/objectives" ]
}

@test "new: refuses an existing branch, objective, or worktree path, writing nothing" {
  git -C "$R" branch feature/taken main
  run orca objective new "$R" taken main
  assert_fail_reason BRANCH_EXISTS
  [ -z "$(ls "$R/.orca/objectives" 2>/dev/null)" ]
  new_objective alpha
  run orca objective new "$R" alpha main
  assert_fail_reason OBJECTIVE_EXISTS
  mkdir "$R/orca-beta"
  run orca objective new "$R" beta main
  assert_fail_reason WORKTREE_EXISTS
  [ "$(ls "$R/.orca/objectives" | wc -l | tr -d ' ')" = 1 ]
}

@test "new: a bad slug, a bad base, bad arguments, outside git fail typed" {
  run orca objective new "$R" Not_Kebab main
  assert_fail_reason BAD_SLUG
  run orca objective new "$R" ok-slug no-such-ref
  assert_fail_reason BAD_REF
  run orca objective new "$R" ok-slug
  assert_fail_reason BAD_ARGS
  mkdir "$BATS_TEST_TMPDIR/plain"
  run orca objective new "$BATS_TEST_TMPDIR/plain" ok-slug main
  assert_fail_reason NOT_GIT
  run orca objective frobnicate
  assert_fail_reason BAD_ARGS
}

@test "new: --idea writes the idea verbatim under ## Idea, from a file or stdin" {
  printf 'add `dark mode` to $HOME\n\nsecond paragraph\n\n\n' >"$BATS_TEST_TMPDIR/idea"
  run orca objective new "$R" alpha main --idea "$BATS_TEST_TMPDIR/idea"
  [ "$status" -eq 0 ]
  D="$(frame_value dir)"
  [ "$(sed -n '/^## Idea$/,/^## Outcome$/p' "$D/objective.md")" = "$(printf '## Idea\n\nadd `dark mode` to $HOME\n\nsecond paragraph\n\n## Outcome')" ]
  run bash -c "printf 'from stdin\n' | bash '$SCRIPTS/orca.sh' objective new '$R' beta main --idea -"
  [ "$status" -eq 0 ]
  D="$(frame_value dir)"
  [ "$(sed -n '/^## Idea$/,/^## Outcome$/p' "$D/objective.md")" = "$(printf '## Idea\n\nfrom stdin\n\n## Outcome')" ]
}

@test "new: an unreadable idea or a stray option fails BAD_ARGS, writing nothing" {
  run orca objective new "$R" alpha main --idea "$BATS_TEST_TMPDIR/missing"
  assert_fail_reason BAD_ARGS
  run orca objective new "$R" alpha main --notes x
  assert_fail_reason BAD_ARGS
  [ -z "$(ls "$R/.orca/objectives" 2>/dev/null)" ]
  run git -C "$R" rev-parse -q --verify refs/heads/feature/alpha
  [ "$status" -ne 0 ]
}

# ---- open -------------------------------------------------------------

@test "open: claims, creates the worktree off the base, frames the list line" {
  new_objective alpha
  git -C "$R/main" commit -q --allow-empty -m 'trunk moves after new'
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  has_line $'OBJECTIVE:\t'"$D"$'\talpha\tdiscussing\topen:0\tpending:0\tblocked:0\tfollowups:0\towner:mine'
  [ "$(frame_value claim)" = claimed ]
  [ "$(frame_value arrival)" = branch_resumed ]
  [ "$(frame_value worktree)" = "$R/orca-alpha" ]
  [ "$(frame_value branch)" = feature/alpha ]
  # the worktree starts at the base commit recorded by new, not today's trunk
  local base
  base="$(sed -n 's/^\*\*Base commit:\*\* `\(.*\)`$/\1/p' "$D/objective.md")"
  [ "$(frame_value base)" = "$base" ]
  [ "$(frame_value head)" = "$base" ]
  [ "$(git -C "$R/orca-alpha" rev-parse HEAD)" = "$base" ]
  [ "$(git -C "$R/orca-alpha" symbolic-ref --short HEAD)" = feature/alpha ]
  grep -qx 'session=sess-mine' "$D/owner"
  grep -qx "host=$(hostname)" "$D/owner"
  grep -qE '^pid=[0-9]+$' "$D/owner"
  grep -q '^pidstart=' "$D/owner"
  grep -q '^taken=' "$D/owner"
}

@test "open and phase-start provision nothing: no secrets, no setup run, no setup keys" {
  mkdir -p "$R/.orca/secrets"
  echo 'SECRET=1' >"$R/.orca/secrets/.env"
  printf 'echo "provisioned $ORCA_ARRIVAL" >>prov.log\n' >"$BATS_TEST_TMPDIR/cand"
  ( cd "$R/main" && bash "$SCRIPTS/orca.sh" setup install "$BATS_TEST_TMPDIR/cand" --sources - ) >/dev/null
  new_objective alpha
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value arrival)" = branch_resumed ]
  [ ! -e "$R/orca-alpha/.env" ] && [ ! -L "$R/orca-alpha/.env" ]
  [ ! -e "$R/orca-alpha/prov.log" ]
  ! printf '%s\n' "$output" | grep -qE '^(LINKED|SETUP|SETUP_TAIL):|^setup' || return 1
  decision D1 decided 'Per key?'
  phase P1 pending 'Bucket'
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  [ "$(frame_value arrival)" = reused ]
  [ ! -e "$R/orca-alpha/prov.log" ]
  ! printf '%s\n' "$output" | grep -qE '^(LINKED|SETUP|SETUP_TAIL):|^setup' || return 1
  # provisioning is the caller's own call, with the arrival the frame named
  run orca provision "$R/orca-alpha" reused
  [ "$status" -eq 0 ]
  [ -L "$R/orca-alpha/.env" ]
  [ "$(cat "$R/orca-alpha/prov.log")" = 'provisioned reused' ]
}

@test "open: run twice is reused and kept, the owner file untouched" {
  new_objective alpha
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  cp "$D/owner" "$BATS_TEST_TMPDIR/owner.before"
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value claim)" = kept ]
  [ "$(frame_value arrival)" = reused ]
  cmp "$D/owner" "$BATS_TEST_TMPDIR/owner.before"
}

@test "open and phase-start: a saved worktree on another branch, detached, or not a worktree is WORKTREE_MISMATCH" {
  new_objective alpha
  decision D1 decided 'Per key?'
  phase P1 pending 'Bucket'
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  local W="$R/orca-alpha"
  git -C "$W" checkout -q -b elsewhere
  run orca objective open "$D"
  assert_fail_reason WORKTREE_MISMATCH
  [[ "$output" == *'elsewhere checked out, not feature/alpha'* ]] || return 1
  run orca objective phase-start "$D" P1
  assert_fail_reason WORKTREE_MISMATCH
  grep -qx '\*\*State:\*\* pending' "$D/phases.md"
  [ ! -e "$D/phases/P1" ]
  git -C "$W" checkout -q --detach
  run orca objective phase-start "$D" P1
  assert_fail_reason WORKTREE_MISMATCH
  [[ "$output" == *'a detached HEAD'* ]] || return 1
  # back on its branch, both pass
  git -C "$W" checkout -q feature/alpha
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  [ "$(frame_value arrival)" = reused ]
  # a plain directory where the worktree should be
  new_objective beta
  mkdir -p "$R/orca-beta"
  run orca objective open "$D"
  assert_fail_reason WORKTREE_MISMATCH
  [[ "$output" == *'not a git worktree root'* ]] || return 1
  [ ! -e "$R/orca-beta/.git" ]
}

@test "open: a hand-deleted worktree resumes on its branch" {
  new_objective alpha
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  rm -rf "$R/orca-alpha"
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value arrival)" = branch_resumed ]
  [ -d "$R/orca-alpha" ]
}

@test "open: a live other session's claim is OWNED_ELSEWHERE — nothing done, --steal refused too" {
  new_objective alpha
  # a live process outside this shell's job table (no reaping noise on kill)
  SPID="$( (sleep 60 >/dev/null 2>&1 & echo $!) )"
  write_owner "$D" sess-other "$SPID" "$(ps -o lstart= -p "$SPID")"
  cp "$D/owner" "$BATS_TEST_TMPDIR/owner.before"
  run orca objective open "$D"
  assert_fail_reason OWNED_ELSEWHERE
  [[ "$output" == *sess-other* ]] || return 1
  run orca objective open "$D" --steal
  assert_fail_reason OWNED_ELSEWHERE
  cmp "$D/owner" "$BATS_TEST_TMPDIR/owner.before"
  [ ! -e "$R/orca-alpha" ]
  run orca objective list "$R"
  has_line $'OBJECTIVE:\t'"$D"$'\talpha\tdiscussing\topen:0\tpending:0\tblocked:0\tfollowups:0\towner:live'
}

@test "open: another host's claim reads unknown and is never taken" {
  new_objective alpha
  printf 'session=sess-other\nhost=elsewhere.invalid\npid=1234\npidstart=x\ntaken=t\n' >"$D/owner"
  run orca objective open "$D" --steal
  assert_fail_reason OWNED_ELSEWHERE
  grep -qx 'session=sess-other' "$D/owner"
}

@test "open: a stale claim needs --steal, which takes it over" {
  new_objective alpha
  # stale: a live pid whose recorded start time does not match (pid reuse shape)
  write_owner "$D" sess-other "$$" "not the real lstart"
  run orca objective open "$D"
  assert_fail_reason OWNER_STALE
  grep -qx 'session=sess-other' "$D/owner"
  [ ! -e "$R/orca-alpha" ]
  run orca objective list "$R"
  has_line $'OBJECTIVE:\t'"$D"$'\talpha\tdiscussing\topen:0\tpending:0\tblocked:0\tfollowups:0\towner:stale'
  run orca objective open "$D" --steal
  [ "$status" -eq 0 ]
  [ "$(frame_value claim)" = stolen ]
  [ "$(frame_value arrival)" = branch_resumed ]
  grep -qx 'session=sess-mine' "$D/owner"
}

@test "open: this session's claim with a dead process is refreshed, not refused" {
  new_objective alpha
  write_owner "$D" sess-mine "$$" "not the real lstart"
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value claim)" = claimed ]
  ! grep -q 'not the real lstart' "$D/owner"
}

@test "open: no session id, an archived objective, a bad dir fail typed with nothing written" {
  new_objective alpha
  CLAUDE_CODE_SESSION_ID='' run orca objective open "$D"
  assert_fail_reason NO_SESSION_ID
  [ ! -e "$D/owner" ]
  printf 'state=abandoned\n' >"$D/archived"
  run orca objective open "$D"
  assert_fail_reason ARCHIVED
  [ ! -e "$D/owner" ]
  [ ! -e "$R/orca-alpha" ]
  run orca objective open "$R/.orca"
  assert_fail_reason BAD_DIR
  mkdir -p "$R/.orca/objectives/not-an-objective"
  run orca objective open "$R/.orca/objectives/not-an-objective"
  assert_fail_reason BAD_DIR
  run orca objective open relative/path
  assert_fail_reason BAD_DIR
  run orca objective open "$D" --force
  assert_fail_reason BAD_ARGS
}

# lock_ref — the objective's claim lock ref; lock_by <pid> <lstart> — a
# claim lock held by that process, on this host; lock_held — the lock
# exists; lock_blob <pid> <lstart> — the blob such a holder writes.
lock_ref() { printf 'refs/orca/claim/%s' "${D##*/}"; }
lock_blob() {
  printf '%s\t%s\t%s' "$(hostname)" "$1" "$2" | git -C "$R/main" hash-object -w --stdin
}
lock_by() {
  git -C "$R/main" update-ref "$(lock_ref)" "$(lock_blob "$1" "$2")"
}
lock_held() { git -C "$R/main" rev-parse -q --verify "$(lock_ref)" >/dev/null; }

@test "open: two sessions opening at once — exactly one claims, the other is OWNED_ELSEWHERE" {
  new_objective alpha
  local n
  for n in 1 2 3; do
    rm -f "$D/owner" "$BATS_TEST_TMPDIR"/[ab].rc
    ( rc=0; CLAUDE_CODE_SESSION_ID=sess-a bash "$SCRIPTS/orca.sh" objective open "$D" >"$BATS_TEST_TMPDIR/a.out" 2>&1 || rc=$?; echo "$rc" >"$BATS_TEST_TMPDIR/a.rc" ) &
    local pa=$!
    ( rc=0; CLAUDE_CODE_SESSION_ID=sess-b bash "$SCRIPTS/orca.sh" objective open "$D" >"$BATS_TEST_TMPDIR/b.out" 2>&1 || rc=$?; echo "$rc" >"$BATS_TEST_TMPDIR/b.rc" ) &
    local pb=$!
    wait "$pa" "$pb" || true
    local winner loser
    if [ "$(cat "$BATS_TEST_TMPDIR/a.rc")" = 0 ]; then winner=a loser=b; else winner=b loser=a; fi
    [ "$(cat "$BATS_TEST_TMPDIR/$winner.rc")" = 0 ] || { cat "$BATS_TEST_TMPDIR"/*.out >&2; return 1; }
    [ "$(cat "$BATS_TEST_TMPDIR/$loser.rc")" = 1 ] || { cat "$BATS_TEST_TMPDIR"/*.out >&2; return 1; }
    grep -q $'^FAIL:\tOWNED_ELSEWHERE\t' "$BATS_TEST_TMPDIR/$loser.out"
    grep -qx "session=sess-$winner" "$D/owner"
    ! lock_held
  done
}

@test "open: a claim lock held by a live process waits, then CLAIM_BUSY with nothing written" {
  new_objective alpha
  SPID="$( (sleep 60 >/dev/null 2>&1 & echo $!) )"
  lock_by "$SPID" "$(ps -o lstart= -p "$SPID")"
  ORCA_OBJ_LOCK_TRIES=2 run orca objective open "$D"
  assert_fail_reason CLAIM_BUSY
  [ ! -e "$D/owner" ] && [ ! -e "$R/orca-alpha" ]
  lock_held
  ORCA_OBJ_LOCK_TRIES=2 run orca objective archive "$D" --abandon
  assert_fail_reason CLAIM_BUSY
}

@test "open: a claim lock left by a gone process is cleared and the claim proceeds" {
  new_objective alpha
  # stale: a live pid whose recorded start time does not match
  lock_by "$$" "not the real lstart"
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value claim)" = claimed ]
  ! lock_held
  # and the archive's lock goes on a typed failure too
  run orca objective archive "$D"
  assert_fail_reason NOT_LANDED
  ! lock_held
}

# behind_lock <cmd...> — run an objective verb in the background while a
# live process holds the claim lock; the caller releases it with
# release_lock and collects the result with behind_result.
behind_lock() {
  SPID="$( (sleep 60 >/dev/null 2>&1 & echo $!) )"
  lock_by "$SPID" "$(ps -o lstart= -p "$SPID")"
  ( rc=0; ORCA_OBJ_LOCK_TRIES=200 bash "$SCRIPTS/orca.sh" "$@" >"$BATS_TEST_TMPDIR/behind.out" 2>&1 || rc=$?
    echo "$rc" >"$BATS_TEST_TMPDIR/behind.rc" ) &
  BPID=$!
  # time for it to pass its argument checks and start waiting on the lock
  perl -e 'select(undef,undef,undef,1.0)'
}
release_lock() { git -C "$R/main" update-ref -d "$(lock_ref)"; wait "$BPID" || true; output="$(cat "$BATS_TEST_TMPDIR/behind.out")"; status="$(cat "$BATS_TEST_TMPDIR/behind.rc")"; }

@test "open: an open waiting behind an archive is ARCHIVED once it gets the lock — no claim, no worktree" {
  new_objective alpha
  behind_lock objective open "$D"
  # the archive it waited on finishes: the archived file is written
  printf 'state=abandoned\ndate=d\ntip=-\nnote=\n' >"$D/archived"
  release_lock
  [ "$status" -eq 1 ]
  assert_fail_reason ARCHIVED
  [ ! -e "$D/owner" ] && [ ! -e "$R/orca-alpha" ]
  [ "$(git -C "$R/main" rev-parse refs/heads/feature/alpha)" = "$(git -C "$R/main" rev-parse main)" ]
}

@test "archive: an archive waiting behind another one is a no-op once it gets the lock" {
  opened alpha
  behind_lock objective archive "$D" --abandon --note second
  printf 'state=landed\ndate=d\ntip=-\nnote=first\n' >"$D/archived"
  cp "$D/archived" "$BATS_TEST_TMPDIR/archived.before"
  release_lock
  [ "$status" -eq 0 ]
  [ "$(frame_value already)" = yes ]
  [ "$(frame_value state)" = archived ]
  cmp "$D/archived" "$BATS_TEST_TMPDIR/archived.before"
  # nothing was removed by the waiting archive
  [ -d "$W" ]
}

@test "unarchive: waits on the claim lock, and one behind an unarchive is a no-op" {
  opened alpha
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  behind_lock objective unarchive "$D"
  rm -f "$D/archived"
  release_lock
  [ "$status" -eq 0 ]
  [ "$(frame_value restored)" = no ]
  ! git -C "$R/main" rev-parse -q --verify refs/heads/feature/alpha
}

@test "open: contenders recovering one stale lock at once — exactly one claims" {
  new_objective alpha
  local n x pids
  for n in 1 2; do
    rm -f "$D/owner" "$BATS_TEST_TMPDIR"/[abcd].rc
    lock_by "$$" "not the real lstart"
    pids=""
    for x in a b c d; do
      ( rc=0; CLAUDE_CODE_SESSION_ID=sess-$x bash "$SCRIPTS/orca.sh" objective open "$D" \
          >"$BATS_TEST_TMPDIR/$x.out" 2>&1 || rc=$?
        echo "$rc" >"$BATS_TEST_TMPDIR/$x.rc" ) &
      pids="$pids $!"
    done
    # shellcheck disable=SC2086
    wait $pids || true
    [ "$(cat "$BATS_TEST_TMPDIR"/[abcd].rc | grep -c '^0$')" -eq 1 ] || { cat "$BATS_TEST_TMPDIR"/[abcd].out >&2; return 1; }
    [ "$(grep -l $'^FAIL:\tOWNED_ELSEWHERE\t' "$BATS_TEST_TMPDIR"/[abcd].out | wc -l | tr -d ' ')" -eq 3 ]
    ! lock_held
  done
}

@test "open: a claim moves this session off its previous objective" {
  new_objective alpha
  local a="$D"
  new_objective beta
  local b="$D"
  run orca objective open "$a"
  [ "$status" -eq 0 ]
  run orca objective open "$b"
  [ "$status" -eq 0 ]
  [ ! -e "$a/owner" ]
  run orca objective current "$R"
  [ "$(frame_value dir)" = "$b" ]
}

# ---- current ----------------------------------------------------------

@test "idle: this session's objective with no active phase passes; another session's, none, or an active phase does not" {
  new_objective alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  run orca objective idle "$D"
  assert_fail_reason NOT_OWNER
  [[ "$output" == *'owner: none'* ]] || return 1
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  run orca objective idle "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value state)" = verify ]
  CLAUDE_CODE_SESSION_ID=sess-other run orca objective idle "$D"
  assert_fail_reason NOT_OWNER
  [[ "$output" == *'session sess-mine'* ]] || return 1
  phase P2 active 'Middleware'
  run orca objective idle "$D"
  assert_fail_reason PHASE_ACTIVE
  CLAUDE_CODE_SESSION_ID='' run orca objective idle "$D"
  assert_fail_reason NO_SESSION_ID
}

@test "idle: a blocked phase, or a restarted one waiting with its base, refuses too — a commit then would fall inside that base" {
  new_objective alpha
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  decision D1 decided 'Per key?'
  phase P1 pending 'Store'
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  decision D2 open 'Which store?'
  run orca objective phase-block "$D" P1 D2
  [ "$status" -eq 0 ]
  run orca objective idle "$D"
  assert_fail_reason PHASE_BLOCKED
  sed -i.bak 's/^\*\*State:\*\* open$/**State:** decided/' "$D/decisions.md"
  mkdir -p "$D/plan"
  P="$D/plan/proposed.md"
  printf '# Phases\n' >"$P"
  block "$P" P1 pending 'Store, decided' 'D1, D2'
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  run orca objective idle "$D"
  assert_fail_reason RESTART_PENDING
  [[ "$output" == *'P1 restarts from its earlier base'* ]] || return 1
}

@test "current: none, then the owned objective; another session's claim and archived ones are not current" {
  new_objective alpha
  run orca objective current "$R"
  [ "$status" -eq 0 ]
  [ "$(frame_value dir)" = none ]
  write_owner "$D" sess-other "$$" x
  run orca objective current "$R"
  [ "$(frame_value dir)" = none ]
  write_owner "$D" sess-mine "$$" x
  run orca objective current "$R/main"
  [ "$(frame_value dir)" = "$D" ]
  printf 'state=landed\n' >"$D/archived"
  run orca objective current "$R"
  [ "$(frame_value dir)" = none ]
  CLAUDE_CODE_SESSION_ID='' run orca objective current "$R"
  assert_fail_reason NO_SESSION_ID
}

# ---- list: derived states ---------------------------------------------

@test "list: discussing with no phases or with an open decision" {
  new_objective alpha
  state_is discussing
  decision D1 decided 'Per key?'
  phase P1 pending 'Bucket'
  state_is ready
  decision D2 open 'Where do bodies come from?'
  state_is discussing
  [ "$(list_line | cut -f5)" = open:1 ]
}

@test "list: planning, ready, active, blocked, idle" {
  new_objective alpha
  decision D1 decided 'Per key?'
  mkdir -p "$D/plan"
  echo proposal >"$D/plan/proposed.md"
  state_is planning
  rm "$D/plan/proposed.md"
  phase P1 done 'Bucket'
  phase P2 pending 'Middleware'
  state_is ready
  sed -i.bak 's/^\*\*State:\*\* pending$/**State:** active/' "$D/phases.md"
  state_is active
  sed -i.bak 's/^\*\*State:\*\* active$/**State:** blocked/' "$D/phases.md"
  printf '**Blocked on:** D2\n' >>"$D/phases.md"
  decision D2 open 'Which store?'
  state_is blocked
  [ "$(list_line | cut -f7)" = blocked:1 ]
  # decided and a new proposal written: replanning
  sed -i.bak 's/^\*\*State:\*\* open$/**State:** decided/' "$D/decisions.md"
  echo proposal >"$D/plan/proposed.md"
  state_is planning
  rm "$D/plan/proposed.md"
  sed -i.bak 's/^\*\*State:\*\* blocked$/**State:** done/' "$D/phases.md"
  # every phase done: verify until a final verification covers the last one
  state_is verify
  printf '# Report: alpha\n\n**Deliverable state:** verified\n**Final verification:** pass after P1 (0123456)\n' >"$D/report.md"
  state_is verify
  sed -i.bak 's/after P1/after P2/' "$D/report.md"
  state_is idle
  sed -i.bak 's/pass after P2/fail after P2/' "$D/report.md"
  state_is idle
  sed -i.bak 's/fail after P2/later after P2/' "$D/report.md"
  state_is verify
}

@test "list: landed once the branch moved and merged into trunk; archived and abandoned only with --all" {
  new_objective alpha
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  # every phase done but the branch still at its base: never landed
  state_is verify
  echo work >"$R/orca-alpha/work.txt"
  git -C "$R/orca-alpha" add work.txt
  git -C "$R/orca-alpha" commit -qm 'add work'
  state_is verify
  git -C "$R/main" merge -q --no-ff -m 'land alpha' feature/alpha
  state_is landed
  printf 'state=landed\ndate=2026-11-03\n' >"$D/archived"
  state_is archived
  run orca objective list "$R"
  [ "$status" -eq 0 ]
  refute_line $'OBJECTIVE:\t'"$D"
  new_objective beta
  printf 'state=abandoned\n' >"$D/archived"
  state_is abandoned
}

@test "list: counts open follow-ups, a decision citing one takes it; owner none" {
  new_objective alpha
  phase P1 done 'Bucket'
  phase P2 pending 'Middleware'
  phase P3 blocked 'Docs' D2
  decision D1 decided 'Per key?' F2
  decision D2 open 'Which store?'
  cat >"$D/report.md" <<'EOF'
# Report: alpha

## Phases

### P1 — Bucket — 0123456

## Follow-ups

- F1 · P1 · out of scope · a — x.sh
- F2 · P1 · gap · b — why
- F3 · P1 · left unfixed (Medium) · c — reason

## Landing
- F9 · not a follow-up, wrong section
EOF
  run orca objective list "$R"
  [ "$status" -eq 0 ]
  has_line $'OBJECTIVE:\t'"$D"$'\talpha\tblocked\topen:1\tpending:1\tblocked:1\tfollowups:2\towner:none'
}

@test "list: one line per objective, oldest first; nothing for a repo without objectives" {
  run orca objective list "$R"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mkdir -p "$R/.orca/objectives/20250101-000000-older" "$R/.orca/objectives/stray"
  cp /dev/null "$R/.orca/objectives/20250101-000000-older/objective.md"
  new_objective newer
  run orca objective list "$R"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 2 ]
  [ "$(printf '%s\n' "$output" | head -1 | cut -f3)" = older ]
  [ "$(printf '%s\n' "$output" | tail -1 | cut -f3)" = newer ]
  run orca objective list "$R" --everything
  assert_fail_reason BAD_ARGS
}

# ---- digest -----------------------------------------------------------

@test "digest: title, outcome, state, tree, decisions, phases, action, follow-ups, last entry" {
  new_objective alpha
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  sed -i.bak 's/^# alpha$/# Rate limit the public API/' "$D/objective.md"
  sed -i.bak 's/^## Outcome$/## Outcome\
\
Public routes answer 429 past a per-key budget.\
A second outcome line never shown./' "$D/objective.md"
  decision D1 decided 'Per key or per IP?'
  decision D2 open 'Where do 429 bodies come from?'
  decision D3 deferred 'Burst size?'
  phase P1 done 'Token bucket' abcdef0123456789abcdef0123456789abcdef01
  phase P2 active 'Middleware on public routes'
  phase P3 pending '429 responses'
  mkdir -p "$D/phases/P2"
  printf '@@ORCA@@\nrc=0\naction=review\nround=2\ngating=1\nminor=0\nout_of_scope=3\n@@ORCA_END@@\n' >"$D/phases/P2/action"
  printf '# Report: alpha\n\n## Phases\n\n### P1 — Token bucket — abcdef0\n- Review: codex\n\n## Follow-ups\n\n- F1 · P1 · gap · x — y\n' >"$D/report.md"
  echo dirt >"$R/orca-alpha/dirt.txt"
  run orca objective digest "$D"
  [ "$status" -eq 0 ]
  local want
  want="# Rate limit the public API
Outcome: Public routes answer 429 past a per-key budget.
State: active
Worktree: $R/orca-alpha (dirty)
Branch: feature/alpha
Decisions: 1 decided, 1 open, 1 deferred
  D2  open  Where do 429 bodies come from?
Phases: 1 of 3 done
  P1  done abcdef0  Token bucket
  P2  active  Middleware on public routes
  P3  pending  429 responses
Action: P2 · review round 2 · gating 1, minor 0, out of scope 3
Final verification: none
Follow-ups: 1 open
Last report entry: P1 — Token bucket — abcdef0"
  if [ "$output" != "$want" ]; then
    printf 'expected:\n%s\nactual:\n%s\n' "$want" "$output" >&2
    return 1
  fi
}

@test "digest: stays within 40 lines on a large objective, never quotes a body, keeps every unfinished phase" {
  new_objective alpha
  local i
  for i in $(seq 1 60); do
    if [ $((i % 3)) -eq 0 ]; then decision "D$i" open "Open question number $i"; else decision "D$i" decided "Settled question $i"; fi
  done
  for i in $(seq 1 45); do phase "P$i" done "Finished phase $i"; done
  phase P46 blocked 'Blocked phase' D3
  for i in $(seq 47 55); do phase "P$i" pending "Pending phase $i"; done
  {
    printf '# Report: alpha\n\n## Phases\n\n'
    for i in $(seq 1 45); do printf '### P%s — Finished phase %s — 0123456\n- Review: codex\n\n' "$i" "$i"; done
    printf '## Follow-ups\n\n'
    for i in $(seq 1 35); do printf -- '- F%s · P1 · gap · t%s — BODY-TEXT-why\n' "$i" "$i"; done
  } >"$D/report.md"
  run orca objective digest "$D"
  [ "$status" -eq 0 ]
  local lines
  lines="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [ "$lines" -le 40 ] || { printf '%s lines:\n%s\n' "$lines" "$output" >&2; return 1; }
  [[ "$output" != *BODY-TEXT* ]] || return 1
  [[ "$output" != *"Settled question"* ]] || return 1
  has_line 'Decisions: 40 decided, 20 open, 0 deferred'
  has_line '  D3  open  Open question number 3'
  has_line '  … 12 more open'
  has_line 'Phases: 45 of 55 done'
  has_line '  P46  blocked on D3  Blocked phase'
  has_line '  P55  pending  Pending phase 55'
  has_line '  P45  done 0123456  Finished phase 45'
  has_line '  … 42 more: 42 done'
  has_line 'Follow-ups: 35 open'
  has_line 'Last report entry: P45 — Finished phase 45 — 0123456'
}

@test "digest: the active phase is listed even when more unfinished phases come before it than fit" {
  new_objective alpha
  decision D1 decided 'Per key?'
  local n
  for n in $(seq 1 13); do phase "P$n" pending "Pending $n"; done
  phase P14 active 'The loop phase'
  run orca objective digest "$D"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^  P14  active  The loop phase$'
  [ "$(printf '%s\n' "$output" | grep -cE '^  P[0-9]+  ')" -eq 13 ]
  # the rest still listed in file order, one pending counted
  printf '%s\n' "$output" | grep -qE '^  P1  pending  Pending 1$'
  ! printf '%s\n' "$output" | grep -qE '^  P13  ' || return 1
  printf '%s\n' "$output" | grep -qx '  … 1 more: 1 pending'
  [ "$(printf '%s\n' "$output" | wc -l)" -le 40 ]
}

@test "digest: truncates long titles on a character boundary; a missing worktree reads absent" {
  new_objective alpha
  local long
  long="$(printf 'é%.0s' $(seq 1 80))"
  decision D1 open "$long"
  run orca objective digest "$D"
  [ "$status" -eq 0 ]
  has_line "Worktree: $R/orca-alpha (absent)"
  has_line 'Outcome: not written yet'
  local row
  row="$(printf '%s\n' "$output" | grep '^  D1  open  ')"
  [[ "$row" == *… ]] || return 1
  [ "${#row}" -le 80 ]
  # valid UTF-8 throughout: iconv rejects a split sequence
  printf '%s' "$row" | iconv -f UTF-8 -t UTF-8 >/dev/null
}

@test "digest: a bad dir and bad arguments fail typed" {
  run orca objective digest "$R/.orca"
  assert_fail_reason BAD_DIR
  run orca objective digest
  assert_fail_reason BAD_ARGS
}

# ---- plan-accept and phase-add ------------------------------------------

# block <file> <id> <state> <title> [decisions] [source] — one phase block
# appended to <file>, with a goal and two acceptance lines.
block() {
  printf '\n## %s — %s\n**State:** %s\n**Source:** %s\n**Decisions:** %s\n**Goal:** goal of %s\n**Acceptance:**\n- first check\n- second check\n' \
    "$2" "$4" "$3" "${6:-plan}" "${5:-none}" "$2" >>"$1"
}

# planned — an objective with D1 decided, P1 done, P2 blocked on D2
# (deferred, so still blocked), P3 pending; P is its proposal path, empty.
planned() {
  new_objective alpha
  decision D1 decided 'Per key?'
  decision D2 deferred 'Which store?'
  phase P1 done 'Bucket'
  phase P2 blocked 'Store' D2
  phase P3 pending 'Middleware'
  mkdir -p "$D/plan"
  P="$D/plan/proposed.md"
  : >"$P"
}

# carry <ids...> — copy these phases.md blocks verbatim into the proposal.
carry() {
  local id
  printf '# Phases\n' >"$P"
  for id in "$@"; do
    printf '\n' >>"$P"
    awk -v id="$id" '/^## / { inside = (index($0, "## " id " — ") == 1) } inside' "$D/phases.md" >>"$P"
  done
}

# refused <reason> — the last run failed typed and nothing was installed.
refused() {
  assert_fail_reason "$1"
  cmp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  [ -f "$P" ]
}

@test "plan-accept --check: validates only and frames the pending phases; plan-accept installs and drops the proposal" {
  planned
  carry P1 P2
  block "$P" P3 pending 'Middleware, rewritten' D1
  block "$P" P4 pending 'Docs'
  printf -- '- third check\n' >>"$P"
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  state_is planning
  run orca objective plan-accept "$D" --check
  [ "$status" -eq 0 ]
  [ "$(frame_value accepted)" = no ]
  [ "$(frame_value kept)" = 2 ]
  [ "$(frame_value phases)" = 2 ]
  [ "$(frame_value phase.1.id)" = P3 ]
  [ "$(frame_value phase.1.title.b64 | base64 --decode)" = 'Middleware, rewritten' ]
  [ "$(frame_value phase.1.acceptance)" = 2 ]
  [ "$(frame_value phase.2.id)" = P4 ]
  [ "$(frame_value phase.2.acceptance)" = 3 ]
  cmp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  [ -f "$P" ]
  cp "$P" "$BATS_TEST_TMPDIR/proposal"
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value accepted)" = yes ]
  cmp "$D/phases.md" "$BATS_TEST_TMPDIR/proposal"
  [ ! -e "$P" ]
  state_is blocked
}

@test "plan-accept: a done or blocked phase dropped or changed is PLAN_REWRITES_DONE; pending ones may be dropped" {
  planned
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  carry P1
  block "$P" P4 pending 'Next'
  run orca objective plan-accept "$D" --check
  refused PLAN_REWRITES_DONE
  [[ "$output" == *P2* ]] || return 1
  carry P1 P2
  sed -i.bak 's/^\*\*Goal:\*\* BODY-TEXT-goal-P1$/**Goal:** reworded/' "$P"
  run orca objective plan-accept "$D" --check
  refused PLAN_REWRITES_DONE
  [[ "$output" == *P1* ]] || return 1
  # trailing blank lines are not a change; dropping pending P3 is fine
  carry P1 P2
  printf '\n\n\n' >>"$P"
  block "$P" P4 pending 'Next'
  run orca objective plan-accept "$D" --check
  [ "$status" -eq 0 ]
  [ "$(frame_value kept)" = 2 ]
  [ "$(frame_value phase.1.id)" = P4 ]
}

@test "plan-accept: a bad heading, a repeated id, or a new id off the sequence is PLAN_BAD_ID" {
  planned
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  carry P1 P2
  printf '\n## Notes\nprose\n' >>"$P"
  run orca objective plan-accept "$D" --check
  refused PLAN_BAD_ID
  carry P1 P2
  block "$P" P3 pending 'Middleware'
  block "$P" P3 pending 'Again'
  run orca objective plan-accept "$D" --check
  refused PLAN_BAD_ID
  carry P1 P2
  block "$P" P5 pending 'Skips P4'
  run orca objective plan-accept "$D" --check
  refused PLAN_BAD_ID
  [[ "$output" == *"next id is P4"* ]] || return 1
  carry P1 P2
  block "$P" P4 pending 'Next'
  block "$P" P6 pending 'Skips P5'
  run orca objective plan-accept "$D" --check
  refused PLAN_BAD_ID
}

@test "plan-accept: a phase not pending, without a goal, or without acceptance is PLAN_BAD_PHASE" {
  planned
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  carry P1 P2
  block "$P" P3 done 'Claims done'
  run orca objective plan-accept "$D" --check
  refused PLAN_BAD_PHASE
  carry P1 P2
  printf '\n## P3 — No acceptance\n**State:** pending\n**Goal:** g\n**Acceptance:**\n' >>"$P"
  run orca objective plan-accept "$D" --check
  refused PLAN_BAD_PHASE
  carry P1 P2
  printf '\n## P3 — No goal\n**State:** pending\n**Acceptance:**\n- a\n' >>"$P"
  run orca objective plan-accept "$D" --check
  refused PLAN_BAD_PHASE
}

@test "plan-accept: an undecided or unknown decision is PLAN_UNDECIDED; an open one DECISION_OPEN; an active phase PHASE_ACTIVE; no proposal NO_PLAN" {
  planned
  decision D3 deferred 'Burst size?'
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  carry P1 P2
  block "$P" P3 pending 'Middleware' 'D1, D3'
  run orca objective plan-accept "$D" --check
  refused PLAN_UNDECIDED
  [[ "$output" == *D3* ]] || return 1
  carry P1 P2
  block "$P" P3 pending 'Middleware' D9
  run orca objective plan-accept "$D" --check
  refused PLAN_UNDECIDED
  carry P1 P2
  block "$P" P3 pending 'Middleware' D1
  decision D4 open 'Still open?'
  run orca objective plan-accept "$D"
  refused DECISION_OPEN
  sed -i.bak 's/^\*\*State:\*\* open$/**State:** decided/' "$D/decisions.md"
  sed -i.bak 's/^\*\*State:\*\* pending$/**State:** active/' "$D/phases.md"
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  run orca objective plan-accept "$D"
  refused PHASE_ACTIVE
  rm "$P"
  run orca objective plan-accept "$D"
  assert_fail_reason NO_PLAN
  run orca objective plan-accept "$D" --force
  assert_fail_reason BAD_ARGS
}

# unblockable — P1 done, P2 blocked on D2 (decided since), P3 blocked on
# D3 (deferred), P4 pending, and a report whose Blocked section lists P2
# and P3; P is the proposal path, empty.
unblockable() {
  new_objective alpha
  decision D1 decided 'Per key?'
  decision D2 decided 'Which store?'
  decision D3 deferred 'Burst size?'
  phase P1 done 'Bucket'
  phase P2 blocked 'Store' D2
  phase P3 blocked 'Bursts' D3
  phase P4 pending 'Middleware'
  printf '# Report: alpha\n\n**Deliverable:** `feature/alpha`\n**Deliverable state:** verified\n\n## Phases\n\n## Blocked\n\nP2 — waiting on D2: Which store?\nP3 — waiting on D3: Burst size?\n\n## Follow-ups\n\nNone\n\n## Landing\n\ngit merge --no-ff feature/alpha\n' >"$D/report.md"
  mkdir -p "$D/plan"
  P="$D/plan/proposed.md"
  : >"$P"
}

blocked_section() { # the lines under report.md's ## Blocked, blanks dropped
  awk '/^## / { inside = ($0 == "## Blocked"); next } inside && NF' "$D/report.md"
}

@test "plan-accept: an unblocked phase the plan keeps starts over — its old rounds move aside, base stays, rounds next implements" {
  unblockable
  # P2 ran, its implementer found it infeasible, and it blocked on D2.
  local pd="$D/phases/P2"
  mkdir -p "$pd/responses" "$pd/reviews"
  printf 'abc123\n' >"$pd/base"
  printf '{"checks":{"commands":[],"pass":true,"failure":""},"findings":[],"followups":[],"status":"infeasible","questions":[]}\n' \
    >"$pd/responses/round-0.json"
  printf 'continue\t2\tgo\n' >"$pd/overrides"
  printf 'old notes\n' >"$pd/notes.md"
  printf '# P2 — Store\n' >"$pd/brief.md"
  printf '@@ORCA@@\nrc=0\naction=infeasible\nround=0\ngating=0\nminor=0\nout_of_scope=0\n@@ORCA_END@@\n' >"$pd/action"
  run orca rounds next "$pd"
  has_line 'action=infeasible'
  carry P1 P3
  block "$P" P2 pending 'Store, on the decided backend' 'D1, D2'
  # the restarted P2 runs before P4, which never started
  awk '/^## / { inside = (index($0, "## P4 — ") == 1) } inside' "$D/phases.md" | { printf '\n'; cat; } >>"$P"
  # --check moves nothing
  run orca objective plan-accept "$D" --check
  [ "$status" -eq 0 ]
  [ "$(frame_value restarted)" = P2 ]
  [ -f "$pd/responses/round-0.json" ] && [ ! -e "$pd/superseded" ]
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value restarted)" = P2 ]
  [ "$(cat "$pd/base")" = abc123 ]
  local k
  for k in responses reviews overrides notes.md brief.md action; do
    [ ! -e "$pd/$k" ] || { echo "$k left behind" >&2; return 1; }
    [ -e "$pd/superseded/1/$k" ] || { echo "$k not moved" >&2; return 1; }
  done
  run orca rounds next "$pd"
  [ "$status" -eq 0 ]
  has_line 'action=implement'
  has_line 'round=0'
  # a second restart takes the next free slot
  mkdir -p "$pd/responses"
  printf '{}' >"$pd/responses/round-0.json"
  sed -i.bak 's/^\*\*State:\*\* pending$/**State:** blocked\n**Blocked on:** D2/' "$D/phases.md"
  awk '/^## P2 — /{f=1} f && /^\*\*State:\*\*/{print "**State:** blocked"; print "**Blocked on:** D2"; f=0; next} {print}' \
    "$D/phases.md.bak" >"$D/phases.md"
  mkdir -p "$D/plan"
  carry P1 P3
  block "$P" P2 pending 'Store, again' 'D1, D2'
  awk '/^## / { inside = (index($0, "## P4 — ") == 1) } inside' "$D/phases.md" | { printf '\n'; cat; } >>"$P"
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  [ -f "$pd/superseded/2/responses/round-0.json" ]
  [ -f "$pd/superseded/1/responses/round-0.json" ]
}

@test "plan-accept: an unblocked phase dropped, and a still-blocked one, keep their rounds" {
  unblockable
  mkdir -p "$D/phases/P2/responses" "$D/phases/P3/responses"
  printf '{}' >"$D/phases/P2/responses/round-0.json"
  printf '{}' >"$D/phases/P3/responses/round-0.json"
  carry P1 P3 P4
  # attempted with no recorded base: nothing proves it left no work
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  run orca objective plan-accept "$D"
  refused PLAN_DROPS_WORK
  # its base recorded, and no branch holds anything past it
  git -C "$R/main" rev-parse HEAD >"$D/phases/P2/base"
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value restarted)" = - ]
  [ -f "$D/phases/P2/responses/round-0.json" ] && [ ! -e "$D/phases/P2/superseded" ]
  [ -f "$D/phases/P3/responses/round-0.json" ] && [ ! -e "$D/phases/P3/superseded" ]
}

@test "plan-accept: a restarted phase must run before every phase not yet started — PLAN_BAD_ORDER, and the commit checks that order protects" {
  new_objective alpha
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  local W="$R/orca-alpha" A
  decision D1 decided 'Per key?'
  phase P1 pending 'Store'
  phase P2 pending 'Middleware'
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  A="$(frame_value base)"
  # the implementer's question is left for later: P1 blocks on it
  decision D2 open 'Which store?'
  run orca objective phase-block "$D" P1 D2
  [ "$status" -eq 0 ]
  sed -i.bak 's/^\*\*State:\*\* open$/**State:** decided/' "$D/decisions.md"
  mkdir -p "$D/plan"
  P="$D/plan/proposed.md"
  printf '# Phases\n' >"$P"
  block "$P" P2 pending 'Middleware' D1
  block "$P" P1 pending 'Store, decided' 'D1, D2'
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  run orca objective plan-accept "$D" --check
  assert_fail_reason PLAN_BAD_ORDER
  [[ "$output" == *'P1 was attempted from a recorded base and must run before P2'* ]] || return 1
  run orca objective plan-accept "$D"
  refused PLAN_BAD_ORDER
  # the restarted phase first: accepted
  printf '# Phases\n' >"$P"
  block "$P" P1 pending 'Store, decided' 'D1, D2'
  block "$P" P2 pending 'Middleware' D1
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  # P1 runs from its kept base A and commits
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  [ "$(frame_value base)" = "$A" ]
  echo store >"$W/store.txt"
  run orca loop snapshot "$W" "$D/phases/P1"
  local t1
  t1="$(frame_value tree)"
  git -C "$W" add -A && git -C "$W" commit -qm 'feat: add the store'
  run orca loop check "$W" "$A" "$t1"
  [ "$(frame_value action)" = accepted ]
  local c1
  c1="$(git -C "$W" rev-parse HEAD)"
  mkdir -p "$D/phases/P1/responses"
  printf '{"checks":{"commands":["t"],"pass":true,"failure":""},"findings":[],"followups":[],"status":"done","questions":[]}\n' >"$D/phases/P1/responses/round-0.json"
  run orca objective phase-done "$D" P1 "$c1"
  [ "$status" -eq 0 ]
  # P2's base is P1's commit: a reset in P2's commit check keeps P1's work
  run orca objective phase-start "$D" P2
  [ "$status" -eq 0 ]
  [ "$(frame_value base)" = "$c1" ]
  echo mw >"$W/mw.txt"
  run orca loop snapshot "$W" "$D/phases/P2"
  local t2
  t2="$(frame_value tree)"
  echo hooked >>"$W/mw.txt"
  git -C "$W" add -A && git -C "$W" commit -qm 'feat: add the middleware'
  run orca loop check "$W" "$c1" "$t2"
  [ "$(frame_value action)" = content_reset ]
  [ "$(git -C "$W" rev-parse HEAD)" = "$c1" ]
  git -C "$W" merge-base --is-ancestor "$c1" HEAD
}

@test "a restarted phase runs first through every entry point: the phase-add shortcut and phase-start are RESTART_PENDING" {
  new_objective alpha
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  local A
  decision D1 decided 'Per key?'
  phase P1 pending 'Store'
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  A="$(frame_value base)"
  decision D2 open 'Which store?'
  run orca objective phase-block "$D" P1 D2
  [ "$status" -eq 0 ]
  sed -i.bak 's/^\*\*State:\*\* open$/**State:** decided/' "$D/decisions.md"
  mkdir -p "$D/plan"
  P="$D/plan/proposed.md"
  printf '# Phases\n' >"$P"
  block "$P" P1 pending 'Store, decided' 'D1, D2'
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  [ "$(cat "$D/phases/P1/base")" = "$A" ]
  # /orca:loop's shortcut: no phase may be added while P1 waits to restart
  block "$BATS_TEST_TMPDIR/p2.md" P2 pending 'Loop fix' none loop
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  run orca objective phase-add "$D" "$BATS_TEST_TMPDIR/p2.md"
  assert_fail_reason RESTART_PENDING
  [[ "$output" == *'P1 restarts from its earlier base'* ]] || return 1
  cmp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  # a phase without a base, however it got into phases.md, does not start first
  block "$D/phases.md" P2 pending 'Loop fix' none loop
  run orca objective phase-start "$D" P2
  assert_fail_reason RESTART_PENDING
  [ ! -e "$D/phases/P2" ]
  grep -qx '\*\*State:\*\* pending' "$D/phases.md"
  # the restarted phase itself starts, from its kept base
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  [ "$(frame_value base)" = "$A" ]
}

@test "plan-accept: a phase blocked on a now-decided decision is rewritten pending under its id; the report's Blocked follows" {
  unblockable
  carry P1 P3 P4
  block "$P" P2 pending 'Store, on the decided backend' 'D1, D2'
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  run orca objective plan-accept "$D" --check
  [ "$status" -eq 0 ]
  [ "$(frame_value kept)" = 2 ]
  [ "$(frame_value unblocked)" = 1 ]
  [ "$(frame_value phases)" = 2 ]
  [ "$(frame_value phase.1.id)" = P4 ]
  [ "$(frame_value phase.2.id)" = P2 ]
  [ "$(frame_value phase.2.title.b64 | base64 --decode)" = 'Store, on the decided backend' ]
  cmp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  cp "$P" "$BATS_TEST_TMPDIR/proposal"
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  cmp "$D/phases.md" "$BATS_TEST_TMPDIR/proposal"
  # P2 is pending with no Blocked on line; P3 is still blocked on D3
  [ "$(awk '/^## P2 — /,/^\*\*Acceptance/' "$D/phases.md" | grep -c 'Blocked on')" -eq 0 ]
  grep -qx '\*\*Blocked on:\*\* D3' "$D/phases.md"
  [ "$(blocked_section)" = 'P3 — waiting on D3: Burst size?' ]
  # the rest of the report is untouched
  grep -qx '\*\*Deliverable state:\*\* verified' "$D/report.md"
  grep -qx 'git merge --no-ff feature/alpha' "$D/report.md"
  state_is blocked
}

@test "plan-accept: the last blocked phase unblocked leaves the report's Blocked None and the phase startable" {
  unblockable
  sed -i.bak 's/^\*\*State:\*\* deferred$/**State:** decided/' "$D/decisions.md"
  carry P1
  block "$P" P2 pending 'Store' D2
  block "$P" P3 pending 'Bursts' D3
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value kept)" = 1 ]
  [ "$(frame_value unblocked)" = 2 ]
  [ "$(blocked_section)" = None ]
  [ "$(grep -c '^\*\*State:\*\* pending$' "$D/phases.md")" -eq 2 ]
  state_is ready
}

@test "plan-accept: a decided-blocked phase copied still blocked, or rewritten keeping Blocked on, is PLAN_BAD_PHASE; it may be dropped" {
  unblockable
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  cp "$D/report.md" "$BATS_TEST_TMPDIR/report.before"
  carry P1 P2 P3
  run orca objective plan-accept "$D"
  refused PLAN_BAD_PHASE
  [[ "$output" == *P2* ]] || return 1
  carry P1 P3
  block "$P" P2 pending 'Store' D2
  printf '**Blocked on:** D2\n' >>"$P"
  run orca objective plan-accept "$D"
  refused PLAN_BAD_PHASE
  [[ "$output" == *'Blocked on'* ]] || return 1
  cmp "$D/report.md" "$BATS_TEST_TMPDIR/report.before"
  # an undecided blocked phase still may not change
  carry P1 P2
  block "$P" P3 pending 'Bursts' D1
  run orca objective plan-accept "$D" --check
  refused PLAN_REWRITES_DONE
  [[ "$output" == *P3* ]] || return 1
  # dropping the decided-blocked phase (and pending P4) is accepted
  carry P1 P3
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value unblocked)" = 1 ]
  [ "$(frame_value phases)" = 0 ]
  [ "$(blocked_section)" = 'P3 — waiting on D3: Burst size?' ]
}

@test "plan-accept: with no report yet, installing writes none" {
  unblockable
  rm "$D/report.md"
  carry P1 P3
  block "$P" P2 pending 'Store' D2
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  [ ! -e "$D/report.md" ]
}

@test "phase-add: appends one loop phase, validated like plan-accept" {
  new_objective alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  local b="$BATS_TEST_TMPDIR/block.md"
  block "$b" P2 pending 'Small fix' D1 loop
  run orca objective phase-add "$D" "$b"
  [ "$status" -eq 0 ]
  [ "$(frame_value phase)" = P2 ]
  [ "$(frame_value acceptance)" = 2 ]
  grep -qx '## P2 — Small fix' "$D/phases.md"
  grep -qx '\*\*Source:\*\* loop' "$D/phases.md"
  state_is ready
}

@test "phase-add: refusals leave phases.md as it was" {
  new_objective alpha
  decision D1 decided 'Per key?'
  decision D2 deferred 'Later?'
  phase P1 done 'Bucket'
  P="$BATS_TEST_TMPDIR/block.md"
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  block "$P" P2 pending 'From the plan' none plan
  run orca objective phase-add "$D" "$P"
  refused PLAN_BAD_PHASE
  : >"$P"; block "$P" P2 pending 'One' none loop; block "$P" P3 pending 'Two' none loop
  run orca objective phase-add "$D" "$P"
  refused PLAN_BAD_PHASE
  : >"$P"; printf 'preamble\n' >"$P"; block "$P" P2 pending 'Text first' none loop
  run orca objective phase-add "$D" "$P"
  refused PLAN_BAD_PHASE
  : >"$P"; block "$P" P2 blocked 'Not pending' none loop
  run orca objective phase-add "$D" "$P"
  refused PLAN_BAD_PHASE
  : >"$P"; block "$P" P2 pending 'Deferred decision' D2 loop
  run orca objective phase-add "$D" "$P"
  refused PLAN_UNDECIDED
  : >"$P"; block "$P" P2 pending 'Fine' none loop
  decision D3 open 'Open?'
  run orca objective phase-add "$D" "$P"
  refused DECISION_OPEN
  sed -i.bak 's/^\*\*State:\*\* open$/**State:** decided/' "$D/decisions.md"
  phase P2 active 'Running'
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  : >"$P"; block "$P" P3 pending 'Fine' none loop
  run orca objective phase-add "$D" "$P"
  refused PHASE_ACTIVE
  run orca objective phase-add "$D" "$BATS_TEST_TMPDIR/no-such-file"
  assert_fail_reason PHASE_ACTIVE
  sed -i.bak 's/^\*\*State:\*\* active$/**State:** done/' "$D/phases.md"
  run orca objective phase-add "$D" "$BATS_TEST_TMPDIR/no-such-file"
  assert_fail_reason NO_FILE
}

@test "phase-add: a final verification's fix phase is Source verify" {
  new_objective alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  local b="$BATS_TEST_TMPDIR/block.md"
  block "$b" P1 pending 'Restore the bucket tests' none verify
  run orca objective phase-add "$D" "$b"
  [ "$status" -eq 0 ]
  [ "$(frame_value phase)" = P2 ]
  grep -qx '\*\*Source:\*\* verify' "$D/phases.md"
  state_is ready
}

# ---- phase-start ----------------------------------------------------------

@test "phase-start: pending to active with base and brief; a re-start keeps the base" {
  new_objective alpha
  decision D1 decided 'Per key?'
  decision D2 decided 'Unrelated?'
  phase P1 pending 'Bucket'
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  [ "$(frame_value started)" = yes ]
  [ "$(frame_value base_kept)" = no ]
  [ "$(frame_value arrival)" = branch_resumed ]
  [ "$(frame_value dir)" = "$D/phases/P1" ]
  [ "$(frame_value brief)" = "$D/phases/P1/brief.md" ]
  local base
  base="$(git -C "$R/orca-alpha" rev-parse HEAD)"
  [ "$(frame_value base)" = "$base" ]
  [ "$(cat "$D/phases/P1/base")" = "$base" ]
  # the round engine guards this work tree
  [ "$(cat "$D/phases/P1/worktree")" = "$R/orca-alpha" ]
  grep -qx '\*\*State:\*\* active' "$D/phases.md"
  state_is active
  # the brief: the block without its state lines, then its decisions only
  grep -qx '# P1 — Bucket' "$D/phases/P1/brief.md"
  grep -qx '\*\*Goal:\*\* BODY-TEXT-goal-P1' "$D/phases/P1/brief.md"
  grep -qx -- '- BODY-TEXT-acceptance' "$D/phases/P1/brief.md"
  grep -qx '### D1 — Per key?' "$D/phases/P1/brief.md"
  ! grep -q 'State:\*\* pending\|Source:\*\* plan\|D2 —' "$D/phases/P1/brief.md" || return 1
  # work moves HEAD; the re-start resumes against the same base
  echo work >"$R/orca-alpha/work.txt"
  git -C "$R/orca-alpha" add work.txt
  git -C "$R/orca-alpha" commit -qm work
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  [ "$(frame_value started)" = no ]
  [ "$(frame_value base_kept)" = yes ]
  [ "$(frame_value arrival)" = reused ]
  [ "$(frame_value base)" = "$base" ]
  [ "$(cat "$D/phases/P1/base")" = "$base" ]
  [ "$(grep -c '^\*\*State:\*\*' "$D/phases.md")" = 1 ]
}

@test "phase-start: a brief or base it cannot write fails WRITE_ERROR and the phase stays pending" {
  new_objective alpha
  decision D1 decided 'Per key?'
  phase P1 pending 'Bucket'
  mkdir -p "$D/phases/P1"
  ln -s "$BATS_TEST_TMPDIR/elsewhere.md" "$D/phases/P1/brief.md"
  run orca objective phase-start "$D" P1
  assert_fail_reason WRITE_ERROR
  refute_line 'rc=0'
  grep -qx '\*\*State:\*\* pending' "$D/phases.md"
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere.md" ]
  rm "$D/phases/P1/brief.md" "$D/phases/P1/base"
  # a base path that is a dangling link: unreadable, then unwritable
  ln -s "$BATS_TEST_TMPDIR/nowhere" "$D/phases/P1/base"
  run orca objective phase-start "$D" P1
  assert_fail_reason WRITE_ERROR
  refute_line 'rc=0'
  grep -qx '\*\*State:\*\* pending' "$D/phases.md"
  [ ! -e "$D/phases/P1/brief.md" ]
}

@test "write failures stop phase-done, phase-block, phase-add, and plan-accept before they report success" {
  new_objective alpha
  decision D1 decided 'Per key?'
  phase P1 active 'Bucket'
  mkdir -p "$D/phases/P1/responses"
  printf '{"checks":{"commands":["t"],"pass":true,"failure":""},"findings":[],"followups":[],"status":"done","questions":[]}\n' \
    >"$D/phases/P1/responses/round-0.json"
  ln -s "$BATS_TEST_TMPDIR/elsewhere.md" "$D/report.md"
  run orca objective phase-done "$D" P1 "$(git -C "$R/main" rev-parse HEAD)"
  assert_fail_reason WRITE_ERROR
  refute_line 'rc=0'
  grep -qx '\*\*State:\*\* active' "$D/phases.md"
  run orca objective phase-block "$D" P1 D1
  assert_fail_reason WRITE_ERROR
  grep -qx '\*\*State:\*\* active' "$D/phases.md"
  rm "$D/report.md"
}

@test "ids: phase-add gives the next id, and a phase directory keeps its id taken" {
  new_objective alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  block "$BATS_TEST_TMPDIR/p.md" P9 pending 'Fresh' none loop
  run orca objective phase-add "$D" "$BATS_TEST_TMPDIR/p.md"
  [ "$status" -eq 0 ]
  [ "$(frame_value phase)" = P2 ]
  grep -qx '## P2 — Fresh' "$D/phases.md"
  ! grep -q '^## P9' "$D/phases.md" || return 1
  # a phase directory left behind counts
  mkdir -p "$D/phases/P7" "$D/plan"
  P="$D/plan/proposed.md"
  cp "$D/phases.md" "$P"
  block "$P" P3 pending 'Behind a directory' none
  run orca objective plan-accept "$D" --check
  assert_fail_reason PLAN_BAD_ID
  [[ "$output" == *'the next id is P8'* ]] || return 1
}

@test "plan-accept: dropping an attempted phase whose work may remain is PLAN_DROPS_WORK; reverted, it passes" {
  new_objective alpha
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  local W="$R/orca-alpha" base
  decision D1 decided 'Per key?'
  decision D2 decided 'Drop the store?'
  phase P1 blocked 'Store' D2
  mkdir -p "$D/phases/P1"
  base="$(git -C "$W" rev-parse HEAD)"
  printf '%s\n' "$base" >"$D/phases/P1/base"
  mkdir -p "$D/plan"
  P="$D/plan/proposed.md"
  printf '# Phases\n' >"$P"
  block "$P" P2 pending 'Something else' D1
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  # left uncommitted in the worktree
  echo half >"$W/store.txt"
  run orca objective plan-accept "$D"
  refused PLAN_DROPS_WORK
  [[ "$output" == *'uncommitted changes'* ]] || return 1
  # salvaged into a commit past its base (an archive and undo)
  git -C "$W" add -A && git -C "$W" commit -qm 'wip: alpha — set aside, partial work'
  run orca objective plan-accept "$D"
  refused PLAN_DROPS_WORK
  [[ "$output" == *'moved past its base'* ]] || return 1
  # --check refuses the same way
  run orca objective plan-accept "$D" --check
  assert_fail_reason PLAN_DROPS_WORK
  # reverted: the branch back at its base, the tree clean
  git -C "$W" reset -q --hard "$base"
  run orca objective plan-accept "$D"
  [ "$status" -eq 0 ]
  ! grep -q '^## P1' "$D/phases.md"
}

@test "phase-start: a pending phase behind a blocked one, or with a decision open, does not start; an active one resumes" {
  new_objective alpha
  decision D1 decided 'Per key?'
  decision D2 deferred 'Which store?'
  phase P1 blocked 'Store' D2
  phase P2 pending 'Middleware'
  run orca objective phase-start "$D" P2
  assert_fail_reason PHASE_BLOCKED
  [[ "$output" == *'P1 on D2'* ]] || return 1
  grep -qx '\*\*State:\*\* pending' "$D/phases.md"
  [ ! -e "$D/phases/P2" ] && [ ! -e "$R/orca-alpha" ]
  # /orca:loop's shortcut is refused the same way
  block "$BATS_TEST_TMPDIR/p3.md" P3 pending 'Loop fix' none loop
  run orca objective phase-add "$D" "$BATS_TEST_TMPDIR/p3.md"
  assert_fail_reason PHASE_BLOCKED
  ! grep -q '^## P3' "$D/phases.md"
  # even once the decision is decided: the plan is redone first
  sed -i.bak 's/^\*\*State:\*\* deferred$/**State:** decided/' "$D/decisions.md"
  run orca objective phase-start "$D" P2
  assert_fail_reason PHASE_BLOCKED
  # an open decision stops a new phase too
  sed -i.bak 's/^\*\*State:\*\* blocked$/**State:** done/' "$D/phases.md"
  decision D3 open 'Bursts?'
  run orca objective phase-start "$D" P2
  assert_fail_reason DECISION_OPEN
  # but an active phase resumes
  sed -i.bak '/^## P2 — /,/^\*\*Acceptance/ s/^\*\*State:\*\* pending$/**State:** active/' "$D/phases.md"
  run orca objective phase-start "$D" P2
  [ "$status" -eq 0 ]
  [ "$(frame_value started)" = no ]
}

@test "phase-start: a done or blocked phase, another active one, or an unknown id is refused, nothing written" {
  new_objective alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  phase P2 blocked 'Store' D1
  phase P3 active 'Middleware'
  phase P4 pending 'Docs'
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  run orca objective phase-start "$D" P1
  assert_fail_reason PHASE_STATE
  run orca objective phase-start "$D" P2
  assert_fail_reason PHASE_STATE
  run orca objective phase-start "$D" P4
  assert_fail_reason PHASE_ACTIVE
  run orca objective phase-start "$D" P9
  assert_fail_reason NO_PHASE
  run orca objective phase-start "$D" 4
  assert_fail_reason BAD_ARGS
  cmp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  [ ! -e "$D/phases" ]
  [ ! -e "$R/orca-alpha" ]
}

# ---- phase-done and phase-block -------------------------------------------

# review <P> <N> <findings-json-array> / response <P> <N> <pass> <commands>
# <findings> <followups> — one round file in $D/phases/<P>.
review() {
  mkdir -p "$D/phases/$1/reviews"
  printf '{"findings":%s}\n' "$3" >"$D/phases/$1/reviews/round-$2.json"
}
response() {
  mkdir -p "$D/phases/$1/responses"
  printf '{"status":"done","questions":[],"checks":{"commands":%s,"pass":%s,"failure":"%s"},"findings":%s,"followups":%s}\n' \
    "$4" "$3" "$([ "$3" = true ] || printf red)" "$5" "$6" >"$D/phases/$1/responses/round-$2.json"
}
finding() { # <severity> <file> <title> [fix_location]
  printf '{"severity":"%s","file":"%s","line":1,"title":"%s","body":"BODY-TEXT","fix_location":"%s"}' \
    "$1" "$2" "$3" "${4:-local code}"
}
disposition() { # <title> <file> <outcome> <reason>
  printf '{"title":"%s","file":"%s","outcome":"%s","reason":"%s"}' "$1" "$2" "$3" "$4"
}

# two_rounds <P> — a phase reviewed twice: round 1 a High (fixed), a
# Medium (declined), a Low (settled by a ruling), an out-of-scope High;
# round 2 a Low fixed after it and the out-of-scope High again; one gap.
two_rounds() {
  response "$1" 0 true '["make test"]' '[]' '[]'
  review "$1" 1 "[$(finding High a.c 'Crash on empty'),$(finding Medium b.c 'Slow path'),$(finding Low c.c 'Naming'),$(finding High old.c 'Old bug' 'another work item')]"
  response "$1" 1 true '["make test"]' \
    "[$(disposition 'Crash on empty' a.c fixed guarded),$(disposition 'Slow path' b.c declined 'not hot'),$(disposition Naming c.c disputed 'fine as is'),$(disposition 'Old bug' old.c out_of_scope pre-existing)]" \
    '[{"title":"CRLF input","file":null,"why":"the brief names LF only"}]'
  printf -- '- Naming\t· c.c\t— declined: the user keeps the name\n' >"$D/phases/$1/declines.md"
  review "$1" 2 "[$(finding Low d.c Typo),$(finding High old.c 'Old bug' 'another work item')]"
  response "$1" 2 true '["make test","make lint"]' \
    "[$(disposition Typo d.c fixed fixed),$(disposition 'Old bug' old.c out_of_scope pre-existing)]" \
    '[{"title":"CRLF input","file":null,"why":"the brief names LF only"}]'
}

# clean_round <P> [pass] — one clean review, checks as given.
clean_round() {
  response "$1" 0 "${2:-true}" '["make test"]' '[]' '[]'
  review "$1" 1 '[]'
}

active_objective() { # an objective with D1 decided and P1 active; reviewer pinned
  new_objective alpha
  printf 'reviewer=claude\n' >"$R/.orca/config"
  decision D1 decided 'Per key?'
  phase P1 active 'Token bucket'
  SHA="$(git -C "$R" rev-parse main)"
}

@test "phase-done: renders the entry, follow-ups, and the report skeleton from the phase files" {
  active_objective
  two_rounds P1
  run orca objective phase-done "$D" P1 main
  [ "$status" -eq 0 ]
  [ "$(frame_value commit)" = "$SHA" ]
  [ "$(frame_value headline.b64 | base64 --decode)" = "P1 — Token bucket — ${SHA:0:7}" ]
  [ "$(frame_value followups_added)" = 3 ]
  [ "$(frame_value deliverable_state)" = verified ]
  grep -qx "\*\*Commit:\*\* $SHA" "$D/phases.md"
  grep -qx '\*\*State:\*\* done' "$D/phases.md"
  local want
  want="# Report: alpha

**Deliverable:** \`feature/alpha\`
**Deliverable state:** verified

## Phases

### P1 — Token bucket — ${SHA:0:7}
- Decisions: D1
- Review: claude, 2 rounds, Critical/High fixed 1
- Fixed after the last review: Typo
- Declined: Naming — the user keeps the name
- Follow-ups: F1, F2, F3
- Checks: pass — make test, make lint

## Blocked

None

## Follow-ups

- F1 · P1 · out of scope · Old bug — old.c
- F2 · P1 · left unfixed (Medium) · Slow path — not hot
- F3 · P1 · gap · CRLF input — the brief names LF only

## Landing

git merge --no-ff feature/alpha"
  if [ "$(cat "$D/report.md")" != "$want" ]; then
    printf 'expected:\n%s\nactual:\n%s\n' "$want" "$(cat "$D/report.md")" >&2
    return 1
  fi
  ! grep -q BODY-TEXT "$D/report.md" || return 1
  state_is verify
  [ "$(list_line | cut -f8)" = followups:3 ]
}

@test "phase-done: a follow-up repeated by a later phase keeps its id; ids are never reused" {
  active_objective
  two_rounds P1
  run orca objective phase-done "$D" P1 main
  [ "$status" -eq 0 ]
  # the user prunes F3 from the report by hand; F3 is still never given again
  sed -i.bak '/^- F3 /d' "$D/report.md"
  phase P2 active 'Middleware'
  response P2 0 true '["make test"]' '[]' '[]'
  review P2 1 "[$(finding High old.c 'Old bug' 'another work item'),$(finding Medium x.c 'New thing' 'another work item')]"
  response P2 1 true '["make test"]' \
    "[$(disposition 'Old bug' old.c out_of_scope again),$(disposition 'New thing' x.c out_of_scope new)]" \
    '[{"title":"CRLF input","file":"io.c","why":"a different file"}]'
  run orca objective phase-done "$D" P2 main
  [ "$status" -eq 0 ]
  [ "$(frame_value followups_added)" = 2 ]
  grep -qx -- '- Follow-ups: F1, F4, F5' "$D/report.md"
  [ "$(grep -c '^- F1 ' "$D/report.md")" = 1 ]
  grep -qx -- '- F4 · P2 · out of scope · New thing — x.c' "$D/report.md"
  grep -qx -- '- F5 · P2 · gap · CRLF input — a different file' "$D/report.md"
  ! grep -q '^- F3 ' "$D/report.md" || return 1
  [ "$(cut -f1 "$D/followups" | tr '\n' ' ')" = 'F1 F2 F3 F4 F5 ' ]
  # entries stay in order under ## Phases
  [ "$(grep '^### ' "$D/report.md" | cut -c5-6 | tr '\n' ' ')" = 'P1 P2 ' ]
}

@test "phase-done: the deliverable state only goes down" {
  active_objective
  clean_round P1 false
  run orca objective phase-done "$D" P1 main
  [ "$status" -eq 0 ]
  [ "$(frame_value deliverable_state)" = unverified ]
  grep -qx -- '- Checks: fail — make test' "$D/report.md"
  local downgraded="**Deliverable state:** unverified — P1 (${SHA:0:7}) committed with checks failing"
  grep -qxF "$downgraded" "$D/report.md"
  # a later clean phase never upgrades it, nor rewrites the reason
  phase P2 active 'Middleware'
  clean_round P2
  run orca objective phase-done "$D" P2 main
  [ "$status" -eq 0 ]
  [ "$(frame_value deliverable_state)" = unverified ]
  grep -qxF "$downgraded" "$D/report.md"
  [ "$(grep -c '^\*\*Deliverable state:\*\*' "$D/report.md")" = 1 ]
}

@test "phase-done: gating findings left in the last review, or no review at all, downgrade" {
  active_objective
  response P1 0 true '["make test"]' '[]' '[]'
  review P1 1 "[$(finding Critical a.c 'Data loss')]"
  run orca objective phase-done "$D" P1 main
  [ "$status" -eq 0 ]
  [ "$(frame_value deliverable_state)" = unverified ]
  grep -q '^\*\*Deliverable state:\*\* unverified — P1 .* committed with Critical/High findings unresolved$' "$D/report.md"
  new_objective beta
  printf 'reviewer=claude\n' >"$R/.orca/config"
  phase P1 active 'Unreviewed'
  response P1 0 true '[]' '[]' '[]'
  run orca objective phase-done "$D" P1 main
  [ "$status" -eq 0 ]
  grep -q '^\*\*Deliverable state:\*\* unverified — P1 .* committed unreviewed$' "$D/report.md"
  grep -qx -- '- Review: claude, 0 rounds, Critical/High fixed 0' "$D/report.md"
  grep -qx -- '- Checks: pass' "$D/report.md"
  grep -qx -- '- Decisions: D1' "$D/report.md"
}

@test "phase-done: a phase not active, a bad sha, missing or malformed rounds fail typed with nothing written" {
  active_objective
  phase P2 pending 'Later'
  cp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  run orca objective phase-done "$D" P2 main
  assert_fail_reason PHASE_STATE
  run orca objective phase-done "$D" P1 no-such-ref
  assert_fail_reason BAD_REF
  run orca objective phase-done "$D" P1 main
  assert_fail_reason BAD_ROUNDS
  clean_round P1
  printf '{"findings":[' >"$D/phases/P1/reviews/round-1.json"
  run orca objective phase-done "$D" P1 main
  assert_fail_reason BAD_JSON
  review P1 1 '[]'
  printf '{"findings":[]}' >"$D/phases/P1/responses/round-0.json"
  run orca objective phase-done "$D" P1 main
  assert_fail_reason BAD_JSON
  cmp "$D/phases.md" "$BATS_TEST_TMPDIR/phases.before"
  [ ! -e "$D/report.md" ]
  [ ! -e "$D/followups" ]
}

@test "phase-block: active to blocked on a decision, the report's Blocked section says so" {
  active_objective
  phase P2 pending 'Middleware'
  phase P3 pending 'Docs'
  decision D2 open 'Which store?' 'P1 (implementer question)'
  run orca objective phase-block "$D" P1 D2
  [ "$status" -eq 0 ]
  [ "$(frame_value blocked_on)" = D2 ]
  [ "$(frame_value waiting)" = 2 ]
  grep -qx '\*\*State:\*\* blocked' "$D/phases.md"
  grep -qx '\*\*Blocked on:\*\* D2' "$D/phases.md"
  [ "$(sed -n '/^## Blocked$/,/^## /p' "$D/report.md" | sed -n 3p)" = 'P1 — waiting on D2: Which store?' ]
  grep -qx '\*\*Deliverable state:\*\* verified' "$D/report.md"
  state_is blocked
  [ "$(list_line | cut -f6-7)" = $'pending:2\tblocked:1' ]
  run orca objective phase-block "$D" P1 D2
  assert_fail_reason PHASE_STATE
  phase P4 active 'Another'
  run orca objective phase-block "$D" P4 D9
  assert_fail_reason NO_DECISION
  run orca objective phase-block "$D" P4 decision
  assert_fail_reason BAD_ARGS
}

# ---- verify-done ----------------------------------------------------------

@test "verify-done: a pass after the last phase ends the verify state until a phase is added" {
  new_objective alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  printf '# Report: alpha\n\n**Deliverable:** `feature/alpha`\n**Deliverable state:** verified\n\n## Phases\n\n### P1 — Bucket — 0123456\n- Checks: pass\n\n## Blocked\n\nNone\n\n## Follow-ups\n\nNone\n\n## Landing\n\ngit merge --no-ff feature/alpha\n' >"$D/report.md"
  state_is verify
  local tip
  tip="$(git -C "$R" rev-parse feature/alpha)"
  run orca objective verify-done "$D" pass
  [ "$status" -eq 0 ]
  [ "$(frame_value result)" = pass ]
  [ "$(frame_value phase)" = P1 ]
  [ "$(frame_value tip)" = "$tip" ]
  [ "$(frame_value deliverable_state)" = verified ]
  # the line sits right after the deliverable state; nothing else moves
  [ "$(sed -n 4,5p "$D/report.md")" = "**Deliverable state:** verified
**Final verification:** pass after P1 (${tip:0:7})" ]
  grep -qx '### P1 — Bucket — 0123456' "$D/report.md"
  state_is idle
  run orca objective digest "$D"
  [[ "$output" == *"Final verification: pass after P1 (${tip:0:7})"* ]] || return 1
  # a phase added after it makes the record stale
  phase P2 done 'Fix'
  state_is verify
  run orca objective verify-done "$D" pass
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\*\*Final verification:\*\*' "$D/report.md")" = 1 ]
  grep -qx "\*\*Final verification:\*\* pass after P2 (${tip:0:7})" "$D/report.md"
  state_is idle
}

@test "verify-done: a fail names why, turns the deliverable unverified, and ends the verify state" {
  new_objective alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  local tip
  tip="$(git -C "$R" rev-parse feature/alpha)"
  run orca objective verify-done "$D" fail
  assert_fail_reason BAD_ARGS
  [ ! -e "$D/report.md" ]
  run orca objective verify-done "$D" pass 'no reason wanted'
  assert_fail_reason BAD_ARGS
  run orca objective verify-done "$D" maybe
  assert_fail_reason BAD_ARGS
  run orca objective verify-done "$D" fail 'make test: 2 failing in bucket_test'
  [ "$status" -eq 0 ]
  [ "$(frame_value deliverable_state)" = unverified ]
  grep -qx "\*\*Deliverable state:\*\* unverified — final verification failed after P1 (${tip:0:7}): make test: 2 failing in bucket_test" "$D/report.md"
  grep -qx "\*\*Final verification:\*\* fail after P1 (${tip:0:7}) — make test: 2 failing in bucket_test" "$D/report.md"
  state_is idle
  # a later pass never raises the state again
  run orca objective verify-done "$D" pass
  [ "$status" -eq 0 ]
  [ "$(frame_value deliverable_state)" = unverified ]
  grep -q '^\*\*Deliverable state:\*\* unverified — final verification failed' "$D/report.md"
}

@test "verify-done: refused before every phase is done, with no phase, and on an archived objective" {
  new_objective alpha
  run orca objective verify-done "$D" pass
  assert_fail_reason NO_PHASE
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  phase P2 pending 'Middleware'
  run orca objective verify-done "$D" pass
  assert_fail_reason PHASE_STATE
  [ ! -e "$D/report.md" ]
  sed -i.bak 's/^\*\*State:\*\* pending$/**State:** done/' "$D/phases.md"
  printf 'state=abandoned\n' >"$D/archived"
  run orca objective verify-done "$D" pass
  assert_fail_reason ARCHIVED
}

@test "phase subcommands refuse an archived objective" {
  active_objective
  printf 'state=abandoned\n' >"$D/archived"
  run orca objective phase-done "$D" P1 main
  assert_fail_reason ARCHIVED
  run orca objective phase-start "$D" P1
  assert_fail_reason ARCHIVED
  run orca objective phase-block "$D" P1 D1
  assert_fail_reason ARCHIVED
  run orca objective plan-accept "$D" --check
  assert_fail_reason ARCHIVED
  run orca objective phase-add "$D" "$D/phases.md"
  assert_fail_reason ARCHIVED
}

# ---- archive and unarchive --------------------------------------------

# opened <slug> — `objective new`, then `open`: the worktree and branch exist.
opened() {
  new_objective "$1"
  run orca objective open "$D"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  W="$R/orca-$1"
}

commit_in() { # <worktree> <file> — one commit adding <file>
  echo "$2" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "add $2"
}

@test "untracked files count as uncommitted work even with status.showUntrackedFiles=no: digest, archive, and a phase drop" {
  opened alpha
  git -C "$R/main" config status.showUntrackedFiles no
  # landed: one commit on the branch, merged into the trunk
  commit_in "$W" done.txt
  git -C "$R/main" merge -q --no-ff -m 'land alpha' feature/alpha
  echo new >"$W/only-untracked.txt"
  [ -z "$(git -C "$W" status --porcelain)" ]
  run orca objective digest "$D"
  printf '%s\n' "$output" | grep -qx "Worktree: $W (dirty)"
  # not landed while the untracked file is there
  run orca objective archive "$D"
  assert_fail_reason NOT_LANDED
  [[ "$output" == *'uncommitted changes'* ]] || return 1
  [ -f "$W/only-untracked.txt" ] && [ ! -e "$D/archived" ]
  # nor droppable from a plan while an attempted phase's file remains
  decision D1 decided 'Per key?'
  decision D2 decided 'Drop the store?'
  phase P1 blocked 'Store' D2
  mkdir -p "$D/phases/P1"
  git -C "$W" rev-parse HEAD >"$D/phases/P1/base"
  mkdir -p "$D/plan"
  printf '# Phases\n' >"$D/plan/proposed.md"
  block "$D/plan/proposed.md" P2 pending 'Other' D1
  run orca objective plan-accept "$D" --check
  assert_fail_reason PLAN_DROPS_WORK
}

@test "archive: a landed objective loses its worktree and branch, keeps its directory and tip; a re-run is a no-op" {
  opened alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  commit_in "$W" work.txt
  git -C "$R/main" merge -q --no-ff -m 'land alpha' feature/alpha
  state_is landed
  local tip
  tip="$(git -C "$W" rev-parse HEAD)"
  run orca objective archive "$D" --note 'shipped in 2.0'
  [ "$status" -eq 0 ]
  [ "$(frame_value state)" = landed ]
  [ "$(frame_value tip)" = "$tip" ]
  [ "$(frame_value ref)" = refs/orca/archive/alpha ]
  [ "$(frame_value salvaged)" = clean ]
  [ "$(frame_value worktree)" = removed ]
  [ "$(frame_value branch)" = removed ]
  [ "$(frame_value already)" = no ]
  [ ! -e "$W" ]
  ! git -C "$R/main" rev-parse -q --verify refs/heads/feature/alpha
  [ "$(git -C "$R/main" rev-parse refs/orca/archive/alpha)" = "$tip" ]
  [ ! -e "$D/owner" ]
  [ -f "$D/objective.md" ] && [ -f "$D/phases.md" ]
  grep -qx 'state=landed' "$D/archived"
  grep -qx "tip=$tip" "$D/archived"
  grep -qx 'note=shipped in 2.0' "$D/archived"
  grep -qE '^date=[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$D/archived"
  state_is archived
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  [ "$(frame_value already)" = yes ]
  [ "$(frame_value state)" = archived ]
  grep -qx 'state=landed' "$D/archived"
}

@test "archive: an unlanded objective needs --abandon; abandoning salvages the dirty tree and the tip survives gc" {
  opened alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  phase P2 active 'Middleware'
  commit_in "$W" done.txt
  echo half >"$W/half.txt"
  echo edit >>"$W/done.txt"
  run orca objective archive "$D"
  assert_fail_reason NOT_LANDED
  [[ "$output" == *'uncommitted changes'* ]] || return 1
  [ -d "$W" ] && [ -f "$D/owner" ] && [ ! -e "$D/archived" ]
  [ -f "$W/half.txt" ]
  run orca objective archive "$D" --abandon --note $'not needed\tafter all'
  [ "$status" -eq 0 ]
  [ "$(frame_value state)" = abandoned ]
  [ "$(frame_value salvaged)" = committed ]
  local tip
  tip="$(frame_value tip)"
  [ "$(git -C "$R/main" log -1 --format=%s "$tip")" = 'wip: alpha — set aside, partial work' ]
  [ "$(git -C "$R/main" show "$tip:half.txt")" = half ]
  [ "$(git -C "$R/main" show "$tip:done.txt" | tail -1)" = edit ]
  [ ! -e "$W" ]
  ! git -C "$R/main" rev-parse -q --verify refs/heads/feature/alpha
  [ ! -e "$D/owner" ]
  grep -qx 'state=abandoned' "$D/archived"
  grep -qx 'note=not needed after all' "$D/archived"
  state_is abandoned
  # nothing but the hidden ref holds the work now
  git -C "$R/main" reflog expire --expire=now --all
  git -C "$R/main" gc -q --prune=now
  git -C "$R/main" cat-file -e "$tip^{commit}"
  [ "$(git -C "$R/main" rev-parse refs/orca/archive/alpha)" = "$tip" ]
  ! git -C "$R/main" branch --list | grep -q alpha
  run orca objective open "$D"
  assert_fail_reason ARCHIVED
}

@test "archive and unarchive: an active phase's salvaged work stays in its diff against the recorded base" {
  opened alpha
  decision D1 decided 'Per key?'
  phase P1 pending 'Bucket'
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  local base
  base="$(frame_value base)"
  echo built >"$W/feature.txt"
  echo edit >>"$W/README" 2>/dev/null || echo edit >"$W/README"
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  [ "$(frame_value salvaged)" = committed ]
  run orca objective unarchive "$D"
  [ "$status" -eq 0 ]
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  [ "$(frame_value started)" = no ]
  [ "$(frame_value base_kept)" = yes ]
  [ "$(frame_value base)" = "$base" ]
  # The wip commit hides the work from a diff against HEAD, never from
  # one against the phase's base — the subject the reviewers read.
  [ -z "$(git -C "$W" diff HEAD)" ]
  [ "$(git -C "$W" log -1 --format=%s)" = 'wip: alpha — set aside, partial work' ]
  git -C "$W" diff "$base" --name-only | grep -qx feature.txt
  git -C "$W" diff "$base" --name-only | grep -qx README
}

@test "archive: work salvaged outside any phase turns a verified report unverified, and the restore keeps it so" {
  opened alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  commit_in "$W" done.txt
  printf '# Report: alpha\n\n**Deliverable:** `feature/alpha`\n**Deliverable state:** verified\n\n## Phases\n\n### P1 — Bucket — 0123456\n- Checks: pass\n\n## Blocked\n\nNone\n\n## Follow-ups\n\nNone\n\n## Landing\n\ngit merge --no-ff feature/alpha\n' >"$D/report.md"
  # edits after the last phase, never checked or reviewed
  echo unreviewed >"$W/extra.txt"
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  [ "$(frame_value salvaged)" = committed ]
  grep -qx '\*\*Deliverable state:\*\* unverified — uncommitted work set aside by archive outside any phase, never checked or reviewed' "$D/report.md"
  grep -qx '### P1 — Bucket — 0123456' "$D/report.md"
  run orca objective unarchive "$D"
  [ "$status" -eq 0 ]
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  [ "$(cat "$W/extra.txt")" = unreviewed ]
  # what /orca:pr gates on still says unverified
  grep -q '^\*\*Deliverable state:\*\* unverified' "$D/report.md"
  grep -qF '**`**Deliverable state:**` is not `verified`** → refuse' "$ORCA_ROOT/skills/pr/SKILL.md"
}

@test "archive: work salvaged under an unfinished phase with a base leaves the report alone; a never-phased one gets an unverified report" {
  opened alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  phase P2 pending 'Middleware'
  printf '# Report: alpha\n\n**Deliverable:** `feature/alpha`\n**Deliverable state:** verified\n\n## Phases\n\n## Blocked\n\nNone\n\n## Follow-ups\n\nNone\n\n## Landing\n\ngit merge --no-ff feature/alpha\n' >"$D/report.md"
  run orca objective phase-start "$D" P2
  [ "$status" -eq 0 ]
  echo half >"$W/half.txt"
  cp "$D/report.md" "$BATS_TEST_TMPDIR/report.before"
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  [ "$(frame_value salvaged)" = committed ]
  cmp "$D/report.md" "$BATS_TEST_TMPDIR/report.before"
  # a never-phased objective with salvaged work gets a report saying so
  new_objective beta
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  echo early >"$R/orca-beta/early.txt"
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  grep -q '^\*\*Deliverable state:\*\* unverified — uncommitted work set aside by archive' "$D/report.md"
}

@test "review discover names an objective's branch from objective.md after archive and undo, with no report; the address gate then holds" {
  opened alpha
  decision D1 decided 'Per key?'
  phase P1 pending 'Bucket'
  run orca objective phase-start "$D" P1
  [ "$status" -eq 0 ]
  echo half >"$W/half.txt"
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  [ ! -e "$D/report.md" ]
  run orca objective unarchive "$D"
  [ "$status" -eq 0 ]
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  [ ! -e "$D/report.md" ]
  # a run's stale report naming the same branch never speaks for it
  mkdir -p "$R/.orca/20250101-1200-feat-alpha"
  printf '# Report: x\n\n**Deliverable:** `feature/alpha`\n**Deliverable state:** verified\n' >"$R/.orca/20250101-1200-feat-alpha/report.md"
  cd "$R/main"
  run orca review discover
  [ "$status" -eq 0 ]
  has_line $'DELIVERABLE:\tfeature/alpha\t'"$W"$'\tok'
  has_line $'OBJECTIVE_DIR:\t'"$D"
  refute_line 'REPORT:'
  [ "$(printf '%s\n' "$output" | grep -A1 '^DELIVERABLE:' | sed -n 2p | cut -f1)" = OBJECTIVE_DIR: ]
  # the gate the address flow runs on that line
  run orca objective idle "$D"
  assert_fail_reason PHASE_ACTIVE
  CLAUDE_CODE_SESSION_ID=sess-other run orca objective idle "$D"
  assert_fail_reason NOT_OWNER
  # archived, the objective no longer names the branch
  cd "$R"
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  git -C "$R/main" branch feature/alpha main
  cd "$R/main"
  run orca review discover
  refute_line $'OBJECTIVE_DIR:\t'"$D"
}

@test "archive interrupted after the branch is gone: open refuses, a re-run finishes from the marker, undo restores the tip" {
  opened alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  commit_in "$W" done.txt
  local tip
  tip="$(git -C "$W" rev-parse HEAD)"
  # the final marker cannot be written: the archive stops after removing
  # the worktree and deleting the branch
  ln -s "$BATS_TEST_TMPDIR/nowhere" "$D/archived"
  run orca objective archive "$D" --abandon --note 'not now'
  assert_fail_reason WRITE_ERROR
  [ ! -e "$W" ]
  ! git -C "$R/main" rev-parse -q --verify refs/heads/feature/alpha
  [ "$(git -C "$R/main" rev-parse refs/orca/archive/alpha)" = "$tip" ]
  grep -qx 'state=abandoned' "$D/archiving"
  grep -qx "tip=$tip" "$D/archiving"
  rm "$D/archived"
  # nothing reopens it at the old base meanwhile
  run orca objective open "$D"
  assert_fail_reason ARCHIVED
  [[ "$output" == *'did not finish'* ]] || return 1
  ! git -C "$R/main" rev-parse -q --verify refs/heads/feature/alpha
  run orca objective phase-start "$D" P1
  assert_fail_reason ARCHIVED
  state_is abandoned
  run orca objective list "$R"
  refute_line $'OBJECTIVE:\t'"$D"
  # a re-run finishes from the marker, without judging landed again
  run orca objective archive "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value state)" = abandoned ]
  [ "$(frame_value tip)" = "$tip" ]
  [ "$(frame_value salvaged)" = resumed ]
  [ -f "$D/archived" ] && [ ! -e "$D/archiving" ]
  grep -qx 'note=not now' "$D/archived"
  run orca objective unarchive "$D"
  [ "$status" -eq 0 ]
  [ "$(git -C "$R/main" rev-parse refs/heads/feature/alpha)" = "$tip" ]
}

@test "archive interrupted before the worktree went: the re-run salvages new edits and keeps the new tip; undo works straight from the marker" {
  opened alpha
  decision D1 decided 'Per key?'
  phase P1 done 'Bucket'
  commit_in "$W" done.txt
  local tip
  tip="$(git -C "$W" rev-parse HEAD)"
  # as an archive that wrote its decision and stopped
  git -C "$R/main" update-ref refs/orca/archive/alpha "$tip"
  printf 'state=abandoned\ndate=d\ntip=%s\nnote=\n' "$tip" >"$D/archiving"
  echo after >"$W/after.txt"
  run orca objective archive "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value salvaged)" = committed ]
  local newtip
  newtip="$(frame_value tip)"
  [ "$newtip" != "$tip" ]
  [ "$(git -C "$R/main" rev-parse refs/orca/archive/alpha)" = "$newtip" ]
  [ "$(git -C "$R/main" show "$newtip:after.txt")" = after ]
  grep -qx "tip=$newtip" "$D/archived"
  # an interrupted archive can be undone directly too
  run orca objective unarchive "$D"
  [ "$status" -eq 0 ]
  opened beta
  commit_in "$W" b.txt
  git -C "$R/main" update-ref refs/orca/archive/beta "$(git -C "$W" rev-parse HEAD)"
  printf 'state=abandoned\ndate=d\ntip=%s\nnote=\n' "$(git -C "$W" rev-parse HEAD)" >"$D/archiving"
  run orca objective unarchive "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value restored)" = yes ]
  [ "$(frame_value branch)" = exists ]
  [ ! -e "$D/archiving" ]
  run orca objective open "$D"
  [ "$status" -eq 0 ]
}

@test "unarchive: the branch comes back at the kept tip, the marker and ref go, and open resumes on it" {
  opened alpha
  decision D1 decided 'Per key?'
  phase P1 pending 'Bucket'
  commit_in "$W" done.txt
  echo half >"$W/half.txt"
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  local tip
  tip="$(frame_value tip)"
  run orca objective unarchive "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value restored)" = yes ]
  [ "$(frame_value branch)" = restored ]
  [ "$(frame_value tip)" = "$tip" ]
  [ "$(git -C "$R/main" rev-parse refs/heads/feature/alpha)" = "$tip" ]
  [ ! -e "$D/archived" ]
  ! git -C "$R/main" rev-parse -q --verify refs/orca/archive/alpha
  state_is ready
  run orca objective open "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value arrival)" = branch_resumed ]
  [ "$(cat "$W/half.txt")" = half ]
  # a second undo has nothing to do
  run orca objective unarchive "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value restored)" = no ]
}

@test "unarchive: a branch recreated at another commit is BRANCH_EXISTS; at the kept tip it is kept; no tip restores the marker alone" {
  opened alpha
  commit_in "$W" done.txt
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  local tip
  tip="$(frame_value tip)"
  git -C "$R/main" branch feature/alpha main
  run orca objective unarchive "$D"
  assert_fail_reason BRANCH_EXISTS
  [ -f "$D/archived" ]
  git -C "$R/main" branch -f feature/alpha "$tip"
  run orca objective unarchive "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value branch)" = exists ]
  [ ! -e "$D/archived" ]
  # no branch (deleted by hand) and no worktree — abandoned with tip -, restored as such
  new_objective beta
  git -C "$R/main" branch -D feature/beta >/dev/null
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  [ "$(frame_value tip)" = - ]
  [ "$(frame_value ref)" = - ]
  [ "$(frame_value salvaged)" = no-worktree ]
  [ "$(frame_value worktree)" = absent ]
  [ "$(frame_value branch)" = absent ]
  grep -qx 'tip=-' "$D/archived"
  run orca objective unarchive "$D"
  [ "$status" -eq 0 ]
  [ "$(frame_value branch)" = none ]
  [ ! -e "$D/archived" ]
  # a lost tip with no ref is refused, nothing restored
  run orca objective archive "$D" --abandon
  sed -i.bak 's/^tip=-$/tip=0123456789abcdef0123456789abcdef01234567/' "$D/archived"
  run orca objective unarchive "$D"
  assert_fail_reason NO_ARCHIVE
  [ -f "$D/archived" ]
}

@test "archive: refused while another live session owns it, inside the worktree, or on bad arguments; a stale owner passes" {
  opened alpha
  SPID="$( (sleep 60 >/dev/null 2>&1 & echo $!) )"
  write_owner "$D" sess-other "$SPID" "$(ps -o lstart= -p "$SPID")"
  run orca objective archive "$D" --abandon
  assert_fail_reason OWNED_ELSEWHERE
  [ -d "$W" ] && [ ! -e "$D/archived" ]
  printf 'session=sess-other\nhost=elsewhere.invalid\npid=1234\npidstart=x\ntaken=t\n' >"$D/owner"
  run orca objective archive "$D" --abandon
  assert_fail_reason OWNED_ELSEWHERE
  run orca objective archive "$D" --abandon --note
  assert_fail_reason BAD_ARGS
  run orca objective archive "$D" --force
  assert_fail_reason BAD_ARGS
  write_owner "$D" sess-other "$$" "not the real lstart"
  ( cd "$W" && bash "$SCRIPTS/orca.sh" objective archive "$D" --abandon ) >"$BATS_TEST_TMPDIR/out" || true
  grep -q $'^FAIL:\tWORKTREE_IN_USE' "$BATS_TEST_TMPDIR/out"
  [ -d "$W" ] && [ ! -e "$D/archived" ]
  git -C "$W" checkout -q --detach
  run orca objective archive "$D" --abandon
  assert_fail_reason WORKTREE_IN_USE
  git -C "$W" checkout -q feature/alpha
  run orca objective archive "$D" --abandon
  [ "$status" -eq 0 ]
  [ "$(frame_value state)" = abandoned ]
}
