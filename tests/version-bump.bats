#!/usr/bin/env bats
# version-bump.sh — sizing from shipped-touching commits, footer-token
# breaking detection. Pushes go to a local bare origin.

load helpers

BUMP="$ORCA_ROOT/.github/scripts/version-bump.sh"

# A repo with the manifest at 1.0.0 and a local bare origin to push to.
make_release_repo() { # <dir>
  make_repo "$1"
  git init -q --bare "$1-origin.git"
  git -C "$1" remote add origin "$1-origin.git"
  mkdir -p "$1/.claude-plugin"
  printf '{"name": "orca", "version": "1.0.0"}\n' >"$1/.claude-plugin/plugin.json"
  git -C "$1" add -A
  git -C "$1" commit -qm 'chore: manifest'
  git -C "$1" push -q origin HEAD:main
}

version_now() { sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' .claude-plugin/plugin.json; }

@test "no shipped changes is a no-op" {
  make_release_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  echo doc >README.md && git add -A && git commit -qm 'feat: readme only'
  run bash "$BUMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
  [ "$(version_now)" = "1.0.0" ]
}

@test "a feat touching shipped files bumps minor" {
  make_release_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p scripts && echo x >scripts/x.sh && git add -A && git commit -qm 'feat: new script'
  run bash "$BUMP"
  [ "$status" -eq 0 ]
  [ "$(version_now)" = "1.1.0" ]
}

@test "a change to the hooks module alone bumps" {
  make_release_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p hooks && echo x >hooks/run-band.tsx && git add -A && git commit -qm 'fix: band width'
  run bash "$BUMP"
  [ "$status" -eq 0 ]
  [ "$(version_now)" = "1.0.1" ]
}

@test "a non-shipped feat does not size a shipped chore's bump" {
  make_release_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p scripts && echo x >scripts/x.sh && git add -A && git commit -qm 'chore: tweak script'
  echo doc >README.md && git add -A && git commit -qm 'feat: shiny docs'
  run bash "$BUMP"
  [ "$status" -eq 0 ]
  [ "$(version_now)" = "1.0.1" ]
}

@test "BREAKING CHANGE mid-body prose does not major; a footer does" {
  make_release_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p scripts && echo x >scripts/x.sh && git add -A
  git commit -qm 'chore: tweak' -m 'This mentions
BREAKING CHANGE: only as prose, mid-body.

And then continues with a final paragraph.'
  run bash "$BUMP"
  [ "$status" -eq 0 ]
  [ "$(version_now)" = "1.0.1" ]
  echo y >scripts/y.sh && git add -A
  git commit -qm 'fix: another' -m 'Body text.' -m 'BREAKING CHANGE: the contract moved'
  run bash "$BUMP"
  [ "$status" -eq 0 ]
  [ "$(version_now)" = "2.0.0" ]
}

@test "a subject bang bumps major" {
  make_release_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p agents && echo x >agents/x.md && git add -A && git commit -qm 'feat!: rework'
  run bash "$BUMP"
  [ "$status" -eq 0 ]
  [ "$(version_now)" = "2.0.0" ]
}
