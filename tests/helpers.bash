# Shared Bats helpers — hermetic git-repo fixtures and typed-line asserts.
#
# Every test repo lives under BATS_TEST_TMPDIR, with HOME and both git
# config scopes pointed away from the developer's real environment, so a
# user's ~/.gitconfig (aliases, hooks, fsmonitor) can never leak into a
# test. Scripts are addressed absolutely via $SCRIPTS.

ORCA_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS="$ORCA_ROOT/scripts"

setup() {
  # Canonicalize: on macOS the temp dir lives behind a /var → /private/var
  # symlink, and the scripts emit git-resolved (physical) paths — every
  # $BATS_TEST_TMPDIR/$PWD-based expectation must be physical too.
  BATS_TEST_TMPDIR="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  # The runtime envelope is bash 3.2 + git + coreutils: python3 is
  # poisoned for every test, so any script call to it fails loudly
  # instead of passing on a dev machine that happens to have it.
  mkdir -p "$BATS_TEST_TMPDIR/envelope-bin"
  printf '#!/bin/sh\necho "python3 called — the orca envelope forbids it" >&2\nexit 127\n' \
    >"$BATS_TEST_TMPDIR/envelope-bin/python3"
  chmod +x "$BATS_TEST_TMPDIR/envelope-bin/python3"
  export PATH="$BATS_TEST_TMPDIR/envelope-bin:$PATH"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME="orca test" GIT_AUTHOR_EMAIL="orca-test@example.invalid"
  export GIT_COMMITTER_NAME="orca test" GIT_COMMITTER_EMAIL="orca-test@example.invalid"
}

# make_repo <dir> — conventional repo with one commit (seed.txt).
make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  echo seed >"$1/seed.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm seed
}

# make_bare_layout <dir> — the bare-with-worktrees layout orca:init
# produces: .bare + .git pointer at the root, a main worktree, .orca/
# beside them, and .env ignored via a tracked .gitignore.
make_bare_layout() {
  make_repo "$1"
  ( cd "$1" &&
    echo '.env' >.gitignore &&
    git add .gitignore && git commit -qm gitignore &&
    mv .git .bare &&
    git --git-dir=.bare config core.bare true &&
    printf 'gitdir: ./.bare\n' >.git &&
    git worktree add main main >/dev/null 2>&1 )
  mkdir -p "$1/.orca"
}

# make_codex_stub <bindir> <version> <ok|denied> [legacy] — a fake codex
# CLI whose --version, `login status`, and `exec --help` behavior the test
# controls. Prepend <bindir> to PATH; an empty version models a
# broken/absent binary. A fourth argument of `legacy` makes `codex exec
# --help` advertise none of the flags orca.sh codex drives — the shape of
# the real 0.155.1 break, where version and auth both looked fine and only
# the interface had moved.
make_codex_stub() {
  mkdir -p "$1"
  cat >"$1/codex" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version) echo "codex-cli $2" ;;
  login)     [[ "$3" == ok ]] && exit 0 || exit 1 ;;
  exec)
    if [[ "${4:-modern}" == legacy ]]; then
      echo "Usage: codex exec [OPTIONS] [PROMPT]"
    else
      echo "Usage: codex exec [OPTIONS] [PROMPT]"
      echo "  -s, --sandbox <SANDBOX_MODE>"
      echo "  -C, --cd <DIR>"
      echo "      --output-schema <FILE>"
      echo "  -o, --output-last-message <FILE>"
    fi
    ;;
esac
EOF
  chmod +x "$1/codex"
}

# has_line <fixed-string> — $output contains a line starting with it.
# Typed contract lines are TAB-separated; write the TAB as $'\t' at the
# call site: has_line $'MOVED:\t3'.
has_line() {
  local line
  while IFS= read -r line; do
    [[ "$line" == "$1"* ]] && return 0
  done <<<"$output"
  echo "expected a line starting with: $1" >&2
  echo "actual output:" >&2
  printf '%s\n' "$output" >&2
  return 1
}

# refute_line <fixed-string> — no line of $output starts with it.
refute_line() {
  local line
  while IFS= read -r line; do
    if [[ "$line" == "$1"* ]]; then
      echo "unexpected line: $line" >&2
      return 1
    fi
  done <<<"$output"
  return 0
}

# assert_fail_reason <reason> — a typed FAIL: line with this reason exists
# and the exit status was 1.
assert_fail_reason() {
  [[ "$status" -eq 1 ]] || { echo "expected exit 1, got $status" >&2; return 1; }
  has_line $'FAIL:\t'"$1"$'\t'
}
