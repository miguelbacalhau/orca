#!/usr/bin/env bats
# The relay verbs — worktree-item arrivals, commit-verify's decision
# table, merge-finalize's commit/attribution/ledger/cleanup, and the two
# re-entrancy classes per verb (run-twice after success, and
# mutation-applied-frame-lost-retry).

load helpers

orca() { bash "$SCRIPTS/orca.sh" "$@"; }

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# frame_get <key> — the key's value from the frame in $output.
frame_get() {
  printf '%s\n' "$output" | awk -v k="$1" '
    /^@@ORCA@@$/ { f = 1; next }
    /^@@ORCA_END@@$/ { f = 0 }
    f && index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'
}

frame_msg() { frame_get message.b64 | base64 --decode; }

# make_run_layout <dir> — bare layout plus an integration worktree at
# <dir>/int on feature/x, the shape the work loop runs in.
make_run_layout() {
  make_bare_layout "$1"
  git -C "$1/main" worktree add "$1/int" -b feature/x main >/dev/null 2>&1
}

# add_wt <dir> — item worktree at <dir>/wt1 via the verb itself; sets
# $base to the head sha its frame reported.
add_wt() {
  run orca worktree-item "$1/int" "$1/wt1" feature/x-W1 feature/x
  [ "$status" -eq 0 ]
  base="$(frame_get head)"
  [[ "$base" =~ ^[0-9a-f]{40}$ ]]
}

commit_in() { # <wt> <message>
  echo "change-$RANDOM" >>"$1/work.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
}

# ---- worktree-item -----------------------------------------------------

@test "worktree-item: fresh arrival creates branch and worktree, reports head" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt1" feature/x-W1 feature/x
  [ "$status" -eq 0 ]
  has_line 'arrival=created'
  [ -d "$BATS_TEST_TMPDIR/r/wt1" ]
  git -C "$BATS_TEST_TMPDIR/r/int" rev-parse -q --verify refs/heads/feature/x-W1 >/dev/null
  [ "$(frame_get head)" = "$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)" ]
}

@test "worktree-item: run-twice lands in reused with the same head" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt1" feature/x-W1 feature/x
  [ "$status" -eq 0 ]
  has_line 'arrival=reused'
  [ "$(frame_get head)" = "$base" ]
}

@test "worktree-item: a hand-deleted directory resumes on its branch via prune" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'feat: survives the deletion'
  rm -rf "$BATS_TEST_TMPDIR/r/wt1"
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt1" feature/x-W1 feature/x
  [ "$status" -eq 0 ]
  has_line 'arrival=branch_resumed'
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" log -1 --format=%s)" = 'feat: survives the deletion' ]
}

@test "worktree-item: a persistent ref lock fails typed after the bounded retry" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/r/.bare/refs/heads/feature"
  touch "$BATS_TEST_TMPDIR/r/.bare/refs/heads/feature/x-W9.lock"
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt9" feature/x-W9 feature/x
  assert_fail_reason WORKTREE_FAILED
}

@test "worktree-item: secrets placement rides the arrival" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/secrets"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt1" feature/x-W1 feature/x
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.env'
  [ -L "$BATS_TEST_TMPDIR/r/wt1/.env" ]
  # No .orca/setup: the provisioning half is a clean no-op, and its keys
  # are still in the frame — the loops declare them, and an undeclared key
  # line would be swallowed as a continuation of `head`.
  [ "$(frame_get setup)" = absent ]
  [ "$(frame_get setup_rc)" = '-' ]
}

@test "worktree-item: provisioning rides both arrivals and its failure rides the frame" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/secrets"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  printf 'test -f .env && echo "provisioned $ORCA_ARRIVAL" >>prov.log\n' >"$BATS_TEST_TMPDIR/cand"
  ( cd "$BATS_TEST_TMPDIR/r" &&
    bash "$SCRIPTS/orca.sh" setup install "$BATS_TEST_TMPDIR/cand" --sources - ) >/dev/null

  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt1" feature/x-W1 feature/x
  [ "$status" -eq 0 ]
  has_line 'arrival=created'
  [ "$(frame_get setup)" = ok ]
  [ "$(frame_get setup_stamped)" = yes ]
  [ "$(cat "$BATS_TEST_TMPDIR/r/wt1/prov.log")" = 'provisioned created' ]

  # A re-run is the `reused` arrival, and it provisions again — a resumed
  # worktree may be days stale.
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt1" feature/x-W1 feature/x
  has_line 'arrival=reused'
  [ "$(frame_get setup)" = ok ]
  [ "$(tail -1 "$BATS_TEST_TMPDIR/r/wt1/prov.log")" = 'provisioned reused' ]

  # A failing script is advisory: the arrival still succeeds, with the tail
  # in the frame for the loop to put in the agent's prompt.
  printf 'echo wrecked >&2\nexit 4\n' >"$BATS_TEST_TMPDIR/cand2"
  ( cd "$BATS_TEST_TMPDIR/r" &&
    bash "$SCRIPTS/orca.sh" setup install "$BATS_TEST_TMPDIR/cand2" --sources - ) >/dev/null
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt2" feature/x-W2 feature/x
  [ "$status" -eq 0 ]
  [[ "$(frame_get head)" =~ ^[0-9a-f]{40}$ ]]
  [ "$(frame_get setup)" = failed ]
  [ "$(frame_get setup_rc)" = 4 ]
  [[ "$(frame_get setup_tail.b64 | base64 --decode)" == *wrecked* ]]
}

# ---- commit-verify -----------------------------------------------------

@test "commit-verify: a clean new commit is accepted with hash and message" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'feat: adds a thing'
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'adds a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=accepted'
  [ "$(frame_get hash)" = "$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)" ]
  [ "$(frame_msg)" = 'feat: adds a thing' ]
}

@test "commit-verify: run-twice after accepted converges on the same verdict" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'feat: adds a thing'
  orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'adds a thing')" >/dev/null
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'adds a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=accepted'
  [ "$(frame_msg)" = 'feat: adds a thing' ]
}

@test "commit-verify: a banned span resets soft and reports violation_reset" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'fix: a thing\n\nCo-Authored-By: Claude <noreply@example.com>'
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=violation_reset'
  # HEAD is back at base with the changes still staged
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)" = "$base" ]
  [ -n "$(git -C "$BATS_TEST_TMPDIR/r/wt1" status --porcelain)" ]
}

@test "commit-verify: the retry after a half-run violation_reset reports needs_commit" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'fix: a thing\n\nCo-Authored-By: Claude <noreply@example.com>'
  orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')" >/dev/null
  # the frame was lost; the retry observes reset-but-staged state
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=needs_commit'
}

@test "commit-verify: --final rewrites a still-banned span deterministically" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'fix: a thing\n\nGenerated with a tool'
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')" --final
  [ "$status" -eq 0 ]
  has_line 'action=fallback_rewritten'
  [ "$(frame_msg)" = 'chore: a thing' ]
  run git -C "$BATS_TEST_TMPDIR/r/wt1" log --format=%B "feature/x..HEAD"
  [[ "$output" != *Generated* ]]
}

@test "commit-verify: a banned title falls back to the id-based message" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'fix: x\n\nCo-Authored-By: Claude <noreply@example.com>'
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'teach Claude a trick')" --final
  [ "$status" -eq 0 ]
  has_line 'action=fallback_rewritten'
  [ "$(frame_msg)" = 'chore: complete work item W1' ]
}

@test "commit-verify: an unmoved wip tip is rewritten by amend" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'wip: W1 — blocked, partial work'
  base="$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)"
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=wip_rewritten'
  [ "$(frame_msg)" = 'chore: a thing' ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" log -1 --format=%s)" = 'chore: a thing' ]
  # amend, not squash: only the tip was rewritten
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-list --count feature/x..HEAD)" = '1' ]
}

@test "commit-verify: a prior-run banned span is squashed behind the fallback" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'feat: honest first half'
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'feat: second half\n\nCo-Authored-By: Claude <noreply@example.com>'
  base="$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)"
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=prior_squashed'
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-list --count feature/x..HEAD)" = '1' ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" log -1 --format=%s)" = 'chore: a thing' ]
}

@test "commit-verify: an unmoved clean non-wip tip is nothing-new accepted" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'feat: already committed last round'
  base="$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)"
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=accepted'
  [ "$(frame_get hash)" = "$base" ]
  [ "$(frame_msg)" = 'feat: already committed last round' ]
}

@test "commit-verify: unicode survives the b64 round trip" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'fix: café — naïve\n\nCo-Authored-By: Claude <noreply@example.com>'
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'café — naïve')" --final
  [ "$status" -eq 0 ]
  [ "$(frame_msg)" = 'chore: café — naïve' ]
}

# ---- merge-finalize ----------------------------------------------------

# squash_layout <dir> — layout with one committed item branch; sets
# $tip_before to the integration head and $ledger to the run's ledger
# path. The merge stage squashes, so nothing here is merged yet.
squash_layout() {
  make_run_layout "$1"
  add_wt "$1"
  commit_in "$1/wt1" 'feat: adds a thing'
  tip_before="$(git -C "$1/int" rev-parse HEAD)"
  ledger="$1/.orca/merged.tsv"
}

# do_squash <dir> [message] — what the merge agent does: squash the item
# branch and commit it. With no <message> the item commit's own message
# is reused (`git commit -C`), which is the prescribed path.
do_squash() {
  git -C "$1/int" merge --squash feature/x-W1 -q
  if [ $# -ge 2 ]; then
    git -C "$1/int" commit -q -m "$2"
  else
    git -C "$1/int" commit -q -C feature/x-W1
  fi
}

# finalize <dir> — the verb under test, over the layout's fixed names.
finalize() {
  run orca merge-finalize "$1/int" "$tip_before" W1 \
    --title-b64 "$(b64 'adds a thing')" --wt "$1/wt1" --branch feature/x-W1 \
    --ledger "$ledger"
}

@test "merge-finalize: a committed squash is ledgered, left alone, and cleaned up" {
  squash_layout "$BATS_TEST_TMPDIR/r"
  do_squash "$BATS_TEST_TMPDIR/r"
  finalize "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line 'commit=agent'
  has_line 'attribution=clean'
  has_line 'ledger=written'
  has_line 'cleanup=done'
  # the item's own Conventional message stands, on a single-parent commit:
  # no merge commit, and no run-internal item id anywhere in the subject
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%s)" = 'feat: adds a thing' ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%P | wc -w | tr -d ' ')" = '1' ]
  [ "$(cat "$ledger")" = "W1$(printf '\t')$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse HEAD)" ]
  [ ! -d "$BATS_TEST_TMPDIR/r/wt1" ]
  ! git -C "$BATS_TEST_TMPDIR/r/int" rev-parse -q --verify refs/heads/feature/x-W1 >/dev/null
}

@test "merge-finalize: a squash left staged is committed by the backstop" {
  squash_layout "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r/int" merge --squash feature/x-W1 -q
  finalize "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line 'commit=recovered'
  has_line 'ledger=written'
  has_line 'cleanup=done'
  # recovered with -C <branch>: the item commit's message, not a fallback
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%s)" = 'feat: adds a thing' ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" rev-list --count "$tip_before..HEAD")" = '1' ]
}

@test "merge-finalize: an unresolved conflicted squash lands nothing and keeps the item" {
  squash_layout "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/int" 'feat: conflicting integration work'
  tip_before="$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse HEAD)"
  run git -C "$BATS_TEST_TMPDIR/r/int" merge --squash feature/x-W1
  [ -n "$(git -C "$BATS_TEST_TMPDIR/r/int" ls-files --unmerged)" ]
  finalize "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line 'commit=none'
  has_line 'attribution=unchanged'
  has_line 'ledger=skipped'
  has_line 'cleanup=skipped'
  # nothing landed, so the work must still be reachable for a retry round
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse HEAD)" = "$tip_before" ]
  [ ! -f "$ledger" ]
  [ -d "$BATS_TEST_TMPDIR/r/wt1" ]
  git -C "$BATS_TEST_TMPDIR/r/int" rev-parse -q --verify refs/heads/feature/x-W1 >/dev/null
}

@test "merge-finalize: an unmoved tip over a clean tree lands nothing and keeps the item" {
  squash_layout "$BATS_TEST_TMPDIR/r"
  finalize "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line 'commit=none'
  has_line 'attribution=unchanged'
  has_line 'cleanup=skipped'
  [ -d "$BATS_TEST_TMPDIR/r/wt1" ]
  git -C "$BATS_TEST_TMPDIR/r/int" rev-parse -q --verify refs/heads/feature/x-W1 >/dev/null
}

@test "merge-finalize: a banned tip alone is amended and the ledger follows the rewrite" {
  squash_layout "$BATS_TEST_TMPDIR/r"
  do_squash "$BATS_TEST_TMPDIR/r" $'feat: adds a thing\n\nCo-Authored-By: Claude <noreply@example.com>'
  finalize "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line 'attribution=amended'
  has_line 'ledger=written'
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%s)" = 'chore: adds a thing' ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%B "$tip_before..HEAD" | grep -c Claude)" = '0' ]
  [ "$(cat "$ledger")" = "W1$(printf '\t')$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse HEAD)" ]
}

@test "merge-finalize: a banned message below the tip squashes the span" {
  squash_layout "$BATS_TEST_TMPDIR/r"
  do_squash "$BATS_TEST_TMPDIR/r" $'chore: land it\n\nCo-Authored-By: Claude <noreply@example.com>'
  commit_in "$BATS_TEST_TMPDIR/r/int" 'fix: post-merge touchup'
  finalize "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line 'attribution=squashed'
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" rev-list --count "$tip_before..HEAD")" = '1' ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%s)" = 'chore: adds a thing' ]
  run git -C "$BATS_TEST_TMPDIR/r/int" log --format=%B "$tip_before..HEAD"
  [[ "$output" != *Claude* ]]
}

@test "merge-finalize: run-twice converges and leaves one ledger row" {
  squash_layout "$BATS_TEST_TMPDIR/r"
  do_squash "$BATS_TEST_TMPDIR/r"
  orca merge-finalize "$BATS_TEST_TMPDIR/r/int" "$tip_before" W1 \
    --title-b64 "$(b64 'adds a thing')" --wt "$BATS_TEST_TMPDIR/r/wt1" --branch feature/x-W1 \
    --ledger "$ledger" >/dev/null
  # the frame was lost; the retry observes the committed span and the
  # finished cleanup, and converges instead of replaying
  finalize "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line 'commit=agent'
  has_line 'attribution=clean'
  has_line 'ledger=written'
  has_line 'cleanup=done'
  [ "$(wc -l <"$ledger" | tr -d ' ')" = '1' ]
}

@test "merge-finalize: the ledger rewrites this item's row and keeps the others" {
  squash_layout "$BATS_TEST_TMPDIR/r"
  printf 'W9\t%s\nW1\t%s\n' 0000000000000000000000000000000000000009 \
    0000000000000000000000000000000000000001 >"$ledger"
  do_squash "$BATS_TEST_TMPDIR/r"
  finalize "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line 'ledger=written'
  [ "$(wc -l <"$ledger" | tr -d ' ')" = '2' ]
  grep -q "^W9$(printf '\t')0000000000000000000000000000000000000009$" "$ledger"
  grep -q "^W1$(printf '\t')$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse HEAD)$" "$ledger"
}

@test "verbs fail typed on bad arguments" {
  run orca commit-verify
  assert_fail_reason BAD_ARGS
  run orca merge-finalize /nonexistent 0000000000000000000000000000000000000000 W1 \
    --title-b64 "$(b64 t)" --wt /x --branch b --ledger /x/merged.tsv
  assert_fail_reason BAD_ARGS
  # every flag is required — a missing --ledger would silently drop audit's
  # only id-to-commit join, so it fails typed rather than defaulting
  run orca merge-finalize /nonexistent 0000000000000000000000000000000000000000 W1 \
    --title-b64 "$(b64 t)" --wt /x --branch b
  assert_fail_reason BAD_ARGS
  make_run_layout "$BATS_TEST_TMPDIR/r"
  run orca commit-verify "$BATS_TEST_TMPDIR/r/int" not-a-sha W1 --branch feature/x --title-b64 "$(b64 t)"
  assert_fail_reason BAD_ARGS
  # the tip-before is a marker: a relay-garbled one fails typed before git sees it
  run orca merge-finalize "$BATS_TEST_TMPDIR/r/int" 'dddd; rm -rf /' W1 \
    --title-b64 "$(b64 t)" --wt /x --branch b --ledger /x/merged.tsv
  assert_fail_reason BAD_ARGS
}

# ---- run-state verbs: spec, archive, notes ------------------------------

# make_run_dir <layout-dir> — a run directory inside the layout's .orca/,
# path in $rd.
make_run_dir() {
  rd="$1/.orca/20260101-0000-feat-x"
  mkdir -p "$rd/plans" "$rd/reviews"
}

@test "spec mark: the mark is spec.md's content id" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  printf '# spec\n' >"$rd/spec.md"
  run orca spec mark "$rd"
  [ "$status" -eq 0 ]
  [ "$(frame_get mark)" = "$(git hash-object --no-filters "$rd/spec.md")" ]
}

@test "spec changed: no over an untouched spec, yes with the new mark after an edit" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  printf '# spec\n' >"$rd/spec.md"
  run orca spec mark "$rd"
  local m1
  m1="$(frame_get mark)"
  run orca spec changed "$rd" "$m1"
  [ "$status" -eq 0 ]
  has_line 'changed=no'
  [ "$(frame_get mark)" = "$m1" ]
  printf '# spec\n\n## Decisions\n- (W1) amended\n' >"$rd/spec.md"
  run orca spec changed "$rd" "$m1"
  [ "$status" -eq 0 ]
  has_line 'changed=yes'
  [ "$(frame_get mark)" = "$(git hash-object --no-filters "$rd/spec.md")" ]
  [ "$(frame_get mark)" != "$m1" ]
}

@test "spec: an unreadable spec answers changed=unknown, and fails mark typed" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  run orca spec changed "$rd" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  [ "$status" -eq 0 ]
  has_line 'changed=unknown'
  [ -z "$(frame_get mark)" ]
  run orca spec mark "$rd"
  assert_fail_reason SPEC_UNREADABLE
}

@test "spec: a malformed mark and a path outside .orca/ fail typed" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  printf '# spec\n' >"$rd/spec.md"
  run orca spec changed "$rd" 'aaaa; rm -rf /'
  assert_fail_reason BAD_ARGS
  run orca spec changed "$rd" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
  assert_fail_reason BAD_ARGS
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  printf '# spec\n' >"$BATS_TEST_TMPDIR/elsewhere/spec.md"
  run orca spec mark "$BATS_TEST_TMPDIR/elsewhere"
  assert_fail_reason BAD_ARGS
  run orca spec mark ".orca/20260101-0000-feat-x"
  assert_fail_reason BAD_ARGS
  run orca spec mark "$BATS_TEST_TMPDIR/r/.orca"
  assert_fail_reason BAD_ARGS
  run orca spec frobnicate "$rd"
  assert_fail_reason BAD_ARGS
}

@test "archive attempt: plan and reviews move together, reviews into prev0" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  echo plan >"$rd/plans/W1.md"
  echo r0 >"$rd/reviews/W1-codex.json"
  echo r0 >"$rd/reviews/W1-codex.round0.json"
  echo keep >"$rd/reviews/W10-codex.json"
  echo keep >"$rd/plans/W10.md"
  run orca archive attempt "$rd" W1
  [ "$status" -eq 0 ]
  has_line 'plan=archived'
  has_line 'reviews=archived'
  [ ! -e "$rd/plans/W1.md" ]
  [ "$(cat "$rd/plans/W1.round0.md")" = plan ]
  [ -f "$rd/reviews/prev0/W1-codex.json" ]
  [ -f "$rd/reviews/prev0/W1-codex.round0.json" ]
  # W1's glob is W1-*, never W10's files
  [ -f "$rd/reviews/W10-codex.json" ]
  [ -f "$rd/plans/W10.md" ]
}

@test "archive attempt: plan slots are unbounded — the first free round<N>" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  local n
  for n in 0 1 2 3 4; do echo "old$n" >"$rd/plans/W3.round$n.md"; done
  echo newest >"$rd/plans/W3.md"
  run orca archive attempt "$rd" W3
  [ "$status" -eq 0 ]
  has_line 'plan=archived'
  [ "$(cat "$rd/plans/W3.round5.md")" = newest ]
  [ "$(cat "$rd/plans/W3.round0.md")" = old0 ]
}

@test "archive attempt: the first prev<N> holding nothing of the item, unbounded, shared with other items" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  local n
  # prev0..prev5 each already hold a W2 attempt; prev0..prev7 hold W5's.
  for n in 0 1 2 3 4 5; do mkdir -p "$rd/reviews/prev$n"; echo "w2-$n" >"$rd/reviews/prev$n/W2-claude.json"; done
  for n in 0 1 2 3 4 5 6 7; do mkdir -p "$rd/reviews/prev$n"; echo "w5-$n" >"$rd/reviews/prev$n/W5-claude.json"; done
  echo fresh >"$rd/reviews/W2-claude.json"
  run orca archive attempt "$rd" W2
  [ "$status" -eq 0 ]
  has_line 'reviews=archived'
  # prev6 is the first holding nothing of W2, even though W5 lives there
  [ "$(cat "$rd/reviews/prev6/W2-claude.json")" = fresh ]
  [ "$(cat "$rd/reviews/prev6/W5-claude.json")" = w5-6 ]
  [ "$(cat "$rd/reviews/prev5/W2-claude.json")" = w2-5 ]
  # and an item with nothing archived yet takes prev0, beside the others
  echo first >"$rd/reviews/W9-codex.json"
  run orca archive attempt "$rd" W9
  [ "$status" -eq 0 ]
  [ "$(cat "$rd/reviews/prev0/W9-codex.json")" = first ]
}

@test "archive attempt: nothing to move is none/none, and a run-twice converges" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  run orca archive attempt "$rd" W4
  [ "$status" -eq 0 ]
  has_line 'plan=none'
  has_line 'reviews=none'
  [ ! -e "$rd/reviews/prev0" ]
  echo plan >"$rd/plans/W4.md"
  echo r >"$rd/reviews/W4-codex.json"
  run orca archive attempt "$rd" W4
  has_line 'plan=archived'
  run orca archive attempt "$rd" W4
  [ "$status" -eq 0 ]
  has_line 'plan=none'
  has_line 'reviews=none'
  [ ! -e "$rd/plans/W4.round1.md" ]
  [ ! -e "$rd/reviews/prev1" ]
}

@test "archive attempt integration: stale integration reviews are archived, not deleted" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  echo codex >"$rd/reviews/integration-codex.json"
  echo claude >"$rd/reviews/integration-claude.json"
  echo codex0 >"$rd/reviews/integration-codex.round0.json"
  echo keep >"$rd/reviews/W1-codex.json"
  run orca archive attempt "$rd" integration
  [ "$status" -eq 0 ]
  has_line 'plan=none'
  has_line 'reviews=archived'
  [ "$(cat "$rd/reviews/prev0/integration-codex.json")" = codex ]
  [ "$(cat "$rd/reviews/prev0/integration-claude.json")" = claude ]
  [ "$(cat "$rd/reviews/prev0/integration-codex.round0.json")" = codex0 ]
  [ -z "$(find "$rd/reviews" -maxdepth 1 -name 'integration-*')" ]
  [ -f "$rd/reviews/W1-codex.json" ]
}

@test "archive attempt: a failed plan move still archives the reviews" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  echo plan >"$rd/plans/W1.md"
  echo r >"$rd/reviews/W1-codex.json"
  chmod a-w "$rd/plans"
  run orca archive attempt "$rd" W1
  chmod u+w "$rd/plans"
  [ "$status" -eq 0 ]
  has_line 'plan=failed'
  has_line 'reviews=archived'
  [ -f "$rd/plans/W1.md" ]
  [ -f "$rd/reviews/prev0/W1-codex.json" ]
}

@test "archive: bad arguments fail typed" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  run orca archive attempt "$rd" 'W1*'
  assert_fail_reason BAD_ARGS
  run orca archive attempt "$rd" '../W1'
  assert_fail_reason BAD_ARGS
  run orca archive attempt "$rd" '.hidden'
  assert_fail_reason BAD_ARGS
  run orca archive attempt "$BATS_TEST_TMPDIR/r/int" W1
  assert_fail_reason BAD_ARGS
  run orca archive plan "$rd" W1
  assert_fail_reason BAD_ARGS
  run orca archive attempt "$rd"
  assert_fail_reason BAD_ARGS
}

@test "notes write: content lands byte-exact, atomically, and reports its path" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  local content
  content="$(printf '{\n  "declines": ["café — naïve"],\n  "escalations": []\n}\nX')"
  content="${content%X}"
  run orca notes write "$rd" integration-fixes "$(b64 "$content")"
  [ "$status" -eq 0 ]
  [ "$(frame_get written)" = "$rd/integration-fixes.json" ]
  [ "$(cat "$rd/integration-fixes.json"; printf X)" = "${content}X" ]
  # a rewrite replaces, and leaves no temp file behind
  run orca notes write "$rd" integration-fixes "$(b64 'second')"
  [ "$status" -eq 0 ]
  [ "$(cat "$rd/integration-fixes.json")" = second ]
  [ -z "$(find "$rd" -maxdepth 1 -name '.notes.*')" ]
}

@test "notes write: bad arguments and an unwritable run dir fail typed" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_dir "$BATS_TEST_TMPDIR/r"
  run orca notes write "$rd" report "$(b64 x)"
  assert_fail_reason BAD_ARGS
  run orca notes write "$rd" integration-fixes 'not base64!'
  assert_fail_reason BAD_ARGS
  run orca notes write "$BATS_TEST_TMPDIR" integration-fixes "$(b64 x)"
  assert_fail_reason BAD_ARGS
  run orca notes read "$rd" integration-fixes
  assert_fail_reason BAD_ARGS
  chmod a-w "$rd"
  run orca notes write "$rd" integration-fixes "$(b64 x)"
  chmod u+w "$rd"
  assert_fail_reason WRITE_ERROR
  [ ! -e "$rd/integration-fixes.json" ]
}

# ---- merge-prepare / commit-prepare -------------------------------------

@test "merge-prepare: a clean integration worktree is left alone, base is its head" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  run orca merge-prepare "$BATS_TEST_TMPDIR/r/int"
  [ "$status" -eq 0 ]
  has_line 'reset=none'
  [ "$(frame_get base)" = "$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse HEAD)" ]
}

# conflict_layout <dir> — an item branch and the integration branch that
# both rewrite seed.txt, so any merge of the item conflicts.
conflict_layout() {
  make_run_layout "$1"
  add_wt "$1"
  echo item >"$1/wt1/seed.txt"
  git -C "$1/wt1" commit -qam 'feat: item side'
  echo int >"$1/int/seed.txt"
  git -C "$1/int" commit -qam 'feat: integration side'
}

@test "merge-prepare: a conflicted squash (no MERGE_HEAD) falls back to reset --hard" {
  conflict_layout "$BATS_TEST_TMPDIR/r"
  local head
  head="$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse HEAD)"
  run git -C "$BATS_TEST_TMPDIR/r/int" merge --squash feature/x-W1
  [ "$status" -ne 0 ]
  [ -n "$(git -C "$BATS_TEST_TMPDIR/r/int" ls-files --unmerged)" ]
  run git -C "$BATS_TEST_TMPDIR/r/int" rev-parse -q --verify MERGE_HEAD
  [ "$status" -ne 0 ]
  echo debris >"$BATS_TEST_TMPDIR/r/int/untracked.txt"
  run orca merge-prepare "$BATS_TEST_TMPDIR/r/int"
  [ "$status" -eq 0 ]
  has_line 'reset=hard'
  [ "$(frame_get base)" = "$head" ]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/r/int" status --porcelain --untracked-files=no)" ]
  [ "$(cat "$BATS_TEST_TMPDIR/r/int/seed.txt")" = int ]
  # untracked files were never reset's to remove
  [ -f "$BATS_TEST_TMPDIR/r/int/untracked.txt" ]
}

@test "merge-prepare: a real merge in progress is aborted" {
  conflict_layout "$BATS_TEST_TMPDIR/r"
  run git -C "$BATS_TEST_TMPDIR/r/int" merge --no-ff feature/x-W1
  [ "$status" -ne 0 ]
  git -C "$BATS_TEST_TMPDIR/r/int" rev-parse -q --verify MERGE_HEAD >/dev/null
  run orca merge-prepare "$BATS_TEST_TMPDIR/r/int"
  [ "$status" -eq 0 ]
  has_line 'reset=aborted'
  run git -C "$BATS_TEST_TMPDIR/r/int" rev-parse -q --verify MERGE_HEAD
  [ "$status" -ne 0 ]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/r/int" status --porcelain --untracked-files=no)" ]
}

@test "merge-prepare: debris an abort leaves behind is reset too" {
  conflict_layout "$BATS_TEST_TMPDIR/r"
  echo other >"$BATS_TEST_TMPDIR/r/int/other.txt"
  git -C "$BATS_TEST_TMPDIR/r/int" add other.txt
  git -C "$BATS_TEST_TMPDIR/r/int" commit -qm 'chore: other'
  echo leftover >>"$BATS_TEST_TMPDIR/r/int/other.txt"
  run git -C "$BATS_TEST_TMPDIR/r/int" merge --no-ff feature/x-W1
  [ "$status" -ne 0 ]
  git -C "$BATS_TEST_TMPDIR/r/int" rev-parse -q --verify MERGE_HEAD >/dev/null
  run orca merge-prepare "$BATS_TEST_TMPDIR/r/int"
  [ "$status" -eq 0 ]
  has_line 'reset=hard'
  [ -z "$(git -C "$BATS_TEST_TMPDIR/r/int" status --porcelain --untracked-files=no)" ]
}

@test "merge-prepare: staged leftovers are reset; a reset that cannot run is reported, not fatal" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  echo staged >"$BATS_TEST_TMPDIR/r/int/seed.txt"
  git -C "$BATS_TEST_TMPDIR/r/int" add seed.txt
  local gitdir
  gitdir="$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse --absolute-git-dir)"
  touch "$gitdir/index.lock"
  run orca merge-prepare "$BATS_TEST_TMPDIR/r/int"
  [ "$status" -eq 0 ]
  has_line 'reset=failed'
  [ "$(frame_get base)" = "$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse HEAD)" ]
  rm -f "$gitdir/index.lock"
  run orca merge-prepare "$BATS_TEST_TMPDIR/r/int"
  [ "$status" -eq 0 ]
  has_line 'reset=hard'
  [ "$(cat "$BATS_TEST_TMPDIR/r/int/seed.txt")" = seed ]
}

@test "merge-prepare and commit-prepare refuse anything but a worktree top level" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/r/int/sub" "$BATS_TEST_TMPDIR/plain"
  for v in merge-prepare commit-prepare; do
    run orca "$v" "$BATS_TEST_TMPDIR/r/int/sub"
    assert_fail_reason BAD_ARGS
    run orca "$v" "$BATS_TEST_TMPDIR/plain"
    assert_fail_reason BAD_ARGS
    run orca "$v" int
    assert_fail_reason BAD_ARGS
    run orca "$v"
    assert_fail_reason BAD_ARGS
  done
}

@test "commit-prepare: pending follows the tree, base is the head" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  run orca commit-prepare "$BATS_TEST_TMPDIR/r/int"
  [ "$status" -eq 0 ]
  has_line 'pending=no'
  [ "$(frame_get base)" = "$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse HEAD)" ]
  echo new >"$BATS_TEST_TMPDIR/r/int/untracked.txt"
  run orca commit-prepare "$BATS_TEST_TMPDIR/r/int"
  has_line 'pending=yes'
  git -C "$BATS_TEST_TMPDIR/r/int" add untracked.txt
  run orca commit-prepare "$BATS_TEST_TMPDIR/r/int"
  has_line 'pending=yes'
}

@test "commit-prepare's base feeds commit-verify as its marker" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  echo fix >"$BATS_TEST_TMPDIR/r/int/fix.txt"
  run orca commit-prepare "$BATS_TEST_TMPDIR/r/int"
  local mark
  mark="$(frame_get base)"
  commit_in "$BATS_TEST_TMPDIR/r/int" 'fix: integration fixes'
  run orca commit-verify "$BATS_TEST_TMPDIR/r/int" "$mark" integration \
    --branch feature/x --title-b64 "$(b64 'integration fixes')"
  [ "$status" -eq 0 ]
  has_line 'action=accepted'
}

# ---- salvage -----------------------------------------------------------

@test "salvage: partial work becomes the fixed wip commit, and the worktree goes" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  echo partial >"$BATS_TEST_TMPDIR/r/wt1/partial.txt"
  run orca salvage "$BATS_TEST_TMPDIR/r/wt1" "$BATS_TEST_TMPDIR/r/int" W1
  [ "$status" -eq 0 ]
  has_line 'salvaged=committed'
  [ ! -d "$BATS_TEST_TMPDIR/r/wt1" ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%B feature/x-W1)" = 'wip: W1 — blocked, partial work' ]
  git -C "$BATS_TEST_TMPDIR/r/int" show feature/x-W1:partial.txt >/dev/null
}

@test "salvage: a clean worktree is removed without a commit; a missing one is no-worktree" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  run orca salvage "$BATS_TEST_TMPDIR/r/wt1" "$BATS_TEST_TMPDIR/r/int" W1
  [ "$status" -eq 0 ]
  has_line 'salvaged=clean'
  [ ! -d "$BATS_TEST_TMPDIR/r/wt1" ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse feature/x-W1)" = "$base" ]
  run orca salvage "$BATS_TEST_TMPDIR/r/wt1" "$BATS_TEST_TMPDIR/r/int" W1
  [ "$status" -eq 0 ]
  has_line 'salvaged=no-worktree'
}

@test "salvage: a failed commit leaves the worktree and its work in place" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/hooks"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/hooks/pre-commit"
  chmod +x "$BATS_TEST_TMPDIR/hooks/pre-commit"
  git -C "$BATS_TEST_TMPDIR/r/wt1" config core.hooksPath "$BATS_TEST_TMPDIR/hooks"
  echo partial >"$BATS_TEST_TMPDIR/r/wt1/partial.txt"
  run orca salvage "$BATS_TEST_TMPDIR/r/wt1" "$BATS_TEST_TMPDIR/r/int" W1
  assert_fail_reason GIT_ERROR
  [ -f "$BATS_TEST_TMPDIR/r/wt1/partial.txt" ]
}

@test "salvage: an id that trips the attribution regex falls back to the id-free message" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wtc" feature/x-claude1 feature/x
  echo partial >"$BATS_TEST_TMPDIR/r/wtc/partial.txt"
  run orca salvage "$BATS_TEST_TMPDIR/r/wtc" "$BATS_TEST_TMPDIR/r/int" claude1
  [ "$status" -eq 0 ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%B feature/x-claude1)" = 'wip: blocked, partial work' ]
}

@test "salvage: never the integration worktree, never another repository's worktree" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  make_run_layout "$BATS_TEST_TMPDIR/other"
  run orca salvage "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/int" W1
  assert_fail_reason BAD_ARGS
  [ -d "$BATS_TEST_TMPDIR/r/int" ]
  run orca salvage "$BATS_TEST_TMPDIR/other/int" "$BATS_TEST_TMPDIR/r/int" W1
  assert_fail_reason BAD_ARGS
  [ -d "$BATS_TEST_TMPDIR/other/int" ]
  mkdir -p "$BATS_TEST_TMPDIR/r/int/sub"
  run orca salvage "$BATS_TEST_TMPDIR/r/int/sub" "$BATS_TEST_TMPDIR/r/int" W1
  assert_fail_reason BAD_ARGS
  run orca salvage wt1 "$BATS_TEST_TMPDIR/r/int" W1
  assert_fail_reason BAD_ARGS
  run orca salvage "$BATS_TEST_TMPDIR/r/wt1" "$BATS_TEST_TMPDIR/r/int" 'W1 x'
  assert_fail_reason BAD_ARGS
}
