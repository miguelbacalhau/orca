#!/usr/bin/env bats
# orca.sh loop — snapshot (the tree the commit should hold) and check
# (the commit decision table), the commit step of an objective's phase.

load helpers

orca() { bash "$SCRIPTS/orca.sh" "$@"; }

# frame_get <key> — the key's value from the frame in $output.
frame_get() {
  printf '%s\n' "$output" | awk -v k="$1" '
    /^@@ORCA@@$/ { f = 1; next }
    /^@@ORCA_END@@$/ { f = 0 }
    f && index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'
}

head_tree() { git -C "$1" rev-parse 'HEAD^{tree}'; }

# phase_dir — a rounds directory beside the work tree, as an
# objective's phase directory sits outside every worktree.
phase_dir() { printf '%s' "$BATS_TEST_TMPDIR/objective/phases/P1"; }

# snapshot_in <wt> — sets $tree from the verb's snapshot frame.
snapshot_in() {
  mkdir -p "$(phase_dir)"
  run orca loop snapshot "$1" "$(phase_dir)"
  [ "$status" -eq 0 ]
  tree="$(frame_get tree)"
  [[ "$tree" =~ ^[0-9a-f]{40}$ ]]
}

commit_in() { # <wt> <message>
  echo "change-$RANDOM" >>"$1/work.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
}

# ---- arguments ----------------------------------------------------------

@test "bad arguments, and the retired start and finish, fail BAD_ARGS" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  assert_fail_reason BAD_ARGS
  run orca loop finish "$BATS_TEST_TMPDIR/r/.orca/loops/main"
  assert_fail_reason BAD_ARGS
  run orca loop bogus "$BATS_TEST_TMPDIR/r"
  assert_fail_reason BAD_ARGS
  run orca loop snapshot "$BATS_TEST_TMPDIR/r"
  assert_fail_reason BAD_ARGS
  run orca loop snapshot "$BATS_TEST_TMPDIR/nope" "$BATS_TEST_TMPDIR/d"
  assert_fail_reason BAD_ARGS
}

@test "a directory outside any work tree fails NOT_GIT" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run orca loop snapshot "$BATS_TEST_TMPDIR/plain" "$BATS_TEST_TMPDIR/d"
  assert_fail_reason NOT_GIT
}

@test "a checkout path carrying a newline fails BAD_PATH" {
  wt="$BATS_TEST_TMPDIR/new"$'\n'"line"
  make_repo "$wt"
  run orca loop snapshot "$wt" "$BATS_TEST_TMPDIR/d"
  assert_fail_reason BAD_PATH
}

@test "a checkout argument with a trailing newline fails BAD_PATH, never resolving to its sibling" {
  make_repo "$BATS_TEST_TMPDIR/r"
  make_repo "$BATS_TEST_TMPDIR/r"$'\n'
  run orca loop check "$BATS_TEST_TMPDIR/r"$'\n' "$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)" "$(head_tree "$BATS_TEST_TMPDIR/r")"
  assert_fail_reason BAD_PATH
}

@test "a symlink to a checkout whose name ends in a newline fails BAD_PATH" {
  make_repo "$BATS_TEST_TMPDIR/r"$'\n'
  ln -s "$BATS_TEST_TMPDIR/r"$'\n' "$BATS_TEST_TMPDIR/link"
  run orca loop snapshot "$BATS_TEST_TMPDIR/link" "$BATS_TEST_TMPDIR/d"
  assert_fail_reason BAD_PATH
}

@test "check: an unborn branch fails UNBORN" {
  mkdir -p "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r" init -q -b main
  run orca loop check "$BATS_TEST_TMPDIR/r" "$(printf '%040d' 0)" "$(printf '%040d' 0)"
  assert_fail_reason UNBORN
}

# ---- snapshot -----------------------------------------------------------

@test "snapshot: the tree git add -A would commit — untracked files in, ignored files out, the real index untouched" {
  make_repo "$BATS_TEST_TMPDIR/r"
  printf 'ignored.txt\n' >"$BATS_TEST_TMPDIR/r/.gitignore"
  git -C "$BATS_TEST_TMPDIR/r" add .gitignore && git -C "$BATS_TEST_TMPDIR/r" commit -qm ignore
  echo edit >>"$BATS_TEST_TMPDIR/r/seed.txt"
  echo new >"$BATS_TEST_TMPDIR/r/new.txt"
  echo junk >"$BATS_TEST_TMPDIR/r/ignored.txt"
  snapshot_in "$BATS_TEST_TMPDIR/r"
  [ -z "$(git -C "$BATS_TEST_TMPDIR/r" diff --cached --name-only)" ]
  git -C "$BATS_TEST_TMPDIR/r" add -A
  [ "$tree" = "$(git -C "$BATS_TEST_TMPDIR/r" write-tree)" ]
  git -C "$BATS_TEST_TMPDIR/r" ls-tree -r --name-only "$tree" | grep -qx new.txt
  ! git -C "$BATS_TEST_TMPDIR/r" ls-tree -r --name-only "$tree" | grep -qx ignored.txt
}

@test "snapshot: the bare layout's worktree, its phase directory outside it" {
  make_bare_layout "$BATS_TEST_TMPDIR/b"
  dir="$BATS_TEST_TMPDIR/b/.orca/objectives/20260101-000000-x/phases/P1"
  mkdir -p "$dir/reviews"
  echo '{}' >"$dir/reviews/round-1.json"
  echo new >"$BATS_TEST_TMPDIR/b/main/new.txt"
  run orca loop snapshot "$BATS_TEST_TMPDIR/b/main" "$dir"
  [ "$status" -eq 0 ]
  tree="$(frame_get tree)"
  [ "$(git -C "$BATS_TEST_TMPDIR/b/main" ls-tree -r --name-only "$tree" | sort | tr '\n' ' ')" = ".gitignore new.txt seed.txt " ]
}

@test "snapshot: recorded per review round — kept across retries and a fresh session, retaken after a new review" {
  make_repo "$BATS_TEST_TMPDIR/r"
  dir="$(phase_dir)"
  mkdir -p "$dir/reviews"
  echo '{"findings":[]}' >"$dir/reviews/round-1.json"
  echo reviewed >"$BATS_TEST_TMPDIR/r/new.txt"
  snapshot_in "$BATS_TEST_TMPDIR/r"
  [ "$(frame_get kept)" = no ]
  [ "$(frame_get round)" = 1 ]
  local first="$tree"
  [ "$(cat "$dir/snapshot")" = "$(printf 'round=1\ntree=%s' "$first")" ]
  # A hook rewrote the tree and the session died: the next snapshot, from
  # any session, is still the reviewed tree.
  echo hooked >"$BATS_TEST_TMPDIR/r/new.txt"
  snapshot_in "$BATS_TEST_TMPDIR/r"
  [ "$(frame_get kept)" = yes ]
  [ "$tree" = "$first" ]
  # A new review round has seen the change: a new snapshot.
  echo '{"findings":[]}' >"$dir/reviews/round-2.json"
  snapshot_in "$BATS_TEST_TMPDIR/r"
  [ "$(frame_get kept)" = no ]
  [ "$(frame_get round)" = 2 ]
  [ "$tree" != "$first" ]
  # A recorded tree the repository lacks is never trusted.
  printf 'round=2\ntree=%s\n' 0123456789abcdef0123456789abcdef01234567 >"$dir/snapshot"
  snapshot_in "$BATS_TEST_TMPDIR/r"
  [ "$(frame_get kept)" = no ]
}

@test "snapshot: a missing directory or a snapshot path that is not a regular file fails typed" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run orca loop snapshot "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/absent"
  assert_fail_reason BAD_ARGS
  mkdir -p "$(phase_dir)/snapshot"
  run orca loop snapshot "$BATS_TEST_TMPDIR/r" "$(phase_dir)"
  assert_fail_reason WRITE_ERROR
  rmdir "$(phase_dir)/snapshot"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$(phase_dir)/snapshot"
  run orca loop snapshot "$BATS_TEST_TMPDIR/r" "$(phase_dir)"
  assert_fail_reason WRITE_ERROR
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]
}

# ---- check --------------------------------------------------------------

@test "check: a commit of exactly the snapshot is accepted" {
  make_repo "$BATS_TEST_TMPDIR/r"
  base="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  echo new >"$BATS_TEST_TMPDIR/r/new.txt"
  snapshot_in "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r" add -A && git -C "$BATS_TEST_TMPDIR/r" commit -qm "feat: add new"
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$tree"
  [ "$(frame_get action)" = accepted ]
}

@test "check: a commit holding changes made after the snapshot resets softly, those changes staged" {
  make_repo "$BATS_TEST_TMPDIR/r"
  base="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  echo new >"$BATS_TEST_TMPDIR/r/new.txt"
  snapshot_in "$BATS_TEST_TMPDIR/r"
  # A commit hook that rewrote code and staged it, then let the commit through.
  echo rewritten >"$BATS_TEST_TMPDIR/r/new.txt"
  git -C "$BATS_TEST_TMPDIR/r" add -A && git -C "$BATS_TEST_TMPDIR/r" commit -qm "feat: add new"
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$tree"
  [ "$status" -eq 0 ]
  [ "$(frame_get action)" = content_reset ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)" = "$base" ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r" show :new.txt)" = rewritten ]
  # Until a review round has seen the staged state, the snapshot holds.
  snapshot_in "$BATS_TEST_TMPDIR/r"
  [ "$(frame_get kept)" = yes ]
  # Converges: once reviewed, a fresh snapshot of the staged state,
  # committed as is, is accepted.
  mkdir -p "$(phase_dir)/reviews"
  echo '{"findings":[]}' >"$(phase_dir)/reviews/round-1.json"
  snapshot_in "$BATS_TEST_TMPDIR/r"
  [ "$(frame_get kept)" = no ]
  git -C "$BATS_TEST_TMPDIR/r" commit -qm "feat: add new"
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$tree"
  [ "$(frame_get action)" = accepted ]
}

@test "check: an unmoved HEAD needs a commit" {
  make_repo "$BATS_TEST_TMPDIR/r"
  base="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  echo pending >>"$BATS_TEST_TMPDIR/r/seed.txt"
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$(head_tree "$BATS_TEST_TMPDIR/r")"
  [ "$status" -eq 0 ]
  [ "$(frame_get action)" = needs_commit ]
}

@test "check: a clean commit over a clean tree is accepted with its head and message" {
  make_repo "$BATS_TEST_TMPDIR/r"
  base="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  commit_in "$BATS_TEST_TMPDIR/r" "feat: add the thing"
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$(head_tree "$BATS_TEST_TMPDIR/r")"
  [ "$status" -eq 0 ]
  [ "$(frame_get action)" = accepted ]
  [ "$(frame_get head)" = "$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)" ]
  [ "$(frame_get message.b64 | base64 --decode)" = "feat: add the thing" ]
}

@test "check: a clean multi-commit span is accepted" {
  make_repo "$BATS_TEST_TMPDIR/r"
  base="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  commit_in "$BATS_TEST_TMPDIR/r" "feat: add the thing"
  commit_in "$BATS_TEST_TMPDIR/r" "test: cover the thing"
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$(head_tree "$BATS_TEST_TMPDIR/r")"
  [ "$(frame_get action)" = accepted ]
  [ "$(frame_get head)" = "$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)" ]
}

@test "check: a commit that left files behind is incomplete, nothing changed" {
  make_repo "$BATS_TEST_TMPDIR/r"
  base="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  commit_in "$BATS_TEST_TMPDIR/r" "feat: add the thing"
  head="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  echo missed >"$BATS_TEST_TMPDIR/r/missed.txt"
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$(head_tree "$BATS_TEST_TMPDIR/r")"
  [ "$(frame_get action)" = incomplete ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)" = "$head" ]
}

@test "check: a banned message anywhere in the span resets softly to base, changes staged" {
  make_repo "$BATS_TEST_TMPDIR/r"
  base="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  commit_in "$BATS_TEST_TMPDIR/r" "$(printf 'feat: add the thing\n\nCo-Authored-By: someone')"
  commit_in "$BATS_TEST_TMPDIR/r" "test: cover the thing"
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$(head_tree "$BATS_TEST_TMPDIR/r")"
  [ "$status" -eq 0 ]
  [ "$(frame_get action)" = violation_reset ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)" = "$base" ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r" diff --cached --name-only)" = work.txt ]
  # Converges: the retry arrival reads needs_commit.
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$(head_tree "$BATS_TEST_TMPDIR/r")"
  [ "$(frame_get action)" = needs_commit ]
}

@test "check: an untracked file left behind is incomplete even with status.showUntrackedFiles=no" {
  make_repo "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r" config status.showUntrackedFiles no
  base="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  commit_in "$BATS_TEST_TMPDIR/r" "feat: add the thing"
  echo missed >"$BATS_TEST_TMPDIR/r/missed.txt"
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$(head_tree "$BATS_TEST_TMPDIR/r")"
  [ "$(frame_get action)" = incomplete ]
}

@test "check: banned beats dirty, so the recommit picks up the missed files" {
  make_repo "$BATS_TEST_TMPDIR/r"
  base="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  commit_in "$BATS_TEST_TMPDIR/r" "feat: generated with a tool"
  echo missed >"$BATS_TEST_TMPDIR/r/missed.txt"
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$(head_tree "$BATS_TEST_TMPDIR/r")"
  [ "$(frame_get action)" = violation_reset ]
  [ -f "$BATS_TEST_TMPDIR/r/missed.txt" ]
}

@test "check: history rewritten under the base reads diverged, nothing changed" {
  make_repo "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r" "feat: the user's own commit"
  base="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  git -C "$BATS_TEST_TMPDIR/r" reset -q --hard HEAD~1
  commit_in "$BATS_TEST_TMPDIR/r" "feat: something else"
  head="$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  run orca loop check "$BATS_TEST_TMPDIR/r" "$base" "$(head_tree "$BATS_TEST_TMPDIR/r")"
  [ "$(frame_get action)" = diverged ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)" = "$head" ]
}

@test "check: a malformed base fails BAD_ARGS" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run orca loop check "$BATS_TEST_TMPDIR/r" HEAD "$(head_tree "$BATS_TEST_TMPDIR/r")"
  assert_fail_reason BAD_ARGS
  run orca loop check "$BATS_TEST_TMPDIR/r" "$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)" nope
  assert_fail_reason BAD_ARGS
  run orca loop check "$BATS_TEST_TMPDIR/r" "$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)"
  assert_fail_reason BAD_ARGS
}
