#!/usr/bin/env bash
#
# orchestrify stage 4c — run the independent, cross-model Codex reviewer over the
# uncommitted changes in ONE work item's worktree, deterministically.
#
# This wraps the fragile parts of the invocation that the SKILL otherwise guards
# with prose: the worktree cwd, the mandatory `< /dev/null`, the GNU timeout
# bound, retry-once-on-failure, and — the part the orchestrator cannot eyeball —
# the guarantee that a non-empty review artifact actually exists before the fix
# agent reads it. An empty or truncated artifact is treated as a failure, never
# as a clean pass.
#
# Usage:
#   codex-review.sh <worktree> <output-file> <prompt-file>
#
#   <worktree>     item worktree to review from (codex exec review has no --cd,
#                  and review mode never edits source, so we just cd into it)
#   <output-file>  where Codex writes its findings (passed to `codex -o`)
#   <prompt-file>  file holding the assembled adversarial review prompt; the
#                  orchestrator owns its content, this script owns the mechanics
#
# Env:
#   CODEX_REVIEW_TIMEOUT   seconds for the per-attempt timeout bound (default 900)
#
# Output: diagnostics on stderr; one machine-readable line on stdout, last:
#   CODEX_REVIEW: COMPLETED <output-file>     review artifact written, non-empty
#   CODEX_REVIEW: FAILED <reason>             did not complete after one retry
#
# Exit 0 iff the review completed and the artifact is non-empty; non-zero otherwise.

set -uo pipefail

worktree="${1:-}"
output="${2:-}"
prompt_file="${3:-}"
timeout_secs="${CODEX_REVIEW_TIMEOUT:-900}"

die() { echo "CODEX_REVIEW: FAILED $*" ; exit 1; }

[[ -n "$worktree" && -n "$output" && -n "$prompt_file" ]] \
  || die "usage: codex-review.sh <worktree> <output-file> <prompt-file>"
[[ -d "$worktree" ]]      || die "worktree not a directory: $worktree"
[[ -s "$prompt_file" ]]   || die "prompt file missing or empty: $prompt_file"

tmo="$(command -v timeout || command -v gtimeout || true)"  # GNU coreutils; preflight guarantees one exists
[[ -n "$tmo" ]] || die "no timeout/gtimeout on PATH (brew install coreutils on macOS)"

prompt="$(cat "$prompt_file")"
mkdir -p "$(dirname "$output")"

# One review attempt. Codex review is read-only, so re-running on retry is safe.
# `< /dev/null` is mandatory: spawned through a non-interactive shell, `codex exec`
# inherits an open-but-unwritten stdin pipe and (CLI 0.120.0+) blocks on read()
# forever waiting for an EOF that never comes; /dev/null delivers the EOF at once.
# The prompt is passed as an argument, so nothing is lost.
attempt() {
  : > "$output"  # truncate so a stale/partial artifact from a prior attempt never reads as success
  # NOTE: `codex exec review` (CLI 0.140.0) rejects `--uncommitted` when a custom
  # [PROMPT] is also passed ("--uncommitted cannot be used with [PROMPT]"), so the
  # adversarial prompt forces default review mode. That mode is agentic: Codex runs
  # `git status`/`git diff` itself from the worktree cwd and reviews the working-tree
  # changes — tracked edits AND untracked new files — with no staging by us (the
  # commit stage owns staging, by name, later). The trade vs `--uncommitted` is that
  # untracked-file coverage is best-effort rather than guaranteed; the prompt names
  # the item's owned paths to steer Codex onto them.
  ( cd "$worktree" && "$tmo" "$timeout_secs" \
      codex exec review -o "$output" "$prompt" < /dev/null )
}

# Success requires both a clean exit AND a non-empty artifact: the stdin-hang
# failure mode exits 124 via timeout, but a clean exit over an empty -o file
# would otherwise be silently read downstream as "no findings."
review_ok() {
  attempt
  local rc=$?
  if [[ "$rc" -eq 0 && -s "$output" ]]; then return 0; fi
  if [[ "$rc" -eq 124 ]]; then last_reason="timeout after ${timeout_secs}s"
  elif [[ "$rc" -ne 0 ]]; then last_reason="codex exited $rc"
  else last_reason="codex exited 0 but the findings file is empty"
  fi
  return 1
}

last_reason=""
if review_ok; then
  echo "CODEX_REVIEW: COMPLETED $output"
  exit 0
fi
echo "first review attempt failed: $last_reason — retrying once" >&2
if review_ok; then
  echo "CODEX_REVIEW: COMPLETED $output"
  exit 0
fi
die "Codex review did not complete after one retry ($last_reason)"
