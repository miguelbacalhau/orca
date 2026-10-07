# shellcheck shell=bash
#
# orca merge-prepare — the head of the serialized merge section: clear
# whatever a dead predecessor left in the integration worktree, then
# hand back the base merge-finalize judges the merge against. Sourced by
# orca.sh; lib.sh is already loaded.
#
# Usage:
#   orca.sh merge-prepare <integration-wt>
#
# Self-heal before merging: a predecessor that died mid-conflict must
# not leave the integration worktree in a merging state for every item
# after it. `merge --abort` alone cannot do it — a conflicted
# `git merge --squash` records no MERGE_HEAD, so the abort fails with
# "no merge to abort" and leaves the conflict markers in the index — so
# `reset --hard HEAD` is the fallback. That reset is safe precisely
# here: merges are serialized and each ends in a commit, so anything
# uncommitted in the integration worktree at the head of the section is
# a dead predecessor's debris; the work itself lives on its item branch.
# Untracked files are left alone (reset --hard never touched them).
#
# Converge, don't replay — the state decides:
#   MERGE_HEAD present:   merge --abort -> reset=aborted; when the abort
#                         fails, or leaves tracked changes behind,
#                         reset --hard -> reset=hard
#   no MERGE_HEAD, tracked changes (staged, unstaged, unmerged):
#                         reset --hard -> reset=hard
#   clean:                reset=none
#   the reset itself failed: reset=failed, rc=0 — the caller logs it and
#     merges anyway, as it always has (the merge agent knows the same
#     reset and can retry it)
#
# The base is the integration head read AFTER the cleanup and BEFORE the
# merge agent runs — the ordering is why merge-finalize can never read
# it itself. It is a marker: the caller passes it to merge-finalize
# verbatim.
#
# Frame keys: rc, reset=none|aborted|hard|failed, base

[ $# -eq 1 ] || fail BAD_ARGS "usage: orca.sh merge-prepare <integration-wt>"
mp_iwt="$1"
is_worktree_root "$mp_iwt" \
  || fail BAD_ARGS "not the top level of a git worktree (absolute path required): $mp_iwt"

mp_dirty() { # tracked changes of any kind, conflicts included
  [ -n "$(git -C "$mp_iwt" status --porcelain --untracked-files=no 2>/dev/null)" ]
}

mp_hard() {
  if git -C "$mp_iwt" reset -q --hard HEAD >/dev/null 2>&1; then
    mp_reset=hard
  else
    mp_reset=failed
  fi
}

mp_reset=none
if git -C "$mp_iwt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  if git -C "$mp_iwt" merge --abort >/dev/null 2>&1; then
    mp_reset=aborted
    mp_dirty && mp_hard
  else
    mp_hard
  fi
elif mp_dirty; then
  mp_hard
fi

mp_base="$(git -C "$mp_iwt" rev-parse HEAD 2>/dev/null)" \
  || fail GIT_ERROR "could not read HEAD in $mp_iwt"
is_marker "$mp_base" || fail GIT_ERROR "HEAD of $mp_iwt is not a commit id: $mp_base"

emit_frame rc=0 "reset=$mp_reset" "base=$mp_base"
