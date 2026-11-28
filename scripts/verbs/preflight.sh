# shellcheck shell=bash disable=SC2154
#
# orca pre-flight — read-only environment validation, run once during
# Step 1 before the brief is confirmed. Config and settings paths are
# resolved from git (the common dir's parent for .orca/, the worktree
# top level for .claude/), so running from a subdirectory can neither
# silently downgrade a pinned reviewer nor produce false timeout FAILs.
#
# Reads one config key — "reviewer" from ./.orca/config — to decide
# whether the codex gate applies; otherwise touches nothing. Prints one
# machine-readable line per gate:
#   <KEY>: PASS
#   <KEY>: FAIL: <terse remediation>
#   <KEY>: SKIPPED: <why it was not checked>   (CODEX only)
# plus informational TRUNK_CANDIDATE, REVIEWER, and CONFIG lines, the
# location lines below, and a final RESULT line.
#
# Location lines — where the session stands, TAB-separated (a path may
# hold spaces), printed whenever the directory is inside a repository:
#   SESSION:<TAB>root | worktree <path> | conventional
#       the bare layout's root, a worktree of it (its top level), or a
#       conventional checkout
#   ORCA_IN_SCOPE:<TAB>yes | no | n/a | -
#       whether <root>/.orca/ — the objective's own files — is inside what
#       a session started here may touch: n/a when the session stands at
#       the root itself (or in a conventional checkout, which is the
#       root); otherwise yes when a permissions.additionalDirectories
#       entry of this worktree's .claude/settings.local.json or
#       settings.json, or of the user's ~/.claude/settings.json, names
#       <root>/.orca or a directory above it (the root itself included);
#       an entry below .orca or beside it does not count. From one of
#       orca's own worktrees (<root>/orca-*) with no such entry the answer
#       is -, unknown: a session that moved there still reads the settings
#       of the directory it was started in, which a shell cannot name
#   DEFAULT_WORKTREE:<TAB><path> | -
#       where the default branch is checked out (lib.sh default_worktree)
#
# Usage:
#   orca.sh preflight                 every gate, plus the location lines
#   orca.sh preflight where [--base <branch>]
#                                     the location lines only, then where a
#                                     run's spec and research explore and
#                                     what the run builds on:
#     EXPLORE:<TAB><dir><TAB>base | session | default | root
#         with --base, the worktree that has <branch> checked out (base).
#         Otherwise, or when <branch> is checked out nowhere: the session's
#         own worktree (session), unless it is one of orca's (<root>/orca-*,
#         another unit's unfinished branch); then the default worktree
#         (default); when the default branch is checked out nowhere either,
#         the root
#     BUILD_BASE:<TAB><sha><TAB><branch>
#         the commit a run builds on, resolved from the branch alone and
#         never from the directory explored: <branch>'s tip with --base (the
#         confirmed trunk, or a follow-up's base branch), else the default
#         branch's; - for a value that does not resolve
#     AT_BASE:<TAB>yes | no | -
#         whether the directory explored has BUILD_BASE checked out (its
#         HEAD is that commit); - when it is no work tree or either is unknown
#     UNCOMMITTED:<TAB><git status --porcelain line>     one per path,
#         untracked files always listed one by one, whatever the user's
#         status.showUntrackedFiles
#     UNCOMMITTED_TOTAL:<TAB><n> | -
#         - when it is unknown: <dir> is no work tree, or git status failed
#         there — never a 0 it did not count
#   `where` exits 0, or 1 with a typed FAIL: (NOT_GIT, OLD_GIT, BAD_ARGS,
#   BAD_REF for a --base that names no branch).
#
# No AGENTS gate: the subagent definitions ship inside the orca plugin, so
# a session that can run this skill has them by construction. Nor is there
# anything left for the live session to check — the reviewer is reached by
# running the codex binary through orca.sh, not over MCP, so every codex
# gate is a shell question and all of them are answered here.
#
# Does NOT check bypassPermissions mode — that is not observable from a shell
# and stays a conversational gate in SKILL.md.
#
# Exit 0 iff every gate passes; non-zero if any gate fails. No side effects.
#
# Sourced by orca.sh (orca.sh preflight); of the lib it uses
# codex_binary_check, canonicalize, default_worktree, and — in `where` —
# resolve_repo and the fail() function; this verb otherwise keeps its own
# internal helpers. The fail below is a VARIABLE, distinct from lib.sh's
# fail() function (bash separates the two namespaces).

# ---- where the session stands -------------------------------------------
# Reads common_dir, is_bare, repo_root, worktree_root.

# The additionalDirectories entries of one settings file, one per line.
# grep-only by design, like the BASH_MAX_TIMEOUT_MS read below: the array
# is taken as written, and an entry holding an escaped quote is not read.
additional_dirs() { # <settings-file>
  [[ -f "$1" ]] || return 0
  tr '\n' ' ' <"$1" \
    | grep -o '"additionalDirectories"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
    | sed 's/^[^[]*\[//; s/\]$//' \
    | grep -o '"[^"]*"' | sed 's/^"//; s/"$//'
  return 0
}

# yes when an entry of <settings-file> is the repository's .orca
# directory or a directory above it — the root included. A relative entry
# is read against <base-dir>, the directory the settings file belongs to;
# an empty <base-dir> skips it.
orca_in_settings() { # <settings-file> <base-dir>
  local entry dir orca_canon orca_real
  # Both spellings of the directory: under the canonical root, and where
  # a linked .orca really is.
  orca_canon="$(canonicalize "$repo_root")/.orca"
  orca_real="$(canonicalize "$repo_root/.orca")"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    # An entry spelled with a literal tilde is matched as text and
    # expanded by hand, so the quoted "~/" is intended.
    # shellcheck disable=SC2088
    case "$entry" in
      /*) dir="$entry" ;;
      "~") dir="$HOME" ;;
      "~/"*) dir="$HOME/${entry#"~/"}" ;;
      *) [[ -n "$2" ]] || continue; dir="$2/$entry" ;;
    esac
    dir="$(canonicalize "$dir")"
    if [[ "$dir" == "/" || "$orca_canon" == "$dir" || "$orca_canon" == "$dir"/* \
      || "$orca_real" == "$dir" || "$orca_real" == "$dir"/* ]]; then
      return 0
    fi
  done < <(additional_dirs "$1")
  return 1
}

# Whether the shell stands in one of orca's own worktrees: a worktree
# directly under the repository root whose name starts orca-.
in_orca_worktree() {
  [[ -n "$worktree_root" ]] || return 1
  case "$(basename "$worktree_root")" in
    orca-*) ;;
    *) return 1 ;;
  esac
  [[ "$(canonicalize "$(dirname "$worktree_root")")" == "$(canonicalize "$repo_root")" ]]
}

location_lines() {
  local scope
  if [[ "$is_bare" != "true" ]]; then
    printf 'SESSION:\tconventional\n'
  elif [[ -n "$worktree_root" ]]; then
    printf 'SESSION:\tworktree %s\n' "$worktree_root"
  else
    printf 'SESSION:\troot\n'
  fi
  if [[ -z "$worktree_root" || "$(canonicalize "$worktree_root")" == "$(canonicalize "$repo_root")" ]]; then
    scope="n/a"
  elif orca_in_settings "$worktree_root/.claude/settings.local.json" "$worktree_root" \
    || orca_in_settings "$worktree_root/.claude/settings.json" "$worktree_root" \
    || orca_in_settings "$HOME/.claude/settings.json" ""; then
    scope="yes"
  elif in_orca_worktree; then
    scope="-"
  else
    scope="no"
  fi
  printf 'ORCA_IN_SCOPE:\t%s\n' "$scope"
  default_wt="$(default_worktree)"
  printf 'DEFAULT_WORKTREE:\t%s\n' "${default_wt:--}"
}

# ---- where: the location lines and the directory to explore ---------------
if [[ "${1:-}" == "where" ]]; then
  where_usage="usage: preflight where [--base <branch>]"
  base_arg=""
  case $# in
    1) ;;
    3) [[ "$2" == "--base" && -n "$3" ]] || fail BAD_ARGS "$where_usage"; base_arg="$3" ;;
    *) fail BAD_ARGS "$where_usage" ;;
  esac
  resolve_repo
  worktree_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  location_lines

  # The build base comes from the branch — the one the caller names, else
  # the default branch — and never from whichever directory gets explored.
  base_branch="$base_arg"
  [[ -n "$base_branch" ]] || base_branch="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  base_sha=""
  [[ -n "$base_branch" ]] && base_sha="$(git --git-dir="$common_dir" rev-parse --verify -q "refs/heads/$base_branch^{commit}" 2>/dev/null || true)"
  [[ -z "$base_arg" || -n "$base_sha" ]] || fail BAD_REF "no branch named $base_arg"

  # Where to explore: the named branch's own worktree when it has one.
  explore="" explore_why=""
  if [[ -n "$base_arg" ]]; then
    cur=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) cur="${line#worktree }" ;;
        "branch refs/heads/$base_arg") explore="$cur" explore_why=base ;;
      esac
    done < <(git --git-dir="$common_dir" worktree list --porcelain 2>/dev/null)
  fi
  if [[ -z "$explore" ]]; then
    if [[ -n "$worktree_root" ]] && ! in_orca_worktree; then
      explore="$worktree_root" explore_why=session
    elif [[ -n "$default_wt" ]]; then
      explore="$default_wt" explore_why=default
    else
      explore="$repo_root" explore_why=root
    fi
  fi
  printf 'EXPLORE:\t%s\t%s\n' "$explore" "$explore_why"
  printf 'BUILD_BASE:\t%s\t%s\n' "${base_sha:--}" "${base_branch:--}"

  if [[ "$(git -C "$explore" rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]]; then
    printf 'AT_BASE:\t-\n'
    printf 'UNCOMMITTED_TOTAL:\t-\n'
    exit 0
  fi
  explore_head="$(git -C "$explore" rev-parse --verify -q HEAD 2>/dev/null || true)"
  if [[ -z "$explore_head" || -z "$base_sha" ]]; then
    printf 'AT_BASE:\t-\n'
  elif [[ "$explore_head" == "$base_sha" ]]; then
    printf 'AT_BASE:\tyes\n'
  else
    printf 'AT_BASE:\tno\n'
  fi
  # Untracked files asked for explicitly (a user's status.showUntrackedFiles=no
  # would hide exactly the files this evidence exists for), and the exit
  # status read: a scan that failed is unknown, never an empty list.
  if status_out="$(git -C "$explore" status --porcelain --untracked-files=all 2>/dev/null)"; then
    uncommitted=0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf 'UNCOMMITTED:\t%s\n' "$line"
      uncommitted=$((uncommitted + 1))
    done <<<"$status_out"
    printf 'UNCOMMITTED_TOTAL:\t%d\n' "$uncommitted"
  else
    printf 'UNCOMMITTED_TOTAL:\t-\n'
  fi
  exit 0
fi

fail=0

# --- BARE_REPO: the run requires a bare repo with worktrees, no main checkout ---
common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -z "$common_dir" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
  # Old git, not no-git: --path-format needs git >= 2.31.
  echo "BARE_REPO: FAIL: git $(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -1) lacks --path-format (orca needs git >= 2.31) — upgrade git"
  fail=1
elif [[ -z "$common_dir" ]]; then
  echo "BARE_REPO: FAIL: not inside a git repository"
  fail=1
else
  is_bare="$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null || true)"
  if [[ "$is_bare" == "true" ]]; then
    echo "BARE_REPO: PASS"
  else
    echo "BARE_REPO: FAIL: conventional checkout, not bare-with-worktrees (run orca:init to convert)"
    fail=1
  fi

  # Informational: the bare repo's HEAD names the default branch — a trunk candidate.
  trunk="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  echo "TRUNK_CANDIDATE: ${trunk:-unknown}"
fi

# --- PLUGIN_ROOT: the plugin-shipped CLI must exist at the dispatcher's own location ---
# The work loop's worktree/commit/merge rituals run through scripts/orca.sh;
# a missing dispatcher means "can't commit anything", discovered at minute
# forty — refuse at minute zero instead (typed NO_PLUGIN_ROOT). Run through
# the dispatcher the check is tautological — orca.sh is what is running —
# but both branches stay: they cost nothing and stay honest if the layout
# ever changes. test -f, not -x: every invocation is `bash .../orca.sh`, so
# the exec bit is never needed and must not be relied on to survive plugin
# installation. The workflow's own non-empty-argument assert covers the
# other failure mode (the launcher never passed pluginRoot); the two are
# complementary, not redundant.
if [[ -f "$orca_scripts_dir/orca.sh" ]]; then
  echo "PLUGIN_ROOT: PASS"
else
  echo "PLUGIN_ROOT: FAIL: NO_PLUGIN_ROOT — scripts/orca.sh is not beside preflight.sh; reinstall the orca plugin"
  fail=1
fi

# Path resolution from git, never CWD: the repo root (common-dir parent)
# holds .orca/, and the worktree top level (when inside one) holds the
# project .claude/ settings. Both empty outside a repo — the relative
# fallbacks below then behave as before.
repo_root=""
worktree_root=""
if [[ -n "$common_dir" ]]; then
  repo_root="$(dirname "$common_dir")"
  worktree_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  # Informational: where the session stands (see the header).
  location_lines
fi

# Informational signpost, never a FAIL: the legacy JSON config is not
# read by anything since the flat-file migration — without this line, a
# previously pinned reviewer silently reverting to detection would
# surface at minute forty instead of minute zero.
if [[ -f "${repo_root:-.}/.orca/config.json" ]]; then
  echo "CONFIG: OBSOLETE: .orca/config.json is no longer read — see orca:config"
fi

# --- REVIEWER: which independent reviewer runs — pinned in config, else detected ---
# A written "reviewer" key in ./.orca/config pins the choice; absent, the
# machine decides: codex binary on PATH at >= the minimum version -> codex,
# else claude. Detection is binary-presence-at-version ONLY — auth or timeout
# problems on a detected/pinned codex are CODEX gate failures below, never a
# silent downgrade to claude (that would swap the reviewer out from under a
# codex user).
#
# Binary present at >= min version? Shared by detection and the CODEX gate
# — and, through lib.sh, with council resolve, so both hold one minimum.
codex_binary_check

# Extraction is grep-only by design: orca:config (via lib.sh) is the sole
# writer and only ever writes canonical one-key-per-line reviewer=<value>.
# Zero matches -> absent (detect); exactly one distinct valid value -> pinned;
# anything else (duplicates, an unrecognized value) -> loud FAIL, never a guess.
reviewer=""
reviewer_provenance=""
reviewer_invalid=0
config_file="${repo_root:-.}/.orca/config"
if [[ -f "$config_file" ]]; then
  reviewer_values="$(grep '^reviewer=' "$config_file" 2>/dev/null \
    | sed 's/^reviewer=//' | sort -u || true)"
  value_count="$(printf '%s' "$reviewer_values" | grep -c . || true)"
  if [[ "$value_count" -eq 1 && ( "$reviewer_values" == "codex" || "$reviewer_values" == "claude" ) ]]; then
    reviewer="$reviewer_values"
    reviewer_provenance="pinned"
  elif [[ "$value_count" -gt 0 ]]; then
    # Multiple distinct values or an unrecognized one — a hand-mangled file.
    # Fail loudly, never guess; the CODEX gate is skipped as unresolvable.
    echo "REVIEWER: FAIL: invalid reviewer in .orca/config — fix with orca:config"
    fail=1
    reviewer_invalid=1
  fi
fi
if [[ -z "$reviewer" && "$reviewer_invalid" -eq 0 ]]; then
  if [[ "$codex_binary_ok" -eq 1 ]]; then reviewer="codex"; else reviewer="claude"; fi
  reviewer_provenance="detected"
fi
if [[ -n "$reviewer" ]]; then
  echo "REVIEWER: $reviewer ($reviewer_provenance)"
fi

# --- CODEX: the cross-model reviewer is the GLOBAL codex binary, run       ---
# --- non-interactively by orca.sh codex — checked only when the resolved   ---
# --- reviewer is codex                                                     ---
# Codex is never installed via npm — the only supported codex is the system
# install on PATH (official non-npm distribution: Homebrew or the release
# binaries). Four checks: binary on PATH at >= the minimum version, valid
# auth, the `codex exec` flags the transport depends on, and the
# BASH_MAX_TIMEOUT_MS env knob.
#
# The FLAGS check is the lesson of the 0.155.1 break. orca reached Codex
# over MCP until then, via `codex mcp-server`; the CLI removed that
# subcommand without a deprecation, and because an unknown subcommand is
# taken as a TUI prompt the server died with "stdin is not a terminal" —
# a version-and-auth gate that passed, and every review failing deep inside
# a run. A version floor cannot see that: what matters is not the number
# but whether this codex still speaks the interface orca drives. So the
# gate asks the binary directly.
#
# The TIMEOUT knob is CLIENT-side and cannot ship in a plugin: reviews run
# through the Bash tool, whose default cap is well under a cold review, and
# only a settings env block can raise it. orca:doctor writes it.
# Project settings can live in the worktree the session runs in or beside
# the bare repo at the root; both are checked, then the user scope. A
# settings env block also reaches the shell, so when no file carries the
# key the environment's own value is taken as the key's: a session that
# moved into another worktree still runs under the settings of the
# directory it was started in, which are not among these files.
settings_files=(
  "${worktree_root:-.}/.claude/settings.local.json" "${worktree_root:-.}/.claude/settings.json"
  "${repo_root:-.}/.claude/settings.local.json" "${repo_root:-.}/.claude/settings.json"
  "$HOME/.claude/settings.json"
)
codex_fail() {
  echo "CODEX: FAIL: $1"
  fail=1
}
if [[ "$reviewer" == "claude" ]]; then
  echo "CODEX: SKIPPED: reviewer is claude"
elif [[ -z "$reviewer" ]]; then
  echo "CODEX: SKIPPED: reviewer unresolved — fix the reviewer key first"
elif [[ "$codex_binary_ok" -ne 1 ]]; then
  codex_fail "$codex_binary_reason — install or upgrade the Codex CLI from its official non-npm distribution (e.g. 'brew install codex'), never via npm; orca:doctor walks this through"
elif ! codex login status >/dev/null 2>&1 </dev/null; then
  codex_fail "not authenticated — run 'codex login' (orca:doctor walks this through)"
else
  codex_exec_help="$(codex exec --help 2>&1 </dev/null || true)"
  missing_flags=""
  for flag in --output-schema --output-last-message --sandbox --cd; do
    case "$codex_exec_help" in
      *"$flag"*) ;;
      *) missing_flags="${missing_flags:+$missing_flags, }$flag" ;;
    esac
  done
  # The VALUE, not just the key: a settings file carrying
  # "BASH_MAX_TIMEOUT_MS": "1000" would pass a presence check and then
  # kill every review after a second, with CODEX: PASS on the record. The
  # first file in precedence order that carries the key decides. A key
  # whose value this cannot parse as a number is treated as set rather
  # than as a failure — misreading an exotic-but-valid settings file into
  # a hard FAIL would be worse than the check it replaces.
  codex_min_timeout=1200000
  timeout_set=0
  timeout_value=""
  for sf in "${settings_files[@]}"; do
    [[ -f "$sf" ]] || continue
    grep -q '"BASH_MAX_TIMEOUT_MS"' "$sf" || continue
    timeout_set=1
    timeout_value="$(grep -o '"BASH_MAX_TIMEOUT_MS"[[:space:]]*:[[:space:]]*"\{0,1\}[0-9]\{1,\}' "$sf" \
      | grep -oE '[0-9]+$' | head -1)"
    break
  done
  if [[ "$timeout_set" -eq 0 && -n "${BASH_MAX_TIMEOUT_MS:-}" ]]; then
    timeout_set=1
    timeout_value="$(printf '%s' "$BASH_MAX_TIMEOUT_MS" | grep -oE '^[0-9]+$' || true)"
  fi
  if [[ -n "$missing_flags" ]]; then
    codex_fail "codex ${codex_version:-unknown} has no 'codex exec' $missing_flags — this codex cannot be driven by orca.sh codex; upgrade the Codex CLI, or pin reviewer=claude via orca:config (orca:doctor walks this through)"
  elif [[ "$timeout_set" -eq 0 ]]; then
    codex_fail "BASH_MAX_TIMEOUT_MS not set in a settings env block — orca:doctor writes it (~20 minutes); reviews would be killed at the default Bash tool timeout"
  elif [[ -n "$timeout_value" ]] && [[ "$timeout_value" -lt "$codex_min_timeout" ]]; then
    codex_fail "BASH_MAX_TIMEOUT_MS is $timeout_value, below the $codex_min_timeout (~20 minutes) a review needs — raise it (orca:doctor writes it); reviews would be killed mid-flight"
  else
    echo "CODEX: PASS"
  fi
fi

if [[ "$fail" -eq 0 ]]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
fi
exit "$fail"
