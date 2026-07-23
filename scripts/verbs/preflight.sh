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
# plus informational TRUNK_CANDIDATE, REVIEWER, and CONFIG lines and a
# final RESULT line.
#
# No AGENTS gate and no MCP-registration checks: the subagent definitions
# and the codex MCP server registration ship inside the orca plugin, so a
# session that can run this skill has them by construction. What only the
# live session can check — the codex MCP tool actually resolving — is
# SKILL.md Step 1's job.
#
# Does NOT check bypassPermissions mode — that is not observable from a shell
# and stays a conversational gate in SKILL.md.
#
# Exit 0 iff every gate passes; non-zero if any gate fails. No side effects.
#
# Sourced by orca.sh (orca.sh preflight); the lib is loaded but unused
# here — this verb keeps its own internal helpers. The fail below is a
# VARIABLE, distinct from lib.sh's fail() function (bash separates the
# two namespaces).

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
codex_min_version="0.142.5"

# Binary present at >= min version? Shared by detection and the CODEX gate.
codex_binary_ok=0
codex_binary_reason="codex not on PATH"
if command -v codex >/dev/null 2>&1; then
  codex_version="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  oldest="$(printf '%s\n%s\n' "$codex_min_version" "${codex_version:-0}" | sort -V | head -1)"
  if [[ -n "$codex_version" && "$oldest" == "$codex_min_version" ]]; then
    codex_binary_ok=1
  else
    codex_binary_reason="codex ${codex_version:-unknown} < required $codex_min_version"
  fi
fi

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

# --- CODEX: the cross-model reviewer is the GLOBAL codex binary's MCP server, ---
# --- registered by the plugin's bundled .mcp.json — checked only when the     ---
# --- resolved reviewer is codex                                               ---
# Codex is never installed via npm — the only supported codex is the system
# install on PATH (official non-npm distribution: Homebrew or the release
# binaries). The gate checks: binary on PATH at >= the minimum version this
# skill's MCP usage was verified against, valid auth, and the MCP_TOOL_TIMEOUT
# env knob. The timeout check survives the plugin migration because it is a
# CLIENT-side setting: the plugin's .mcp.json registers the server, but a
# plugin cannot set the session env that governs MCP tool-call timeouts, so
# it still lives in a settings env block (project or user) that orca:doctor
# writes. Nothing here can check what is LOADED in the current session —
# the live check (does the codex MCP tool resolve?) is SKILL.md Step 1's
# job, in the session itself.
# Project settings can live in the worktree the session runs in or beside
# the bare repo at the root; both are checked, then the user scope.
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
  timeout_set=0
  for sf in "${settings_files[@]}"; do
    [[ -f "$sf" ]] || continue
    if grep -q '"MCP_TOOL_TIMEOUT"' "$sf"; then
      timeout_set=1
    fi
  done
  if [[ "$timeout_set" -eq 0 ]]; then
    codex_fail "MCP_TOOL_TIMEOUT not set in a settings env block — orca:doctor writes it (~20 minutes); reviews would be killed at the default tool timeout"
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
