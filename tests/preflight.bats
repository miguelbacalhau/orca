#!/usr/bin/env bats
# orca.sh preflight — gates, reviewer resolution, codex checks (stubbed CLI).

load helpers

# Run preflight with a controlled codex stub prepended to PATH.
preflight_with_codex() { # <version> <ok|denied> [legacy]
  make_codex_stub "$BATS_TEST_TMPDIR/stub" "$1" "$2" "${3:-modern}"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" preflight
}

# The stranded-install test (a preflight copied away from orca.sh
# failing typed NO_PLUGIN_ROOT) is gone with the fold: its failure
# condition is unreachable through the only remaining entry point —
# dispatch itself proves the dispatcher exists.
@test "the plugin-shipped CLI passes the PLUGIN_ROOT gate" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  preflight_with_codex "" denied
  [ "$status" -eq 0 ]
  has_line 'PLUGIN_ROOT: PASS'
}

@test "conventional checkout fails the bare gate" {
  make_repo "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  preflight_with_codex "" denied
  [ "$status" -eq 1 ]
  has_line 'BARE_REPO: FAIL'
  has_line 'RESULT: FAIL'
}

@test "bare layout with no usable codex detects claude and passes" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  preflight_with_codex "" denied
  [ "$status" -eq 0 ]
  has_line 'BARE_REPO: PASS'
  has_line 'TRUNK_CANDIDATE: main'
  has_line 'REVIEWER: claude (detected)'
  has_line 'CODEX: SKIPPED: reviewer is claude'
  has_line 'RESULT: PASS'
}

@test "a modern codex on PATH is detected as the reviewer" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  mkdir -p .claude
  printf '{"env":{"BASH_MAX_TIMEOUT_MS":"1200000"}}\n' >.claude/settings.json
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 0 ]
  has_line 'REVIEWER: codex (detected)'
  has_line 'CODEX: PASS'
  has_line 'RESULT: PASS'
}

@test "an outdated codex is never silently used: detection falls to claude" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  preflight_with_codex 0.1.0 ok
  [ "$status" -eq 0 ]
  has_line 'REVIEWER: claude (detected)'
}

@test "pinned codex with an outdated binary fails loud, no silent downgrade" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  preflight_with_codex 0.1.0 ok
  [ "$status" -eq 1 ]
  has_line 'REVIEWER: codex (pinned)'
  has_line 'CODEX: FAIL'
  has_line 'RESULT: FAIL'
}

@test "pinned codex without auth fails the codex gate" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  preflight_with_codex 999.0.0 denied
  [ "$status" -eq 1 ]
  has_line 'CODEX: FAIL: not authenticated'
}

@test "pinned codex without BASH_MAX_TIMEOUT_MS fails the codex gate" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 1 ]
  has_line 'CODEX: FAIL: BASH_MAX_TIMEOUT_MS'
}

# A key that is present but too small is the silent version of the same
# failure: CODEX: PASS, and every review killed seconds in.
@test "a BASH_MAX_TIMEOUT_MS below the review budget fails the codex gate" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  mkdir -p .claude
  printf '{"env":{"BASH_MAX_TIMEOUT_MS":"1000"}}\n' >.claude/settings.json
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 1 ]
  has_line 'CODEX: FAIL: BASH_MAX_TIMEOUT_MS is 1000, below the 1200000'
}

# An unquoted number is just as valid in settings.json, and must pass.
@test "an unquoted BASH_MAX_TIMEOUT_MS at the budget passes" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  mkdir -p .claude
  printf '{"env":{"BASH_MAX_TIMEOUT_MS": 1200000}}\n' >.claude/settings.json
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 0 ]
  has_line 'CODEX: PASS'
}

# The 0.155.1 regression in miniature: a new, authenticated codex whose
# `codex exec` no longer carries the flags orca.sh codex drives. Version
# and auth pass; only asking the binary what it speaks catches it.
@test "a codex whose exec interface moved fails the codex gate" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  mkdir -p .claude
  printf '{"env":{"BASH_MAX_TIMEOUT_MS":"1200000"}}\n' >.claude/settings.json
  preflight_with_codex 999.0.0 ok legacy
  [ "$status" -eq 1 ]
  has_line 'CODEX: FAIL: codex 999.0.0 has no '"'"'codex exec'"'"' --output-schema, --output-last-message, --sandbox, --cd'
  has_line 'RESULT: FAIL'
}

@test "an invalid reviewer value fails loud, gate unresolvable" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=gemini\n' >.orca/config
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 1 ]
  has_line 'REVIEWER: FAIL'
  has_line 'CODEX: SKIPPED: reviewer unresolved'
}

@test "pinned reviewer is honored from a worktree subdirectory" {
  # finding 8.3: config paths resolve from CWD, so running anywhere but
  # the repo root silently downgrades a pinned reviewer to detection
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=claude\n' >"$BATS_TEST_TMPDIR/r/.orca/config"
  mkdir -p "$BATS_TEST_TMPDIR/r/main/src"
  cd "$BATS_TEST_TMPDIR/r/main/src"
  preflight_with_codex 999.0.0 ok
  has_line 'REVIEWER: claude (pinned)'
}

@test "a leftover config.json gets the informational OBSOLETE line, never a FAIL" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf '{"reviewer":"codex"}\n' >.orca/config.json
  preflight_with_codex "" denied
  [ "$status" -eq 0 ]
  has_line 'CONFIG: OBSOLETE: .orca/config.json is no longer read'
  # nothing parses it: the pinned-looking value does not pin
  has_line 'REVIEWER: claude (detected)'
  has_line 'RESULT: PASS'
}

@test "settings env blocks are found from a worktree subdirectory" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >"$BATS_TEST_TMPDIR/r/.orca/config"
  mkdir -p "$BATS_TEST_TMPDIR/r/.claude"
  printf '{"env":{"BASH_MAX_TIMEOUT_MS":"1200000"}}\n' >"$BATS_TEST_TMPDIR/r/.claude/settings.json"
  mkdir -p "$BATS_TEST_TMPDIR/r/main/src"
  cd "$BATS_TEST_TMPDIR/r/main/src"
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 0 ]
  has_line 'CODEX: PASS'
}

# ---- where the session stands ----

where() { run bash "$SCRIPTS/orca.sh" preflight where "$@"; }

@test "SESSION names the root, a worktree's top level, or a conventional checkout" {
  r="$BATS_TEST_TMPDIR/r"
  make_bare_layout "$r"
  mkdir -p "$r/main/packages/x"
  cd "$r"
  preflight_with_codex 0.1.0 ok
  has_line $'SESSION:\troot'
  has_line $'ORCA_IN_SCOPE:\tn/a'
  has_line $'DEFAULT_WORKTREE:\t'"$r/main"
  cd "$r/main/packages/x"
  preflight_with_codex 0.1.0 ok
  has_line $'SESSION:\tworktree '"$r/main"
  has_line $'ORCA_IN_SCOPE:\tno'
  make_repo "$BATS_TEST_TMPDIR/c"
  cd "$BATS_TEST_TMPDIR/c"
  preflight_with_codex 0.1.0 ok
  has_line $'SESSION:\tconventional'
  has_line $'ORCA_IN_SCOPE:\tn/a'
  has_line $'DEFAULT_WORKTREE:\t'"$BATS_TEST_TMPDIR/c"
}

@test "ORCA_IN_SCOPE reads the worktree's settings and the user's" {
  r="$BATS_TEST_TMPDIR/r"
  make_bare_layout "$r"
  mkdir -p "$r/main/.claude" "$HOME/.claude"
  cd "$r/main"
  # neither
  where; has_line $'ORCA_IN_SCOPE:\tno'
  # an unrelated directory is not above .orca
  printf '{"permissions":{"additionalDirectories":["/somewhere/else","../main"]}}\n' >.claude/settings.local.json
  where; has_line $'ORCA_IN_SCOPE:\tno'
  # the root, absolute, in the worktree's local settings — pretty-printed
  printf '{\n  "env": {"X": "1"},\n  "permissions": {\n    "allow": ["Bash(ls:*)"],\n    "additionalDirectories": [\n      "/somewhere/else",\n      "%s"\n    ]\n  }\n}\n' "$r" >.claude/settings.local.json
  where; has_line $'ORCA_IN_SCOPE:\tyes'
  # relative, as the worktree's own settings resolve it
  printf '{"permissions":{"additionalDirectories":[".."]}}\n' >.claude/settings.local.json
  where; has_line $'ORCA_IN_SCOPE:\tyes'
  rm .claude/settings.local.json
  # the worktree's shared settings file
  printf '{"permissions":{"additionalDirectories":["%s/"]}}\n' "$r" >.claude/settings.json
  where; has_line $'ORCA_IN_SCOPE:\tyes'
  rm .claude/settings.json
  # the user's: the root itself, or a directory above it
  printf '{"permissions":{"additionalDirectories":["%s"]}}\n' "$r" >"$HOME/.claude/settings.json"
  where; has_line $'ORCA_IN_SCOPE:\tyes'
  printf '{"permissions":{"additionalDirectories":["%s"]}}\n' "$BATS_TEST_TMPDIR" >"$HOME/.claude/settings.json"
  where; has_line $'ORCA_IN_SCOPE:\tyes'
  # a relative entry in the user's settings names nothing here
  printf '{"permissions":{"additionalDirectories":[".."]}}\n' >"$HOME/.claude/settings.json"
  where; has_line $'ORCA_IN_SCOPE:\tno'
  # a root session needs none
  cd "$r"
  where; has_line $'ORCA_IN_SCOPE:\tn/a'
}

@test "ORCA_IN_SCOPE is yes for the repository's .orca or a directory above it, no for one below or beside it" {
  r="$HOME/proj"
  make_bare_layout "$r"
  mkdir -p "$r/main/.claude" "$r/.orca/objectives" "$r/.orca-other"
  cd "$r/main"
  scope_with() { # <entry> — the worktree's local settings hold only it
    printf '{"permissions":{"additionalDirectories":["%s"]}}\n' "$1" >"$r/main/.claude/settings.local.json"
    where
  }
  # .orca itself: absolute, with a trailing slash, relative, ~-spelled
  scope_with "$r/.orca";   has_line $'ORCA_IN_SCOPE:\tyes'
  scope_with "$r/.orca/";  has_line $'ORCA_IN_SCOPE:\tyes'
  scope_with "../.orca";   has_line $'ORCA_IN_SCOPE:\tyes'
  scope_with "~/proj/.orca"; has_line $'ORCA_IN_SCOPE:\tyes'
  # anything above it: the root (an install from before), .., the home directory
  scope_with "$r";         has_line $'ORCA_IN_SCOPE:\tyes'
  scope_with "$r/";        has_line $'ORCA_IN_SCOPE:\tyes'
  scope_with "..";         has_line $'ORCA_IN_SCOPE:\tyes'
  scope_with "~/proj";     has_line $'ORCA_IN_SCOPE:\tyes'
  scope_with "~";          has_line $'ORCA_IN_SCOPE:\tyes'
  # below it, or beside it
  scope_with "$r/.orca/objectives"; has_line $'ORCA_IN_SCOPE:\tno'
  scope_with "../.orca/objectives"; has_line $'ORCA_IN_SCOPE:\tno'
  scope_with "$r/.orca-other";      has_line $'ORCA_IN_SCOPE:\tno'
  scope_with "$r/.bare";            has_line $'ORCA_IN_SCOPE:\tno'
  scope_with "$r/orca-obj";         has_line $'ORCA_IN_SCOPE:\tno'
  scope_with "$r/main";             has_line $'ORCA_IN_SCOPE:\tno'
  # the user's settings: .orca by absolute path
  rm "$r/main/.claude/settings.local.json"
  mkdir -p "$HOME/.claude"
  printf '{"permissions":{"additionalDirectories":["%s/.orca"]}}\n' "$r" >"$HOME/.claude/settings.json"
  where; has_line $'ORCA_IN_SCOPE:\tyes'
  rm "$HOME/.claude/settings.json"
  # a .orca that is a link is matched where it is named and where it leads
  mv "$r/.orca" "$BATS_TEST_TMPDIR/orca-store"
  ln -s "$BATS_TEST_TMPDIR/orca-store" "$r/.orca"
  scope_with "$r/.orca";                    has_line $'ORCA_IN_SCOPE:\tyes'
  scope_with "$BATS_TEST_TMPDIR/orca-store"; has_line $'ORCA_IN_SCOPE:\tyes'
  scope_with "$r";                          has_line $'ORCA_IN_SCOPE:\tyes'
}

@test "from an objective's worktree the scope is unknown, never no, and the codex timeout is taken from the environment" {
  r="$BATS_TEST_TMPDIR/r"
  make_bare_layout "$r"
  printf 'reviewer=codex\n' >"$r/.orca/config"
  mkdir -p "$r/main/.claude"
  printf '{"env":{"BASH_MAX_TIMEOUT_MS":"1200000"},"permissions":{"additionalDirectories":["%s"]}}\n' "$r" \
    >"$r/main/.claude/settings.local.json"
  git -C "$r/main" worktree add -q "$r/orca-obj" -b feature/obj
  mkdir -p "$r/orca-obj/src"
  # the directory the session was started in
  cd "$r/main"
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 0 ]
  has_line 'CODEX: PASS'
  has_line $'ORCA_IN_SCOPE:\tyes'
  # the objective's worktree has no settings of its own: the scope is
  # unknown, and with nothing in the environment the timeout is missed
  cd "$r/orca-obj/src"
  preflight_with_codex 999.0.0 ok
  [ "$status" -eq 1 ]
  has_line $'SESSION:\tworktree '"$r/orca-obj"
  has_line $'ORCA_IN_SCOPE:\t-'
  has_line 'CODEX: FAIL: BASH_MAX_TIMEOUT_MS not set'
  # a session that moved here carries main/'s settings env block in its shell
  BASH_MAX_TIMEOUT_MS=1200000 preflight_with_codex 999.0.0 ok
  [ "$status" -eq 0 ]
  has_line $'ORCA_IN_SCOPE:\t-'
  has_line 'CODEX: PASS'
  # a low value in the environment fails like a low value in a file
  BASH_MAX_TIMEOUT_MS=1000 preflight_with_codex 999.0.0 ok
  [ "$status" -eq 1 ]
  has_line 'CODEX: FAIL: BASH_MAX_TIMEOUT_MS is 1000, below the 1200000'
  # a file that carries the key still decides, whatever the environment says
  mkdir -p "$r/orca-obj/.claude"
  printf '{"env":{"BASH_MAX_TIMEOUT_MS":"1000"}}\n' >"$r/orca-obj/.claude/settings.json"
  BASH_MAX_TIMEOUT_MS=1200000 preflight_with_codex 999.0.0 ok
  [ "$status" -eq 1 ]
  has_line 'CODEX: FAIL: BASH_MAX_TIMEOUT_MS is 1000, below the 1200000'
}

@test "the environment's timeout counts with no settings file at all" {
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  printf 'reviewer=codex\n' >.orca/config
  BASH_MAX_TIMEOUT_MS=1200000 preflight_with_codex 999.0.0 ok
  [ "$status" -eq 0 ]
  has_line 'CODEX: PASS'
}

@test "ORCA_IN_SCOPE from an orca-* worktree is yes when its own or the user's settings say so; a user's own worktree still reads no" {
  r="$BATS_TEST_TMPDIR/r"
  make_bare_layout "$r"
  git -C "$r/main" worktree add -q "$r/orca-obj" -b feature/obj
  git -C "$r/main" worktree add -q "$r/second" -b second
  mkdir -p "$r/orca-obj/.claude" "$HOME/.claude"
  cd "$r/orca-obj"
  where; has_line $'ORCA_IN_SCOPE:\t-'
  printf '{"permissions":{"additionalDirectories":[".."]}}\n' >.claude/settings.local.json
  where; has_line $'ORCA_IN_SCOPE:\tyes'
  rm .claude/settings.local.json
  printf '{"permissions":{"additionalDirectories":["%s"]}}\n' "$r" >"$HOME/.claude/settings.json"
  where; has_line $'ORCA_IN_SCOPE:\tyes'
  rm "$HOME/.claude/settings.json"
  # a worktree of the user's own is not one orca moves a session into
  cd "$r/second"
  where; has_line $'ORCA_IN_SCOPE:\tno'
  # nor is an orca-* directory that is not directly under the root
  git -C "$r/main" worktree add -q "$r/second/orca-nested" -b nested
  cd "$r/second/orca-nested"
  where; has_line $'ORCA_IN_SCOPE:\tno'
}

@test "where explores the session's own worktree before the default one, never an orca-* worktree" {
  r="$BATS_TEST_TMPDIR/r"
  make_bare_layout "$r"
  git -C "$r/main" worktree add -q "$r/second" -b second
  git -C "$r/main" worktree add -q "$r/orca-obj" -b feature/obj
  mkdir -p "$r/second/src" "$r/orca-obj/src"
  # a user's second worktree is explored as it stands
  cd "$r/second/src"
  where
  has_line $'EXPLORE:\t'"$r/second"$'\tsession'
  has_line $'AT_BASE:\tyes'
  # one of orca's is another unit's unfinished branch: the default worktree
  cd "$r/orca-obj/src"
  where
  has_line $'EXPLORE:\t'"$r/main"$'\tdefault'
  # a root session has no worktree of its own
  cd "$r"
  where
  has_line $'EXPLORE:\t'"$r/main"$'\tdefault'
  # the default worktree is the session's own when it stands there
  cd "$r/main"
  where
  has_line $'EXPLORE:\t'"$r/main"$'\tsession'
  # --base still wins, from anywhere
  cd "$r/second"
  where --base feature/obj
  has_line $'EXPLORE:\t'"$r/orca-obj"$'\tbase'
  where --base main
  has_line $'EXPLORE:\t'"$r/main"$'\tbase'
  # an orca-* session with the default branch checked out nowhere: the root
  git -C "$r/main" checkout -q --detach
  cd "$r/orca-obj"
  where
  has_line $'EXPLORE:\t'"$r"$'\troot'
}

@test "the default worktree is where the default branch is checked out, whatever the directory is called" {
  r="$BATS_TEST_TMPDIR/r"
  make_bare_layout "$r"
  cd "$r"
  where
  [ "$status" -eq 0 ]
  has_line $'DEFAULT_WORKTREE:\t'"$r/main"
  has_line $'EXPLORE:\t'"$r/main"$'\tdefault'
  # a worktree whose directory differs from its branch name
  git -C "$r" worktree move main trunk-checkout
  where
  has_line $'DEFAULT_WORKTREE:\t'"$r/trunk-checkout"
  has_line $'EXPLORE:\t'"$r/trunk-checkout"$'\tdefault'
  # the default branch checked out nowhere: the session's own checkout, else the root
  git -C "$r/trunk-checkout" checkout -q -b other
  cd "$r/trunk-checkout"
  where
  has_line $'DEFAULT_WORKTREE:\t-'
  has_line $'EXPLORE:\t'"$r/trunk-checkout"$'\tsession'
  cd "$r"
  where
  has_line $'DEFAULT_WORKTREE:\t-'
  has_line $'EXPLORE:\t'"$r"$'\troot'
  has_line $'UNCOMMITTED_TOTAL:\t-'
}

@test "where reports the build base and what is uncommitted in the directory explored" {
  r="$BATS_TEST_TMPDIR/r"
  make_bare_layout "$r"
  tip="$(git -C "$r/main" rev-parse HEAD)"
  cd "$r/main"
  where
  has_line $'BUILD_BASE:\t'"$tip"$'\tmain'
  has_line $'AT_BASE:\tyes'
  has_line $'UNCOMMITTED_TOTAL:\t0'
  refute_line $'UNCOMMITTED:\t'
  echo helper >"$r/main/helper.sh"
  echo changed >>"$r/main/seed.txt"
  where
  has_line $'UNCOMMITTED:\t?? helper.sh'
  has_line $'UNCOMMITTED:\t M seed.txt'
  has_line $'UNCOMMITTED_TOTAL:\t2'
  mkdir "$BATS_TEST_TMPDIR/plain"
  cd "$BATS_TEST_TMPDIR/plain"
  where
  assert_fail_reason NOT_GIT
}

@test "where --base takes the build base from the named branch, and explores its worktree when it has one" {
  r="$BATS_TEST_TMPDIR/r"
  make_bare_layout "$r"
  trunk_tip="$(git -C "$r/main" rev-parse HEAD)"
  # a follow-up on an unlanded branch, checked out at orca-feat
  git -C "$r/main" worktree add -q "$r/orca-feat" -b feature/feat
  ( cd "$r/orca-feat" && echo more >more.txt && git add more.txt && git commit -qm more )
  feat_tip="$(git -C "$r/orca-feat" rev-parse HEAD)"
  cd "$r/main"
  where --base feature/feat
  [ "$status" -eq 0 ]
  has_line $'EXPLORE:\t'"$r/orca-feat"$'\tbase'
  has_line $'BUILD_BASE:\t'"$feat_tip"$'\tfeature/feat'
  has_line $'AT_BASE:\tyes'
  has_line $'UNCOMMITTED_TOTAL:\t0'
  # the base branch checked out nowhere: the build base is still the branch's
  # tip, the session's own worktree is explored, and the mismatch is stated
  git -C "$r/main" worktree remove "$r/orca-feat"
  where --base feature/feat
  [ "$status" -eq 0 ]
  has_line $'EXPLORE:\t'"$r/main"$'\tsession'
  has_line $'BUILD_BASE:\t'"$feat_tip"$'\tfeature/feat'
  has_line $'AT_BASE:\tno'
  # a confirmed trunk that is not the bare HEAD's branch: its tip, not HEAD's
  git -C "$r/main" branch develop
  git -C "$r/main" worktree add -q "$r/develop" develop
  ( cd "$r/develop" && echo d >d.txt && git add d.txt && git commit -qm d )
  where --base develop
  has_line $'EXPLORE:\t'"$r/develop"$'\tbase'
  has_line $'BUILD_BASE:\t'"$(git -C "$r/develop" rev-parse HEAD)"$'\tdevelop'
  where
  has_line $'BUILD_BASE:\t'"$trunk_tip"$'\tmain'
  # the default branch moved on while main/ sits on another commit
  git -C "$r/main" checkout -q --detach
  ( cd "$r/develop" && git branch -f main develop )
  where --base main
  has_line $'EXPLORE:\t'"$r/main"$'\tsession'
  has_line $'AT_BASE:\tno'
  where --base nope
  assert_fail_reason BAD_REF
  where --base
  assert_fail_reason BAD_ARGS
  where "$r/main"
  assert_fail_reason BAD_ARGS
}

@test "where lists untracked files whatever status.showUntrackedFiles says, one line per file" {
  r="$BATS_TEST_TMPDIR/r"
  make_bare_layout "$r"
  mkdir -p "$r/main/newdir"
  echo a >"$r/main/newdir/a.sh"; echo b >"$r/main/newdir/b.sh"
  git -C "$r/main" config status.showUntrackedFiles no
  [ -z "$(git -C "$r/main" status --porcelain)" ]
  cd "$r/main"
  where
  has_line $'UNCOMMITTED:\t?? newdir/a.sh'
  has_line $'UNCOMMITTED:\t?? newdir/b.sh'
  has_line $'UNCOMMITTED_TOTAL:\t2'
}

@test "where reports unknown, never zero, when git status cannot inspect the checkout" {
  r="$BATS_TEST_TMPDIR/r"
  make_bare_layout "$r"
  echo helper >"$r/main/helper.sh"
  # an index git cannot read
  printf 'not an index' >"$r/.bare/worktrees/main/index"
  ! git -C "$r/main" status --porcelain >/dev/null 2>&1
  cd "$r/main"
  where
  [ "$status" -eq 0 ]
  has_line $'UNCOMMITTED_TOTAL:\t-'
  refute_line $'UNCOMMITTED_TOTAL:\t0'
  refute_line $'UNCOMMITTED:\t'
}
