#!/usr/bin/env bats
# orca.sh loop — start (the loop directory, base, dirty state, the run
# whose deliverable the branch is) and check (the commit decision table).

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

# snapshot_in <wt> — sets $tree from the verb's snapshot frame.
snapshot_in() {
  run orca loop snapshot "$1" "$1/.orca/loops/main"
  [ "$status" -eq 0 ]
  tree="$(frame_get tree)"
  [[ "$tree" =~ ^[0-9a-f]{40}$ ]]
}

commit_in() { # <wt> <message>
  echo "change-$RANDOM" >>"$1/work.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
}

# ---- start --------------------------------------------------------------

@test "start: a clean checkout frames its branch, base, and a fresh loop directory" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  [ "$(frame_get worktree)" = "$BATS_TEST_TMPDIR/r" ]
  [ "$(frame_get branch)" = main ]
  [ "$(frame_get dirty)" = no ]
  [ "$(frame_get base)" = "$(git -C "$BATS_TEST_TMPDIR/r" rev-parse HEAD)" ]
  [ "$(frame_get dir)" = "$BATS_TEST_TMPDIR/r/.orca/loops/main" ]
  [ -d "$BATS_TEST_TMPDIR/r/.orca/loops/main/reviews" ]
  [ "$(frame_get run_dir)" = - ]
}

@test "start: the loop directory never makes a conventional checkout dirty" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  echo brief >"$BATS_TEST_TMPDIR/r/.orca/loops/main/brief.md"
  [ -z "$(git -C "$BATS_TEST_TMPDIR/r" status --porcelain)" ]
  grep -qxF '.orca/' "$BATS_TEST_TMPDIR/r/.git/info/exclude"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  [ "$(frame_get dirty)" = no ]
}

@test "start: uncommitted changes read dirty, untracked files included" {
  make_repo "$BATS_TEST_TMPDIR/r"
  echo new >"$BATS_TEST_TMPDIR/r/untracked.txt"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  [ "$(frame_get dirty)" = yes ]
}

@test "start: a subdirectory argument is normalized to the work-tree top level" {
  make_repo "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/r/sub"
  run orca loop start "$BATS_TEST_TMPDIR/r/sub"
  [ "$status" -eq 0 ]
  [ "$(frame_get worktree)" = "$BATS_TEST_TMPDIR/r" ]
}

@test "start: a detached HEAD fails DETACHED" {
  make_repo "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r" checkout -q --detach
  run orca loop start "$BATS_TEST_TMPDIR/r"
  assert_fail_reason DETACHED
}

@test "start: a directory outside any work tree fails NOT_GIT" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run orca loop start "$BATS_TEST_TMPDIR/plain"
  assert_fail_reason NOT_GIT
}

@test "start: an unborn branch fails UNBORN" {
  mkdir -p "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r" init -q -b main
  run orca loop start "$BATS_TEST_TMPDIR/r"
  assert_fail_reason UNBORN
}

@test "start: bad arguments fail BAD_ARGS" {
  run orca loop start
  assert_fail_reason BAD_ARGS
  run orca loop bogus "$BATS_TEST_TMPDIR"
  assert_fail_reason BAD_ARGS
  run orca loop start "$BATS_TEST_TMPDIR/nope"
  assert_fail_reason BAD_ARGS
}

@test "start: a branch with a slash keys through the notes rule, under the bare layout's root" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r/main" worktree add -q "$BATS_TEST_TMPDIR/r/orca-x" -b feature/x main 2>/dev/null
  run orca loop start "$BATS_TEST_TMPDIR/r/orca-x"
  [ "$status" -eq 0 ]
  [ "$(frame_get branch)" = feature/x ]
  [ "$(frame_get dir)" = "$BATS_TEST_TMPDIR/r/.orca/loops/feature-x" ]
  [ -d "$BATS_TEST_TMPDIR/r/.orca/loops/feature-x/reviews" ]
}

@test "start: run_dir is the run whose report names the branch its deliverable" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r/main" worktree add -q "$BATS_TEST_TMPDIR/r/orca-x" -b feature/x main 2>/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/20261001-0900-feat-x" "$BATS_TEST_TMPDIR/r/.orca/20261002-0900-feat-y"
  printf '# Report: x\n\n**Deliverable:** `feature/x`\n' >"$BATS_TEST_TMPDIR/r/.orca/20261001-0900-feat-x/report.md"
  printf '# Report: y\n\n**Deliverable:** `feature/xy`\n' >"$BATS_TEST_TMPDIR/r/.orca/20261002-0900-feat-y/report.md"
  run orca loop start "$BATS_TEST_TMPDIR/r/orca-x"
  [ "$status" -eq 0 ]
  [ "$(frame_get run_dir)" = "$BATS_TEST_TMPDIR/r/.orca/20261001-0900-feat-x" ]
}

@test "start: an existing loop directory from a dead session is emptied" {
  make_repo "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/loops/main/reviews"
  echo stale >"$BATS_TEST_TMPDIR/r/.orca/loops/main/brief.md"
  echo stale >"$BATS_TEST_TMPDIR/r/.orca/loops/main/reviews/round-1.json"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  [ -d "$BATS_TEST_TMPDIR/r/.orca/loops/main/reviews" ]
  [ ! -e "$BATS_TEST_TMPDIR/r/.orca/loops/main/brief.md" ]
  [ ! -e "$BATS_TEST_TMPDIR/r/.orca/loops/main/reviews/round-1.json" ]
}

@test "start: a loop directory git would not ignore fails LOOP_DIR_UNIGNORED and is not left behind" {
  make_repo "$BATS_TEST_TMPDIR/r"
  printf '!.orca/\n!.orca/**\n' >"$BATS_TEST_TMPDIR/r/.gitignore"
  git -C "$BATS_TEST_TMPDIR/r" add .gitignore
  git -C "$BATS_TEST_TMPDIR/r" commit -qm ignore
  run orca loop start "$BATS_TEST_TMPDIR/r"
  assert_fail_reason LOOP_DIR_UNIGNORED
  [ ! -e "$BATS_TEST_TMPDIR/r/.orca/loops/main" ]
}

@test "start: untracked files read dirty even with status.showUntrackedFiles=no" {
  make_repo "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r" config status.showUntrackedFiles no
  echo new >"$BATS_TEST_TMPDIR/r/untracked.txt"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  [ "$(frame_get dirty)" = yes ]
}

@test "start: a symlinked .orca/loops fails UNSAFE_LOOP_DIR and deletes nothing through it" {
  make_repo "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/main" "$BATS_TEST_TMPDIR/r/.orca"
  echo keep >"$BATS_TEST_TMPDIR/elsewhere/main/sentinel"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$BATS_TEST_TMPDIR/r/.orca/loops"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  assert_fail_reason UNSAFE_LOOP_DIR
  [ -f "$BATS_TEST_TMPDIR/elsewhere/main/sentinel" ]
}

@test "start: a symlinked .orca fails UNSAFE_LOOP_DIR and deletes nothing through it" {
  make_repo "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/loops/main"
  echo keep >"$BATS_TEST_TMPDIR/elsewhere/loops/main/sentinel"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$BATS_TEST_TMPDIR/r/.orca"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  assert_fail_reason UNSAFE_LOOP_DIR
  [ -f "$BATS_TEST_TMPDIR/elsewhere/loops/main/sentinel" ]
}

@test "start: a branch whose key another live loop owns fails KEY_COLLISION, its state intact" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r/main" worktree add -q "$BATS_TEST_TMPDIR/r/a" -b feature/x main 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/r/main" worktree add -q "$BATS_TEST_TMPDIR/r/b" -b feature-x main 2>/dev/null
  run orca loop start "$BATS_TEST_TMPDIR/r/a"
  [ "$status" -eq 0 ]
  echo brief >"$BATS_TEST_TMPDIR/r/.orca/loops/feature-x/brief.md"
  run orca loop start "$BATS_TEST_TMPDIR/r/b"
  assert_fail_reason KEY_COLLISION
  [ -f "$BATS_TEST_TMPDIR/r/.orca/loops/feature-x/brief.md" ]
  # The owning branch itself restarts fine.
  run orca loop start "$BATS_TEST_TMPDIR/r/a"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/r/.orca/loops/feature-x/brief.md" ]
}

@test "start: a negation that re-includes only part of the loop directory fails LOOP_DIR_UNIGNORED" {
  make_repo "$BATS_TEST_TMPDIR/r"
  printf '!.orca/\n!.orca/**\n.orca/loops/*/brief.md\n' >"$BATS_TEST_TMPDIR/r/.gitignore"
  git -C "$BATS_TEST_TMPDIR/r" add .gitignore
  git -C "$BATS_TEST_TMPDIR/r" commit -qm ignore
  run orca loop start "$BATS_TEST_TMPDIR/r"
  assert_fail_reason LOOP_DIR_UNIGNORED
  [ ! -e "$BATS_TEST_TMPDIR/r/.orca/loops/main" ]
}

@test "start: tracked files under the loop directory fail LOOP_DIR_UNIGNORED and are never deleted" {
  make_repo "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/loops/main"
  echo tracked >"$BATS_TEST_TMPDIR/r/.orca/loops/main/brief.md"
  git -C "$BATS_TEST_TMPDIR/r" add -f .orca/loops/main/brief.md
  git -C "$BATS_TEST_TMPDIR/r" commit -qm tracked
  run orca loop start "$BATS_TEST_TMPDIR/r"
  assert_fail_reason LOOP_DIR_UNIGNORED
  [ -f "$BATS_TEST_TMPDIR/r/.orca/loops/main/brief.md" ]
}

@test "start: a checkout path carrying a newline fails BAD_PATH before anything is created" {
  wt="$BATS_TEST_TMPDIR/new"$'\n'"line"
  make_repo "$wt"
  run orca loop start "$wt"
  assert_fail_reason BAD_PATH
  [ ! -e "$wt/.orca" ]
}

@test "start: a checkout argument with a trailing newline fails BAD_PATH, never resolving to its sibling" {
  make_repo "$BATS_TEST_TMPDIR/r"
  make_repo "$BATS_TEST_TMPDIR/r"$'\n'
  run orca loop start "$BATS_TEST_TMPDIR/r"$'\n'
  assert_fail_reason BAD_PATH
  [ ! -e "$BATS_TEST_TMPDIR/r/.orca" ]
}

@test "start: a symlink to a checkout whose name ends in a newline fails BAD_PATH" {
  make_repo "$BATS_TEST_TMPDIR/r"$'\n'
  ln -s "$BATS_TEST_TMPDIR/r"$'\n' "$BATS_TEST_TMPDIR/link"
  run orca loop start "$BATS_TEST_TMPDIR/link"
  assert_fail_reason BAD_PATH
}

@test "start: a linked worktree of a conventional repo keeps its scratch in the primary checkout, ignored there" {
  make_repo "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r" worktree add -q "$BATS_TEST_TMPDIR/wt" -b feature/x 2>/dev/null
  run orca loop start "$BATS_TEST_TMPDIR/wt"
  [ "$status" -eq 0 ]
  [ "$(frame_get dir)" = "$BATS_TEST_TMPDIR/r/.orca/loops/feature-x" ]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/r" status --porcelain --untracked-files=all)" ]
}

@test "start: files the primary checkout tracks under a linked worktree's scratch are never deleted" {
  make_repo "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/loops/feature-x"
  echo tracked >"$BATS_TEST_TMPDIR/r/.orca/loops/feature-x/brief.md"
  git -C "$BATS_TEST_TMPDIR/r" add -f .orca/loops/feature-x/brief.md
  git -C "$BATS_TEST_TMPDIR/r" commit -qm tracked
  echo edited >"$BATS_TEST_TMPDIR/r/.orca/loops/feature-x/brief.md"
  git -C "$BATS_TEST_TMPDIR/r" worktree add -q "$BATS_TEST_TMPDIR/wt" -b feature/x 2>/dev/null
  run orca loop start "$BATS_TEST_TMPDIR/wt"
  assert_fail_reason LOOP_DIR_UNIGNORED
  [ "$(cat "$BATS_TEST_TMPDIR/r/.orca/loops/feature-x/brief.md")" = edited ]
}

@test "start: .orca linked to a sibling whose name ends in a newline fails UNSAFE_LOOP_DIR, the sibling intact" {
  make_repo "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca"$'\n'"/loops/main"
  echo keep >"$BATS_TEST_TMPDIR/r/.orca"$'\n'"/loops/main/sentinel"
  ln -s ".orca"$'\n' "$BATS_TEST_TMPDIR/r/.orca"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  assert_fail_reason UNSAFE_LOOP_DIR
  [ -f "$BATS_TEST_TMPDIR/r/.orca"$'\n'"/loops/main/sentinel" ]
}

@test "start: a previous loop directory that cannot be cleared fails WRITE_ERROR, never reusing stale state" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  make_repo "$BATS_TEST_TMPDIR/r"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  dir="$(frame_get dir)"
  echo stale >"$dir/declines.md"
  chmod a-w "$dir"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  chmod u+w "$dir"
  assert_fail_reason WRITE_ERROR
}

# ---- finish -------------------------------------------------------------

@test "finish: removes the directory start made, then reads removed=no" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  dir="$(frame_get dir)"
  echo brief >"$dir/brief.md"
  run orca loop finish "$dir"
  [ "$status" -eq 0 ]
  [ "$(frame_get removed)" = yes ]
  [ ! -e "$dir" ]
  run orca loop finish "$dir"
  [ "$(frame_get removed)" = no ]
}

@test "finish: a parent swapped for a symlink after start fails UNSAFE_LOOP_DIR, the outside sentinel intact" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  dir="$(frame_get dir)"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/main"
  echo keep >"$BATS_TEST_TMPDIR/elsewhere/main/sentinel"
  : >"$BATS_TEST_TMPDIR/elsewhere/main/owner"
  rm -rf "$BATS_TEST_TMPDIR/r/.orca/loops"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$BATS_TEST_TMPDIR/r/.orca/loops"
  run orca loop finish "$dir"
  assert_fail_reason UNSAFE_LOOP_DIR
  [ -f "$BATS_TEST_TMPDIR/elsewhere/main/sentinel" ]
}

@test "finish: .orca linked to a sibling whose name ends in a newline fails UNSAFE_LOOP_DIR, the sibling intact" {
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca"$'\n'"/loops/main"
  echo keep >"$BATS_TEST_TMPDIR/r/.orca"$'\n'"/loops/main/sentinel"
  : >"$BATS_TEST_TMPDIR/r/.orca"$'\n'"/loops/main/owner"
  ln -s ".orca"$'\n' "$BATS_TEST_TMPDIR/r/.orca"
  run orca loop finish "$BATS_TEST_TMPDIR/r/.orca/loops/main"
  assert_fail_reason UNSAFE_LOOP_DIR
  [ -f "$BATS_TEST_TMPDIR/r/.orca"$'\n'"/loops/main/sentinel" ]
}

@test "finish: scratch files the checkout tracks are never deleted" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  dir="$(frame_get dir)"
  echo brief >"$dir/brief.md"
  git -C "$BATS_TEST_TMPDIR/r" add -f .orca/loops/main/brief.md
  git -C "$BATS_TEST_TMPDIR/r" commit -qm "tracked scratch"
  run orca loop finish "$dir"
  assert_fail_reason LOOP_DIR_UNIGNORED
  [ -f "$dir/brief.md" ]
}

@test "start: a tracked-file query that fails is GIT_ERROR, the existing scratch intact" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  dir="$(frame_get dir)"
  echo keep >"$dir/declines.md"
  echo garbage >"$BATS_TEST_TMPDIR/r/.git/index"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  assert_fail_reason GIT_ERROR
  [ -f "$dir/declines.md" ]
}

@test "finish: a directory without start's owner file, or outside .orca/loops, is never deleted" {
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/loops/main" "$BATS_TEST_TMPDIR/other/x"
  run orca loop finish "$BATS_TEST_TMPDIR/r/.orca/loops/main"
  assert_fail_reason UNSAFE_LOOP_DIR
  [ -d "$BATS_TEST_TMPDIR/r/.orca/loops/main" ]
  : >"$BATS_TEST_TMPDIR/other/x/owner"
  run orca loop finish "$BATS_TEST_TMPDIR/other/x"
  assert_fail_reason UNSAFE_LOOP_DIR
  [ -d "$BATS_TEST_TMPDIR/other/x" ]
  run orca loop finish relative/path
  assert_fail_reason BAD_ARGS
}

# ---- check --------------------------------------------------------------

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

@test "snapshot: an ignore rule changed after start that exposes the scratch fails LOOP_DIR_UNIGNORED" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run orca loop start "$BATS_TEST_TMPDIR/r"
  dir="$(frame_get dir)"
  echo brief >"$dir/brief.md"
  printf '!.orca/\n!.orca/**\n' >"$BATS_TEST_TMPDIR/r/.gitignore"
  run orca loop snapshot "$BATS_TEST_TMPDIR/r" "$dir"
  assert_fail_reason LOOP_DIR_UNIGNORED
  [ -z "$(git -C "$BATS_TEST_TMPDIR/r" diff --cached --name-only)" ]
}

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
  # Converges: a fresh snapshot of the staged state, committed as is, is accepted.
  snapshot_in "$BATS_TEST_TMPDIR/r"
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
