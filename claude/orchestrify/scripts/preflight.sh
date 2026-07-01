#!/usr/bin/env bash
#
# orchestrify pre-flight — read-only environment validation, run once during the
# interview before the closing confirmation. Run from the project root.
#
# Checks the three mechanical gates and prints one machine-readable line each:
#   <KEY>: PASS
#   <KEY>: FAIL: <terse remediation>
# plus an informational TRUNK_CANDIDATE line and a final RESULT line.
#
# Does NOT check bypassPermissions mode — that is not observable from a shell
# and stays a conversational gate in SKILL.md.
#
# Exit 0 iff every gate passes; non-zero if any gate fails. No side effects.

set -uo pipefail

fail=0

# --- BARE_REPO: the run requires a bare repo with worktrees, no main checkout ---
common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -z "$common_dir" ]]; then
  echo "BARE_REPO: FAIL: not inside a git repository"
  fail=1
else
  is_bare="$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null || true)"
  if [[ "$is_bare" == "true" ]]; then
    echo "BARE_REPO: PASS"
  else
    echo "BARE_REPO: FAIL: conventional checkout, not bare-with-worktrees (see SKILL.md conversion recipe)"
    fail=1
  fi

  # Informational: the bare repo's HEAD names the default branch — a trunk candidate.
  trunk="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  echo "TRUNK_CANDIDATE: ${trunk:-unknown}"
fi

# --- CODEX: cross-model reviewer used by stage 4c must be installed + authed ---
if ! command -v codex >/dev/null 2>&1; then
  echo "CODEX: FAIL: codex CLI not found — npm i -g @openai/codex"
  fail=1
elif ! codex login status >/dev/null 2>&1 </dev/null; then
  echo "CODEX: FAIL: not authenticated — run 'codex login'"
  fail=1
else
  echo "CODEX: PASS"
fi

# --- TIMEOUT: stage 4c bounds each Codex review with GNU timeout/gtimeout ---
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  echo "TIMEOUT: PASS"
else
  echo "TIMEOUT: FAIL: no timeout/gtimeout for the Codex review bound — 'brew install coreutils' on macOS"
  fail=1
fi

# --- AGENTS: the seven subagent definitions must be installed for the harness ---
missing=""
for name in spec plan implement fix commit merge integrate; do
  if [[ ! -e "$HOME/.claude/agents/orchestrify-$name.md" && ! -e "./.claude/agents/orchestrify-$name.md" ]]; then
    missing="$missing $name"
  fi
done
if [[ -n "$missing" ]]; then
  echo "AGENTS: FAIL: missing definitions:$missing — re-run install-claude-skills.sh"
  fail=1
else
  echo "AGENTS: PASS"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
fi
exit "$fail"
