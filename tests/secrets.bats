#!/usr/bin/env bats
# secrets.sh — placement gates, idempotency, dangling-link sweep boundaries.

load helpers

# A bare-with-worktrees layout: repo root with .bare/.git pointer, a main
# worktree, .orca/secrets seeded, and .env ignored (tracked .gitignore).
make_bare_layout() { # <dir>
  make_repo "$1"
  ( cd "$1" &&
    echo '.env' >.gitignore &&
    git add .gitignore && git commit -qm gitignore &&
    /usr/bin/mv .git .bare &&
    git --git-dir=.bare config core.bare true &&
    printf 'gitdir: ./.bare\n' >.git &&
    git worktree add main main >/dev/null 2>&1 )
  mkdir -p "$1/.orca/secrets"
}

@test "no secrets dir is a clean no-op" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line $'OK:\tno secrets'
}

@test "places a relative symlink for an ignored destination" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.env'
  [ -L "$BATS_TEST_TMPDIR/r/main/.env" ]
  [ "$(readlink "$BATS_TEST_TMPDIR/r/main/.env")" = "../.orca/secrets/.env" ]
  [ "$(cat "$BATS_TEST_TMPDIR/r/main/.env")" = "SECRET=1" ]
}

@test "nested secret gets a depth-correct relative link" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  ( cd "$BATS_TEST_TMPDIR/r/main" &&
    mkdir -p apps/api && echo '.env' >apps/api/.gitignore &&
    git add apps/api/.gitignore && git commit -qm nested )
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/secrets/apps/api"
  echo 'K=v' >"$BATS_TEST_TMPDIR/r/.orca/secrets/apps/api/.env"
  run bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'LINKED:\tapps/api/.env'
  [ "$(readlink "$BATS_TEST_TMPDIR/r/main/apps/api/.env")" = "../../../.orca/secrets/apps/api/.env" ]
  [ "$(cat "$BATS_TEST_TMPDIR/r/main/apps/api/.env")" = "K=v" ]
}

@test "unignored destination never receives a secret" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  echo 'x' >"$BATS_TEST_TMPDIR/r/.orca/secrets/not-ignored.txt"
  run bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'UNIGNORED:\tnot-ignored.txt'
  [ ! -e "$BATS_TEST_TMPDIR/r/main/not-ignored.txt" ]
}

@test "re-run over a placed worktree is idempotent OK" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/r/main" >/dev/null
  run bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'OK:\t.env'
  refute_line 'LINKED:'
  refute_line 'RELINKED:'
}

@test "a real file at the destination is never overwritten" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  echo 'mine' >"$BATS_TEST_TMPDIR/r/main/.env"
  run bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_EXISTS:\t.env'
  [ "$(cat "$BATS_TEST_TMPDIR/r/main/.env")" = "mine" ]
}

@test "a symlink inside secrets/ is skipped as irregular" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  ln -s /etc/hostname "$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_IRREGULAR:\t.env'
  [ ! -e "$BATS_TEST_TMPDIR/r/main/.env" ]
}

@test "dangling secrets link whose source is gone is swept" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/r/main" >/dev/null
  rm "$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_GONE:\t.env'
  [ ! -L "$BATS_TEST_TMPDIR/r/main/.env" ]
}

@test "sweep leaves dangling links that are not secrets placements alone" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  ln -s /nonexistent-target "$BATS_TEST_TMPDIR/r/main/dead-link"
  run bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  [ -L "$BATS_TEST_TMPDIR/r/main/dead-link" ]
}

@test "sweep does not descend into .git or .orca" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  # a conventional-layout repo whose root holds .orca — the prune must
  # protect links under it
  make_repo "$BATS_TEST_TMPDIR/c"
  mkdir -p "$BATS_TEST_TMPDIR/c/.orca/secrets"
  ln -s /gone "$BATS_TEST_TMPDIR/c/.orca/keep-me"
  ln -s /gone "$BATS_TEST_TMPDIR/c/.git/keep-me-too"
  run bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/c"
  [ "$status" -eq 0 ]
  [ -L "$BATS_TEST_TMPDIR/c/.orca/keep-me" ]
  [ -L "$BATS_TEST_TMPDIR/c/.git/keep-me-too" ]
}

@test "misuse fails typed: bad args and non-worktree" {
  run bash "$SCRIPTS/secrets.sh" place
  assert_fail_reason BAD_ARGS
  mkdir "$BATS_TEST_TMPDIR/plain"
  run bash "$SCRIPTS/secrets.sh" place "$BATS_TEST_TMPDIR/plain"
  assert_fail_reason NOT_GIT
}
