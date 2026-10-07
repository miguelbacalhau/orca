# shellcheck shell=bash
#
# orca salvage — a blocked (or cut) item's worktree becomes a WIP commit
# on its branch, and the worktree goes. Sourced by orca.sh; lib.sh is
# already loaded.
#
# Usage:
#   orca.sh salvage <worktree> <integration-wt> <id>
#
# The branch is the recovery surface a retry round resumes (the
# worktree-item verb's branch arrival); the directory is just clutter at
# the repo root. Order is the safety contract — stage everything, commit
# when the index is not empty, and only then remove the worktree — so an
# unfinished salvage (a failed add or commit) leaves the worktree in
# place rather than removing unsaved work.
#
#   no directory at <worktree>:          salvaged=no-worktree
#   nothing to commit, worktree removed: salvaged=clean
#   WIP committed, worktree removed:     salvaged=committed
#
# The WIP message is fixed — `wip: <id> — blocked, partial work` — and
# checked against the banned-attribution regex here, where the regex
# lives (falling back to `wip: blocked, partial work` should an id ever
# trip it). commit-verify rewrites a wip: tip if one ever surfaces at
# commit time.
#
# Guards: both paths absolute; the integration worktree is a worktree
# top level; an existing <worktree> is a worktree top level of the SAME
# repository, and never the integration worktree itself — removing that
# would take the run's deliverable with it.
#
# Failures are typed (GIT_ERROR) and the caller treats every one as
# non-fatal: it logs and moves on — a blocked item is already blocked.
#
# Frame keys: rc, salvaged=committed|clean|no-worktree

[ $# -eq 3 ] || fail BAD_ARGS "usage: orca.sh salvage <worktree> <integration-wt> <id>"
sv_wt="$1"
sv_iwt="$2"
sv_id="$3"
case "$sv_wt" in
  /*) ;;
  *) fail BAD_ARGS "worktree path is not absolute: $sv_wt" ;;
esac
is_worktree_root "$sv_iwt" \
  || fail BAD_ARGS "not the top level of a git worktree (absolute path required): $sv_iwt"
[[ $sv_id =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail BAD_ARGS "id is not a work-item id: $sv_id"

if [ ! -d "$sv_wt" ]; then
  emit_frame rc=0 salvaged=no-worktree
  exit 0
fi

is_worktree_root "$sv_wt" || fail BAD_ARGS "not the top level of a git worktree: $sv_wt"
[ "$(canonicalize "$sv_wt")" != "$(canonicalize "$sv_iwt")" ] \
  || fail BAD_ARGS "refusing to salvage the integration worktree itself: $sv_wt"
sv_common_wt="$(git -C "$sv_wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
sv_common_iwt="$(git -C "$sv_iwt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -z "$sv_common_wt" ] || [ "$(canonicalize "$sv_common_wt")" != "$(canonicalize "$sv_common_iwt")" ]; then
  fail BAD_ARGS "worktree does not belong to the integration worktree's repository: $sv_wt"
fi

sv_msg="wip: $sv_id — blocked, partial work"
is_banned "$sv_msg" && sv_msg="wip: blocked, partial work"

git -C "$sv_wt" add -A >/dev/null 2>&1 \
  || fail GIT_ERROR "git add -A failed in $sv_wt — worktree left in place"
if git -C "$sv_wt" diff --cached --quiet; then
  sv_salvaged=clean
else
  git -C "$sv_wt" commit -q -m "$sv_msg" >/dev/null 2>&1 \
    || fail GIT_ERROR "WIP commit failed in $sv_wt — worktree left in place"
  sv_salvaged=committed
fi

sv_out="$(git -C "$sv_iwt" worktree remove --force "$sv_wt" 2>&1)" \
  || fail GIT_ERROR "salvage $sv_salvaged, but the worktree could not be removed: $(printf '%s' "$sv_out" | tr '\n' ' ' | tail -c 300)"

emit_frame rc=0 "salvaged=$sv_salvaged"
