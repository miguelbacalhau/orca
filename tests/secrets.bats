#!/usr/bin/env bats
# orca.sh secrets — placement gates, idempotency, dangling-link sweep boundaries.

load helpers

# python3 is poisoned for every test by helpers.bash's setup — symlink
# ownership resolution is the lib's pure-bash canonicalizer, and any
# python3 call is an envelope regression that fails loudly.
secrets() {
  bash "$SCRIPTS/orca.sh" secrets "$@"
}

# make_bare_layout comes from helpers.bash; these tests add the secrets
# tree on top.
make_secrets_layout() { # <dir>
  make_bare_layout "$1"
  mkdir -p "$1/.orca/secrets"
}

@test "no secrets dir is a clean no-op" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run secrets place "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line $'OK:\tno secrets'
}

@test "places a relative symlink for an ignored destination" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.env'
  [ -L "$BATS_TEST_TMPDIR/r/main/.env" ]
  [ "$(readlink "$BATS_TEST_TMPDIR/r/main/.env")" = "../.orca/secrets/.env" ]
  [ "$(cat "$BATS_TEST_TMPDIR/r/main/.env")" = "SECRET=1" ]
}

@test "nested secret gets a depth-correct relative link" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  ( cd "$BATS_TEST_TMPDIR/r/main" &&
    mkdir -p apps/api && echo '.env' >apps/api/.gitignore &&
    git add apps/api/.gitignore && git commit -qm nested )
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/secrets/apps/api"
  echo 'K=v' >"$BATS_TEST_TMPDIR/r/.orca/secrets/apps/api/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'LINKED:\tapps/api/.env'
  [ "$(readlink "$BATS_TEST_TMPDIR/r/main/apps/api/.env")" = "../../../.orca/secrets/apps/api/.env" ]
  [ "$(cat "$BATS_TEST_TMPDIR/r/main/apps/api/.env")" = "K=v" ]
}

@test "unignored destination never receives a secret" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'x' >"$BATS_TEST_TMPDIR/r/.orca/secrets/not-ignored.txt"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'UNIGNORED:\tnot-ignored.txt'
  [ ! -e "$BATS_TEST_TMPDIR/r/main/not-ignored.txt" ]
}

@test "re-run over a placed worktree is idempotent OK" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  secrets place "$BATS_TEST_TMPDIR/r/main" >/dev/null
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'OK:\t.env'
  refute_line 'LINKED:'
  refute_line 'RELINKED:'
}

@test "a real file at the destination is never overwritten" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  echo 'mine' >"$BATS_TEST_TMPDIR/r/main/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_EXISTS:\t.env'
  [ "$(cat "$BATS_TEST_TMPDIR/r/main/.env")" = "mine" ]
}

@test "a secrets entry linking to a directory is skipped as irregular" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  mkdir "$BATS_TEST_TMPDIR/somedir"
  ln -s "$BATS_TEST_TMPDIR/somedir" "$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_IRREGULAR:\t.env'
  [ ! -e "$BATS_TEST_TMPDIR/r/main/.env" ]
}

# ---- entries that link into the default worktree ----

# make_linked_layout <dir> — the user's real .env in main/, the store's
# entry a relative link to it, and a run worktree beside main.
make_linked_layout() {
  make_secrets_layout "$1"
  echo 'LIVE=1' >"$1/main/.env"
  ln -s ../../main/.env "$1/.orca/secrets/.env"
  git -C "$1/main" worktree add -q -b feature/x ../orca-x >/dev/null 2>&1
}

@test "a linked entry is placed as a link to the entry, not past it" {
  make_linked_layout "$BATS_TEST_TMPDIR/r"
  run secrets place "$BATS_TEST_TMPDIR/r/orca-x"
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.env'
  [ "$(readlink "$BATS_TEST_TMPDIR/r/orca-x/.env")" = "../.orca/secrets/.env" ]
  [ "$(cat "$BATS_TEST_TMPDIR/r/orca-x/.env")" = "LIVE=1" ]
  # a re-run recognizes its own chained link
  run secrets place "$BATS_TEST_TMPDIR/r/orca-x"
  has_line $'OK:\t.env'
  refute_line 'RELINKED:'
}

@test "a run worktree follows the user's file through a write-then-rename" {
  make_linked_layout "$BATS_TEST_TMPDIR/r"
  secrets place "$BATS_TEST_TMPDIR/r/orca-x" >/dev/null
  echo 'LIVE=2' >"$BATS_TEST_TMPDIR/r/main/.env.tmp"
  mv "$BATS_TEST_TMPDIR/r/main/.env.tmp" "$BATS_TEST_TMPDIR/r/main/.env"
  [ "$(cat "$BATS_TEST_TMPDIR/r/orca-x/.env")" = "LIVE=2" ]
}

@test "the worktree holding a linked entry's file is its source, untouched" {
  make_linked_layout "$BATS_TEST_TMPDIR/r"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SOURCE:\t.env'
  refute_line 'SKIPPED_EXISTS:'
  [ ! -L "$BATS_TEST_TMPDIR/r/main/.env" ]
  [ "$(cat "$BATS_TEST_TMPDIR/r/main/.env")" = "LIVE=1" ]
  # remove never strips the source either
  run secrets remove "$BATS_TEST_TMPDIR/r/main"
  has_line $'UNPLACED_TOTAL:\t0'
  [ -f "$BATS_TEST_TMPDIR/r/main/.env" ]
}

@test "a nested linked entry places at the right depth" {
  make_linked_layout "$BATS_TEST_TMPDIR/r"
  ( cd "$BATS_TEST_TMPDIR/r/main" &&
    mkdir -p apps/api && echo '.env' >apps/api/.gitignore &&
    git add apps/api/.gitignore && git commit -qm nested &&
    echo 'API=1' >apps/api/.env )
  git -C "$BATS_TEST_TMPDIR/r/orca-x" merge -q main
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/secrets/apps/api"
  ln -s ../../../../main/apps/api/.env "$BATS_TEST_TMPDIR/r/.orca/secrets/apps/api/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/orca-x"
  [ "$status" -eq 0 ]
  has_line $'LINKED:\tapps/api/.env'
  [ "$(cat "$BATS_TEST_TMPDIR/r/orca-x/apps/api/.env")" = "API=1" ]
}

@test "a dangling entry is never placed and its placement is removed" {
  make_linked_layout "$BATS_TEST_TMPDIR/r"
  secrets place "$BATS_TEST_TMPDIR/r/orca-x" >/dev/null
  rm "$BATS_TEST_TMPDIR/r/main/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/orca-x"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_DANGLING:\t.env'
  refute_line 'SKIPPED_GONE:'
  [ ! -L "$BATS_TEST_TMPDIR/r/orca-x/.env" ]
  # placing into the source worktree must not close a link loop
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  has_line $'SKIPPED_DANGLING:\t.env'
  [ ! -L "$BATS_TEST_TMPDIR/r/main/.env" ]
  [ ! -e "$BATS_TEST_TMPDIR/r/main/.env" ]
}

@test "a link loop between the store and a worktree is reported dangling" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  ln -s ../.orca/secrets/.env "$BATS_TEST_TMPDIR/r/main/.env"
  ln -s ../../main/.env "$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_DANGLING:\t.env'
}

@test "remove strips a chained placement and leaves the user's file" {
  make_linked_layout "$BATS_TEST_TMPDIR/r"
  secrets place "$BATS_TEST_TMPDIR/r/orca-x" >/dev/null
  run secrets remove "$BATS_TEST_TMPDIR/r/orca-x"
  [ "$status" -eq 0 ]
  has_line $'UNPLACED:\t.env'
  [ ! -L "$BATS_TEST_TMPDIR/r/orca-x/.env" ]
  [ "$(cat "$BATS_TEST_TMPDIR/r/main/.env")" = "LIVE=1" ]
}

# ---- status ----

@test "status reports entries, copies, and unlinked env files in the default worktree" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  r="$BATS_TEST_TMPDIR/r"
  ( cd "$r/main" &&
    printf '.env*\n!.env.example\nnode_modules/\n' >.gitignore &&
    mkdir -p apps/api && echo 'ex' >.env.example &&
    git add .gitignore .env.example && git commit -qm ignores )
  echo 'A=1' >"$r/main/.env";              echo 'A=1' >"$r/.orca/secrets/.env"
  echo 'B=new' >"$r/main/.env.local";      echo 'B=old' >"$r/.orca/secrets/.env.local"
  echo 'C=1' >"$r/main/apps/api/.env"
  echo 'D=1' >"$r/main/.env.test"
  ln -s ../../main/.env.test "$r/.orca/secrets/.env.test"
  ln -s ../../main/.env.gone "$r/.orca/secrets/.env.gone"
  mkdir -p "$r/main/node_modules/pkg" && echo 'x' >"$r/main/node_modules/pkg/.env"
  echo 'x' >"$r/main/.env.sample"
  cd "$r"
  run secrets status
  [ "$status" -eq 0 ]
  has_line "DEFAULT_WORKTREE:"$'\t'"$(cd "$r/main" && pwd -P)"
  has_line $'ENTRY:\t.env\tFILE'
  has_line $'COPY:\t.env\tSAME\t../../main/.env'
  has_line $'COPY:\t.env.local\tDIFFERS\t../../main/.env.local'
  has_line $'ENTRY:\t.env.test\tLINK\t../../main/.env.test'
  has_line $'ENTRY:\t.env.gone\tDANGLING\t../../main/.env.gone'
  has_line $'UNLINKED:\tapps/api/.env\t../../../../main/apps/api/.env'
  refute_line $'UNLINKED:\t.env.test'
  refute_line $'UNLINKED:\tnode_modules'
  refute_line $'UNLINKED:\t.env.sample'
  refute_line $'UNLINKED:\t.env.example'
  has_line $'ENTRIES:\t4\tCOPIES:\t2\tUNLINKED:\t1'
}

@test "status in a conventional checkout links to the checkout root" {
  make_repo "$BATS_TEST_TMPDIR/c"
  ( cd "$BATS_TEST_TMPDIR/c" && echo '.env' >.gitignore &&
    git add .gitignore && git commit -qm ignore && echo 'A=1' >.env )
  cd "$BATS_TEST_TMPDIR/c"
  run secrets status
  [ "$status" -eq 0 ]
  has_line $'UNLINKED:\t.env\t../../.env'
  has_line $'ENTRIES:\t0\tCOPIES:\t0\tUNLINKED:\t1'
  # read-only: no exclude written, no store created
  [ ! -e "$BATS_TEST_TMPDIR/c/.orca" ]
}

@test "status with the default branch checked out nowhere reports -" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r/main" checkout -q -b other
  echo 'A=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run secrets status "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line $'DEFAULT_WORKTREE:\t-'
  has_line $'ENTRY:\t.env\tFILE'
  refute_line 'COPY:'
}

@test "dangling secrets link whose source is gone is swept" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  secrets place "$BATS_TEST_TMPDIR/r/main" >/dev/null
  rm "$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_GONE:\t.env'
  [ ! -L "$BATS_TEST_TMPDIR/r/main/.env" ]
}

@test "sweep leaves dangling links that are not secrets placements alone" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  ln -s /nonexistent-target "$BATS_TEST_TMPDIR/r/main/dead-link"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  [ -L "$BATS_TEST_TMPDIR/r/main/dead-link" ]
}

@test "sweep does not descend into .git or .orca" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  # a conventional-layout repo whose root holds .orca — the prune must
  # protect links under it
  make_repo "$BATS_TEST_TMPDIR/c"
  mkdir -p "$BATS_TEST_TMPDIR/c/.orca/secrets"
  ln -s /gone "$BATS_TEST_TMPDIR/c/.orca/keep-me"
  ln -s /gone "$BATS_TEST_TMPDIR/c/.git/keep-me-too"
  run secrets place "$BATS_TEST_TMPDIR/c"
  [ "$status" -eq 0 ]
  [ -L "$BATS_TEST_TMPDIR/c/.orca/keep-me" ]
  [ -L "$BATS_TEST_TMPDIR/c/.git/keep-me-too" ]
}

@test "a link into another repo's secrets tree is never repaired or replaced" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  make_secrets_layout "$BATS_TEST_TMPDIR/other"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  echo 'FOREIGN=1' >"$BATS_TEST_TMPDIR/other/.orca/secrets/.env"
  ln -s "$BATS_TEST_TMPDIR/other/.orca/secrets/.env" "$BATS_TEST_TMPDIR/r/main/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_EXISTS:\t.env'
  [ "$(readlink "$BATS_TEST_TMPDIR/r/main/.env")" = "$BATS_TEST_TMPDIR/other/.orca/secrets/.env" ]
}

@test "sweep leaves a dangling link into another repo's secrets alone" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  ln -s "$BATS_TEST_TMPDIR/gone-repo/.orca/secrets/.env" "$BATS_TEST_TMPDIR/r/main/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  refute_line 'SKIPPED_GONE:'
  [ -L "$BATS_TEST_TMPDIR/r/main/.env" ]
}

@test "sweep leaves a backup.orca look-alike path alone" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  # the old substring test (*.orca/secrets/*) matched this and deleted it
  ln -s "$BATS_TEST_TMPDIR/backup.orca/secrets/x" "$BATS_TEST_TMPDIR/r/main/x"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  refute_line 'SKIPPED_GONE:'
  [ -L "$BATS_TEST_TMPDIR/r/main/x" ]
}

@test "an absolute link to the exact right secret is normalized, not skipped" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  ln -s "$BATS_TEST_TMPDIR/r/.orca/secrets/.env" "$BATS_TEST_TMPDIR/r/main/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'RELINKED:\t.env'
  [ "$(readlink "$BATS_TEST_TMPDIR/r/main/.env")" = "../.orca/secrets/.env" ]
}

@test "a repo path containing glob metacharacters still sweeps correctly" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r[1]"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r[1]/.orca/secrets/.env"
  secrets place "$BATS_TEST_TMPDIR/r[1]/main" >/dev/null
  rm "$BATS_TEST_TMPDIR/r[1]/.orca/secrets/.env"
  # a protected link under .orca must survive the sweep despite the [ in
  # the -path pattern; the placed dangling link must still be swept
  mkdir -p "$BATS_TEST_TMPDIR/r[1]/main/.orca"
  ln -s /gone "$BATS_TEST_TMPDIR/r[1]/main/.orca/keep"
  run secrets place "$BATS_TEST_TMPDIR/r[1]/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_GONE:\t.env'
  [ ! -L "$BATS_TEST_TMPDIR/r[1]/main/.env" ]
  [ -L "$BATS_TEST_TMPDIR/r[1]/main/.orca/keep" ]
}

@test "place git-excludes the secrets tree in a conventional checkout" {
  make_repo "$BATS_TEST_TMPDIR/c"
  mkdir -p "$BATS_TEST_TMPDIR/c/.orca/secrets"
  echo 'x' >"$BATS_TEST_TMPDIR/c/.orca/secrets/x"
  cd "$BATS_TEST_TMPDIR/c"
  run secrets place "$BATS_TEST_TMPDIR/c"
  [ "$status" -eq 0 ]
  git check-ignore -q .orca/secrets/x
}

@test "remove strips only our placement links" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  secrets place "$BATS_TEST_TMPDIR/r/main" >/dev/null
  ln -s /somewhere-else "$BATS_TEST_TMPDIR/r/main/foreign-link"
  run secrets remove "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'UNPLACED:\t.env'
  has_line $'UNPLACED_TOTAL:\t1'
  [ ! -L "$BATS_TEST_TMPDIR/r/main/.env" ]
  [ -L "$BATS_TEST_TMPDIR/r/main/foreign-link" ]
  # the canonical secret survives; a later place restores the link
  [ -f "$BATS_TEST_TMPDIR/r/.orca/secrets/.env" ]
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  has_line $'LINKED:\t.env'
}

@test "remove sweeps our dangling links too" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  secrets place "$BATS_TEST_TMPDIR/r/main" >/dev/null
  rm "$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run secrets remove "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'UNPLACED:\t.env'
  [ ! -L "$BATS_TEST_TMPDIR/r/main/.env" ]
}

@test "misuse fails typed: bad args and non-worktree" {
  run secrets place
  assert_fail_reason BAD_ARGS
  mkdir "$BATS_TEST_TMPDIR/plain"
  run secrets place "$BATS_TEST_TMPDIR/plain"
  assert_fail_reason NOT_GIT
  run secrets status a b
  assert_fail_reason BAD_ARGS
  run secrets status "$BATS_TEST_TMPDIR/plain"
  assert_fail_reason NOT_GIT
}

# ---- link: writing what status offers ----

# make_link_layout <dir> — a bare layout whose main/ ignores env files
# and node_modules, with a nested package directory.
make_link_layout() {
  make_secrets_layout "$1"
  ( cd "$1/main" &&
    printf '.env*\n!.env.example\nnode_modules/\nconfig/local.json\n' >.gitignore &&
    mkdir -p apps/api config && echo '{}' >config/base.json &&
    git add .gitignore config/base.json && git commit -qm ignores )
}

@test "link writes a nested UNLINKED entry, creating parents, as a resolving relative link" {
  r="$BATS_TEST_TMPDIR/r"
  make_link_layout "$r"
  echo 'C=1' >"$r/main/apps/api/.env"
  cd "$r"
  run secrets link apps/api/.env
  [ "$status" -eq 0 ]
  has_line $'LINKED:\tapps/api/.env\t../../../../main/apps/api/.env'
  has_line $'LINKED_TOTAL:\t1\tREFUSED:\t0'
  [ -L "$r/.orca/secrets/apps/api/.env" ]
  [ "$(readlink "$r/.orca/secrets/apps/api/.env")" = "../../../../main/apps/api/.env" ]
  [ "$(cat "$r/.orca/secrets/apps/api/.env")" = "C=1" ]
  # status now sees a LINK entry and offers nothing
  run secrets status
  has_line $'ENTRY:\tapps/api/.env\tLINK\t../../../../main/apps/api/.env'
  refute_line 'UNLINKED:'
}

@test "link replaces an eligible SAME copy with the link" {
  r="$BATS_TEST_TMPDIR/r"
  make_link_layout "$r"
  echo 'A=1' >"$r/main/.env"; echo 'A=1' >"$r/.orca/secrets/.env"
  run secrets link .env --dir "$r"
  [ "$status" -eq 0 ]
  has_line $'RELINKED:\t.env\t../../main/.env'
  [ -L "$r/.orca/secrets/.env" ]
  [ "$(cat "$r/.orca/secrets/.env")" = "A=1" ]
  # no temporary link left beside it
  [ "$(ls -A "$r/.orca/secrets")" = ".env" ]
}

@test "link refuses a non-env SAME copy: it stays a copy" {
  r="$BATS_TEST_TMPDIR/r"
  make_link_layout "$r"
  echo '{"k":1}' >"$r/main/config/local.json"
  mkdir -p "$r/.orca/secrets/config"
  echo '{"k":1}' >"$r/.orca/secrets/config/local.json"
  run secrets status "$r"
  has_line $'COPY:\tconfig/local.json\tSAME'
  run secrets link config/local.json --dir "$r"
  [ "$status" -eq 0 ]
  has_line $'REFUSED:\tconfig/local.json\tNOT_OFFERED'
  has_line $'LINKED_TOTAL:\t0\tREFUSED:\t1'
  [ -f "$r/.orca/secrets/config/local.json" ]
  [ ! -L "$r/.orca/secrets/config/local.json" ]
}

@test "link refuses a path below a symlinked store parent and writes nothing outside" {
  r="$BATS_TEST_TMPDIR/r"
  make_link_layout "$r"
  echo 'C=1' >"$r/main/apps/api/.env"
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  ln -s "$BATS_TEST_TMPDIR/outside" "$r/.orca/secrets/apps"
  # status still offers it: its scan looks only at the final entry
  run secrets status "$r"
  has_line $'UNLINKED:\tapps/api/.env'
  run secrets link apps/api/.env --dir "$r"
  [ "$status" -eq 0 ]
  has_line $'REFUSED:\tapps/api/.env\tIRREGULAR_PARENT'
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/outside")" ]
}

@test "link refuses by name, one path at a time, without stopping the rest" {
  r="$BATS_TEST_TMPDIR/r"
  make_link_layout "$r"
  echo 'B=new' >"$r/main/.env.local"; echo 'B=old' >"$r/.orca/secrets/.env.local"
  echo 'ex' >"$r/main/.env.example"
  ( cd "$r/main" && git add .env.example && git commit -qm example )
  echo 'x' >"$r/main/notes.txt"
  echo '{"k":1}' >"$r/main/config/local.json"
  mkdir -p "$r/main/node_modules/pkg" && echo 'x' >"$r/main/node_modules/pkg/.env"
  echo 'T=1' >"$r/main/.env.test"
  ln -s /somewhere/else "$r/.orca/secrets/.env.test"
  echo 'only-store' >"$r/.orca/secrets/.env.store"
  echo 'G=1' >"$r/main/.env.good"
  run secrets link .env.local .env.example notes.txt config/local.json seed.txt \
    node_modules/pkg/.env .env.test .env.store .env.missing .env.good --dir "$r"
  [ "$status" -eq 0 ]
  has_line $'REFUSED:\t.env.local\tCOPY_DIFFERS'
  has_line $'REFUSED:\t.env.example\tNOT_OFFERED'             # tracked
  has_line $'REFUSED:\tnotes.txt\tNOT_OFFERED'                # unignored
  has_line $'REFUSED:\tconfig/local.json\tNOT_OFFERED'        # ignored, not an env name
  has_line $'REFUSED:\tseed.txt\tNOT_OFFERED'                 # tracked, not an env name
  has_line $'REFUSED:\tnode_modules/pkg/.env\tNOT_OFFERED'    # inside an ignored directory
  has_line $'REFUSED:\t.env.test\tENTRY_EXISTS'
  has_line $'REFUSED:\t.env.store\tENTRY_EXISTS'
  has_line $'REFUSED:\t.env.missing\tSOURCE_GONE'
  has_line $'LINKED:\t.env.good\t../../main/.env.good'
  has_line $'LINKED_TOTAL:\t1\tREFUSED:\t9'
  [ "$(cat "$r/.orca/secrets/.env.local")" = "B=old" ]
  [ ! -e "$r/.orca/secrets/notes.txt" ]
  [ ! -e "$r/.orca/secrets/node_modules" ]
}

@test "link misuse fails typed: no relpath, absolute, dot-dot, no default worktree" {
  r="$BATS_TEST_TMPDIR/r"
  make_link_layout "$r"
  echo 'A=1' >"$r/main/.env"
  run secrets link --dir "$r"
  assert_fail_reason BAD_ARGS
  run secrets link "$r/main/.env" --dir "$r"
  assert_fail_reason BAD_ARGS
  run secrets link ../main/.env --dir "$r"
  assert_fail_reason BAD_ARGS
  run secrets link apps/../.env --dir "$r"
  assert_fail_reason BAD_ARGS
  run secrets link .env --dir
  assert_fail_reason BAD_ARGS
  mkdir "$BATS_TEST_TMPDIR/plain"
  run secrets link .env --dir "$BATS_TEST_TMPDIR/plain"
  assert_fail_reason NOT_GIT
  [ ! -e "$r/.orca/secrets/.env" ]
  git -C "$r/main" checkout -q -b other
  run secrets link .env --dir "$r"
  assert_fail_reason NO_DEFAULT_WORKTREE
  [ ! -e "$r/.orca/secrets/.env" ]
}

@test "link is idempotent: a re-run is all OK" {
  r="$BATS_TEST_TMPDIR/r"
  make_link_layout "$r"
  echo 'A=1' >"$r/main/.env"; echo 'C=1' >"$r/main/apps/api/.env"
  secrets link .env apps/api/.env --dir "$r" >/dev/null
  run secrets link .env apps/api/.env --dir "$r"
  [ "$status" -eq 0 ]
  has_line $'OK:\t.env'
  has_line $'OK:\tapps/api/.env'
  refute_line 'LINKED:'
  has_line $'LINKED_TOTAL:\t2\tREFUSED:\t0'
}

@test "link gives the same result from main/, the root, and a subdirectory" {
  for from in main . main/apps/api; do
    r="$BATS_TEST_TMPDIR/r-${from//\//-}"
    make_link_layout "$r"
    echo 'C=1' >"$r/main/apps/api/.env"
    cd "$r/$from"
    run secrets link apps/api/.env
    [ "$status" -eq 0 ]
    has_line $'LINKED:\tapps/api/.env\t../../../../main/apps/api/.env'
    [ "$(cat "$r/.orca/secrets/apps/api/.env")" = "C=1" ]
  done
}

@test "link in a conventional checkout creates and excludes the store" {
  c="$BATS_TEST_TMPDIR/c"
  make_repo "$c"
  ( cd "$c" && echo '.env' >.gitignore &&
    git add .gitignore && git commit -qm ignore && echo 'A=1' >.env )
  cd "$c"
  run secrets link .env
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.env\t../../.env'
  [ "$(cat "$c/.orca/secrets/.env")" = "A=1" ]
  git check-ignore -q .orca/secrets/.env
}

@test "place over linked entries links worktrees as before" {
  r="$BATS_TEST_TMPDIR/r"
  make_link_layout "$r"
  echo 'A=1' >"$r/main/.env"; echo 'C=1' >"$r/main/apps/api/.env"
  secrets link .env apps/api/.env --dir "$r" >/dev/null
  git -C "$r/main" worktree add -q "$r/orca-x" -b orca/x
  run secrets place "$r/orca-x"
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.env'
  has_line $'LINKED:\tapps/api/.env'
  [ "$(readlink "$r/orca-x/apps/api/.env")" = "../../../.orca/secrets/apps/api/.env" ]
  [ "$(cat "$r/orca-x/apps/api/.env")" = "C=1" ]
  # the default worktree is the entries' source: untouched
  run secrets place "$r/main"
  has_line $'SOURCE:\t.env'
  [ ! -L "$r/main/.env" ]
}

@test "link: an existing link whose file is gone, or no longer offered, is not OK" {
  r="$BATS_TEST_TMPDIR/r"
  make_link_layout "$r"
  echo 'A=1' >"$r/main/.env"; echo 'T=1' >"$r/main/.env.test"
  run secrets link .env .env.test --dir "$r"
  has_line $'LINKED_TOTAL:\t2\tREFUSED:\t0'
  # the user's file goes away between two calls: status says DANGLING, link must not say OK
  rm "$r/main/.env"
  # and another becomes tracked: no longer something link would offer
  ( cd "$r/main" && git add -f .env.test && git commit -qm track )
  run secrets link .env .env.test --dir "$r"
  [ "$status" -eq 0 ]
  has_line $'REFUSED:\t.env\tSOURCE_GONE'
  has_line $'REFUSED:\t.env.test\tNOT_OFFERED'
  refute_line 'OK:'
  has_line $'LINKED_TOTAL:\t0\tREFUSED:\t2'
  run secrets status "$r"
  has_line $'ENTRY:\t.env\tDANGLING'
  # nothing was removed or rewritten
  [ -L "$r/.orca/secrets/.env" ] && [ -L "$r/.orca/secrets/.env.test" ]
}

@test "status marks LINKABLE exactly the SAME copies link accepts: a tracked env-named copy is not one" {
  r="$BATS_TEST_TMPDIR/r"
  make_link_layout "$r"
  echo 'A=1' >"$r/main/.env";        echo 'A=1' >"$r/.orca/secrets/.env"
  echo 'T=1' >"$r/main/.env.test";   echo 'T=1' >"$r/.orca/secrets/.env.test"
  echo 'B=new' >"$r/main/.env.local"; echo 'B=old' >"$r/.orca/secrets/.env.local"
  echo '{"k":1}' >"$r/main/config/local.json"
  mkdir -p "$r/.orca/secrets/config"; echo '{"k":1}' >"$r/.orca/secrets/config/local.json"
  ( cd "$r/main" && git add -f .env.test && git commit -qm track )
  run secrets status "$r"
  [ "$status" -eq 0 ]
  has_line $'COPY:\t.env\tSAME'
  has_line $'COPY:\t.env.test\tSAME'
  has_line $'COPY:\tconfig/local.json\tSAME'
  has_line $'LINKABLE:\t.env\t../../main/.env'
  refute_line $'LINKABLE:\t.env.test'      # env-named, but tracked
  refute_line $'LINKABLE:\t.env.local'     # drifted
  refute_line $'LINKABLE:\tconfig'         # not an env file
  # the offer and the verb agree, path for path
  run secrets link .env .env.test config/local.json --dir "$r"
  has_line $'RELINKED:\t.env\t../../main/.env'
  has_line $'REFUSED:\t.env.test\tNOT_OFFERED'
  has_line $'REFUSED:\tconfig/local.json\tNOT_OFFERED'
}
