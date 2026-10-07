# shellcheck shell=bash
#
# orca commit-prepare — before a commit agent runs over a worktree the
# caller did not arrive in itself (the integration-fixes pass): is there
# anything to commit, and what base does commit-verify judge against?
# Sourced by orca.sh; lib.sh is already loaded. Read-only.
#
# Usage:
#   orca.sh commit-prepare <worktree>
#
# pending=yes when `git status --porcelain` shows anything — staged,
# unstaged, or untracked — since the commit agent stages with -A.
#
# The base is the head read BEFORE the commit agent runs (the same
# ordering logic as merge-prepare's): commit-verify can never read it
# itself, the agent has already run by then. It is a marker: the caller
# passes it to commit-verify verbatim.
#
# Frame keys: rc, pending=yes|no, base

[ $# -eq 1 ] || fail BAD_ARGS "usage: orca.sh commit-prepare <worktree>"
cp_wt="$1"
is_worktree_root "$cp_wt" \
  || fail BAD_ARGS "not the top level of a git worktree (absolute path required): $cp_wt"

cp_status="$(git -C "$cp_wt" status --porcelain)" \
  || fail GIT_ERROR "git status failed in $cp_wt"
cp_base="$(git -C "$cp_wt" rev-parse HEAD 2>/dev/null)" \
  || fail GIT_ERROR "could not read HEAD in $cp_wt"
is_marker "$cp_base" || fail GIT_ERROR "HEAD of $cp_wt is not a commit id: $cp_base"

if [ -n "$cp_status" ]; then cp_pending=yes; else cp_pending=no; fi
emit_frame rc=0 "pending=$cp_pending" "base=$cp_base"
