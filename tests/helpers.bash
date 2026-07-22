# Shared Bats helpers — hermetic git-repo fixtures and typed-line asserts.
#
# Every test repo lives under BATS_TEST_TMPDIR, with HOME and both git
# config scopes pointed away from the developer's real environment, so a
# user's ~/.gitconfig (aliases, hooks, fsmonitor) can never leak into a
# test. Scripts are addressed absolutely via $SCRIPTS.

ORCA_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS="$ORCA_ROOT/scripts"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
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
    /usr/bin/mv .git .bare &&
    git --git-dir=.bare config core.bare true &&
    printf 'gitdir: ./.bare\n' >.git &&
    git worktree add main main >/dev/null 2>&1 )
  mkdir -p "$1/.orca"
}

# make_codex_stub <bindir> <version> <ok|denied> — a fake codex CLI whose
# --version and `login status` behavior the test controls. Prepend
# <bindir> to PATH; an empty version models a broken/absent binary.
make_codex_stub() {
  mkdir -p "$1"
  cat >"$1/codex" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version) echo "codex-cli $2" ;;
  login)     [[ "$3" == ok ]] && exit 0 || exit 1 ;;
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
