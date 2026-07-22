#!/usr/bin/env bats
# init-convert.sh — conversion, cleanup refusal, crash recovery.

load helpers

convert_repo() { # <dir> — run convert inside it
  run bash "$SCRIPTS/init-convert.sh" convert
}

@test "check passes on a clean conventional repo" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPTS/init-convert.sh" check
  [ "$status" -eq 0 ]
  has_line $'CLEAN:\tPASS'
  has_line $'NO_WORKTREES:\tPASS'
  has_line $'NO_SUBMODULES:\tPASS'
  has_line $'BRANCH:\tmain'
}

@test "check fails typed on staged changes" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  echo change >>seed.txt
  run bash "$SCRIPTS/init-convert.sh" check
  [ "$status" -eq 1 ]
  has_line $'CLEAN:\tFAIL'
}

@test "convert refuses a namespaced branch" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  git checkout -qb feature/foo
  run bash "$SCRIPTS/init-convert.sh" convert
  assert_fail_reason BRANCH_UNSAFE
}

@test "convert moves untracked files with spaces, newlines, and symlinks" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  echo a >"with space.txt"
  printf 'b\n' >"$(printf 'new\nline.txt')"
  ln -s seed.txt link-to-seed
  mkdir -p "deep dir"
  echo c >"deep dir/nested file"
  run bash "$SCRIPTS/init-convert.sh" convert
  [ "$status" -eq 0 ]
  has_line $'MOVED:\t4'
  has_line $'VERIFY:\ttracked-clean\tall 4 untracked arrived'
  [ -f "main/with space.txt" ]
  [ -f "$(printf 'main/new\nline.txt')" ]
  [ -L main/link-to-seed ]
  [ -f "main/deep dir/nested file" ]
}

@test "cleanup deletes only conversion leftovers" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir tracked-dir
  echo t >tracked-dir/file.txt
  git add -A && git commit -qm more
  echo u >untracked.txt
  run bash "$SCRIPTS/init-convert.sh" convert
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/init-convert.sh" cleanup
  [ "$status" -eq 0 ]
  has_line 'CLEANED:'
  [ ! -e seed.txt ]
  [ ! -e tracked-dir ]
  [ -f main/seed.txt ]
  [ -f main/untracked.txt ]
  [ ! -e .orca/init-convert-manifest ]
}

@test "cleanup refuses unrecognized entries and registered worktrees, deleting nothing" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPTS/init-convert.sh" convert
  [ "$status" -eq 0 ]
  git -C main worktree add ../orca-myfeature -b orca-myfeature >/dev/null 2>&1
  echo stray >stray-file
  run bash "$SCRIPTS/init-convert.sh" cleanup
  assert_fail_reason PRECONDITION
  [[ "$output" == *orca-myfeature* ]]
  [[ "$output" == *stray-file* ]]
  # nothing was deleted — the old tracked content survives too
  [ -f seed.txt ]
  [ -d orca-myfeature ]
  [ -f stray-file ]
}

@test "cleanup refuses when a manifest file is missing from the worktree" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  echo u >untracked.txt
  run bash "$SCRIPTS/init-convert.sh" convert
  [ "$status" -eq 0 ]
  rm main/untracked.txt
  run bash "$SCRIPTS/init-convert.sh" cleanup
  assert_fail_reason MANIFEST_MISMATCH
  [ -f seed.txt ]
}

@test "signal mid-move leaves a journal; recover completes the conversion" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  echo 1 >aaa.txt
  echo 2 >killme.txt
  echo 3 >zzz.txt
  # a PATH-injected mv that SIGTERMs the script when it reaches killme.txt
  mkdir "$BATS_TEST_TMPDIR/fakebin"
  cat >"$BATS_TEST_TMPDIR/fakebin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == *killme* ]]; then kill -TERM $PPID; sleep 2; exit 1; fi
exec /usr/bin/mv "$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/fakebin/mv"
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run bash "$SCRIPTS/init-convert.sh" convert
  assert_fail_reason INTERRUPTED
  [ -f .orca/init-convert-journal ]
  [ -f main/aaa.txt ]
  [ -f killme.txt ]
  run bash "$SCRIPTS/init-convert.sh" recover
  [ "$status" -eq 0 ]
  has_line $'MOVED:\t2'
  has_line $'VERIFY:\ttracked-clean\tall 3 untracked arrived'
  [ -f main/killme.txt ]
  [ -f main/zzz.txt ]
  [ ! -e .orca/init-convert-journal ]
}

@test "recover rolls forward from a crash between mv .git and the pointer write" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  echo u >note.txt
  # hand-built crash state: manifest and journal written, .git moved, no
  # pointer file, no worktree — git itself cannot see a repository here
  mkdir .orca
  printf 'note.txt\0' >.orca/init-convert-manifest
  printf 'begin\0main\0step\0mv-git-bare\0' >.orca/init-convert-journal
  /usr/bin/mv .git .bare
  run bash "$SCRIPTS/init-convert.sh" recover
  [ "$status" -eq 0 ]
  has_line $'MOVED:\t1'
  [ -f main/note.txt ]
  [ -f main/seed.txt ]
  [ ! -e .orca/init-convert-journal ]
}

@test "recover without a journal fails typed" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPTS/init-convert.sh" recover
  assert_fail_reason NO_JOURNAL
}
