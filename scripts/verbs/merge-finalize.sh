# shellcheck shell=bash
#
# orca merge-finalize — one relay call for the whole post-merge-agent
# block: the forgot-to-commit recovery, the span attribution check, the
# audit ledger write, and the worktree/branch cleanup. Sourced by
# orca.sh; lib.sh is already loaded. Runs inside the caller's serialized
# merge section — an amend must never rewrite a commit a later merge
# builds on.
#
# Usage:
#   orca.sh merge-finalize <integration-wt> <tip-before> <id> \
#       --title-b64 <b64> --wt <worktree> --branch <branch> \
#       --ledger <path>
#
# <tip-before> is the integration head read after the merge mutex was
# taken and before the merge agent ran — the caller captures it (that
# ordering is why this verb can never read it itself).
#
# The merge stage squashes: `git merge --squash <item-branch>` stages the
# item's whole diff without recording a second parent, and the agent
# commits it with the item commit's own Conventional message. So the
# integration branch is linear — one commit per item, no merge commits,
# and no run-internal item id anywhere in the history the user lands.
#
# Converge, don't replay: every decision observes current repo state.
#
#   commit (a squash merge leaves the result STAGED — an agent that
#   resolves conflicts and then forgets `git commit` would otherwise
#   lose the item, so the deterministic layer finishes the job, but
#   only from a state that can mean nothing else):
#     tip moved:                                  commit=agent
#     tip unmoved, index clean of unmerged paths,
#       nothing unstaged, something staged:       commit=recovered
#       (committed with -C <branch> — the item commit's already-verified
#       message — falling back to the composed safe message)
#     tip unmoved, anything else (unresolved
#       conflicts, unstaged leftovers, nothing
#       staged):                                  commit=none
#       Nothing merged: the caller blocks the item, and the ledger write
#       and the cleanup are BOTH skipped so the branch and worktree
#       survive for a retry round.
#
#   attribution (only commits this merge created — first-parent, so a
#   stray merge's second parent, which came off an item branch already
#   checked by commit-verify, is not re-judged and cannot be rewritten
#   from here; the span is a single commit in the normal case):
#     commit=none:                      attribution=unchanged
#     span clean:                       attribution=clean
#     banned on the tip only:           attribution=amended
#     banned below the tip (a post-commit fix sits on top): the marker
#       cannot be amended away — attribution=squashed (reset --soft to
#       <tip-before>, one clean commit behind the safe message)
#
#   ledger (audit's ground truth: with no merge commit to carry the item
#   id, the id->sha join is recorded here by the deterministic layer,
#   from observed repo state and never from an agent's self-report, so
#   audit's reconciliation stays non-circular. One `<id><TAB><sha>` line
#   per item, the id's own line rewritten so a retried call cannot
#   duplicate it. NON-FATAL, like cleanup — a merged item must never be
#   demoted to blocked over a bookkeeping file):
#     commit=none:                      ledger=skipped
#     otherwise:                        ledger=written|failed
#
#   cleanup (idempotent, and NON-FATAL by contract: the item is already
#   merged, so a stray build artifact must never demote it to blocked —
#   a failure is reported in the frame with rc=0 intact):
#     commit=none:                      cleanup=skipped
#     otherwise: remove the item worktree if present, prune stale
#       registrations, delete the item branch if present (-D: a squashed
#       branch is not an ancestor, so -d would refuse)
#                                       -> cleanup=done|failed
#
# The safe message is composed HERE from the title and id (single-holder
# rule: it needs the banned regex, and lib.sh is the regex's one home),
# in commit-verify's shape so a rewritten item reads the same wherever
# the rewrite happened: `chore: <title>`, or `chore: complete work item
# <id>` when the title itself trips the regex.
#
# Frame keys: rc, tip, commit, attribution, ledger, cleanup

mf_iwt=""
mf_tip_before=""
mf_id=""
mf_title_b64=""
mf_wt=""
mf_branch=""
mf_ledger=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title-b64) mf_title_b64="${2:-}"; shift 2 || break ;;
    --wt)        mf_wt="${2:-}"; shift 2 || break ;;
    --branch)    mf_branch="${2:-}"; shift 2 || break ;;
    --ledger)    mf_ledger="${2:-}"; shift 2 || break ;;
    -*)          fail BAD_ARGS "unknown merge-finalize flag: $1" ;;
    *)
      if   [ -z "$mf_iwt" ];        then mf_iwt="$1"
      elif [ -z "$mf_tip_before" ]; then mf_tip_before="$1"
      elif [ -z "$mf_id" ];         then mf_id="$1"
      else fail BAD_ARGS "unexpected merge-finalize argument: $1"
      fi
      shift ;;
  esac
done
usage="usage: orca.sh merge-finalize <integration-wt> <tip-before> <id> --title-b64 <b64> --wt <worktree> --branch <branch> --ledger <path>"
if [ -z "$mf_iwt" ] || [ -z "$mf_tip_before" ] || [ -z "$mf_id" ] || [ -z "$mf_title_b64" ] || [ -z "$mf_wt" ] || [ -z "$mf_branch" ] || [ -z "$mf_ledger" ]; then
  fail BAD_ARGS "$usage"
fi
[ -d "$mf_iwt" ] || fail BAD_ARGS "integration worktree is not a directory: $mf_iwt"
[[ $mf_tip_before =~ ^[0-9a-f]{40}$ ]] || fail BAD_ARGS "tip-before is not a 40-hex commit sha: $mf_tip_before"
# The id is a ledger key matched with an anchored regex — keep it to the
# characters a work-item id has ever had (it is also a branch-name
# segment, so anything else is already broken upstream).
[[ $mf_id =~ ^[A-Za-z0-9_.-]+$ ]] || fail BAD_ARGS "id is not a work-item id: $mf_id"

mf_title="$(printf '%s' "$mf_title_b64" | tr -d '[:space:]' | b64_decode 2>/dev/null)" \
  || fail BAD_ARGS "--title-b64 does not decode as base64"

if is_banned "$mf_title"; then
  mf_safe="chore: complete work item $mf_id"
else
  mf_safe="chore: $mf_title"
fi

mf_tab="$(printf '\t')"

mf_head() {
  local sha
  sha="$(git -C "$mf_iwt" rev-parse HEAD)" || fail GIT_ERROR "could not read HEAD in $mf_iwt"
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || fail GIT_ERROR "HEAD of $mf_iwt is not a commit sha: $sha"
  printf '%s' "$sha"
}

mf_squash() { # <why> — reset the span behind the guaranteed safe message
  if ! git -C "$mf_iwt" reset --soft "$mf_tip_before" \
    || ! git -C "$mf_iwt" commit -m "$mf_safe" >/dev/null; then
    fail GIT_ERROR "$1 squash failed in $mf_iwt"
  fi
}

# Rewrite the id's line rather than appending: merge-finalize is retried
# on a lost frame, and a duplicated row would read as two merges of one
# item. grep's exit 1 (no lines left) is success here; only >1 is an
# error, and a botched filter must never truncate the other items' rows.
mf_ledger_write() { # <sha> -> 0 written, 1 failed
  local tmp rc
  tmp="$mf_ledger.$$.tmp"
  if [ -f "$mf_ledger" ]; then
    grep -v "^$mf_id$mf_tab" "$mf_ledger" >"$tmp" 2>/dev/null
    rc=$?
    [ "$rc" -le 1 ] || { rm -f "$tmp"; return 1; }
  else
    : >"$tmp" 2>/dev/null || return 1
  fi
  printf '%s%s%s\n' "$mf_id" "$mf_tab" "$1" >>"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$mf_ledger" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

mf_commit=agent
mf_attribution=unchanged
mf_ledger_state=skipped
mf_cleanup=skipped
mf_now="$(mf_head)"

if [ "$mf_now" = "$mf_tip_before" ]; then
  # The agent claimed a merge but left the tip where it was. Recover only
  # from the one state that can mean nothing but a missing `git commit`.
  if [ -n "$(git -C "$mf_iwt" ls-files --unmerged)" ] \
    || ! git -C "$mf_iwt" diff --quiet \
    || git -C "$mf_iwt" diff --cached --quiet; then
    mf_commit=none
  else
    git -C "$mf_iwt" commit -C "$mf_branch" >/dev/null 2>&1 \
      || git -C "$mf_iwt" commit -m "$mf_safe" >/dev/null \
      || fail GIT_ERROR "staged-squash recovery commit failed in $mf_iwt"
    mf_commit=recovered
  fi
fi

if [ "$mf_commit" != none ]; then
  mf_span="$(git -C "$mf_iwt" log --first-parent --format=%B "$mf_tip_before..HEAD")" \
    || fail GIT_ERROR "git log failed in $mf_iwt"
  if is_banned "$mf_span"; then
    mf_below="$(git -C "$mf_iwt" log --first-parent --skip=1 --format=%B "$mf_tip_before..HEAD")" \
      || fail GIT_ERROR "git log failed in $mf_iwt"
    if ! is_banned "$mf_below"; then
      git -C "$mf_iwt" commit --amend -m "$mf_safe" >/dev/null \
        || fail GIT_ERROR "attribution amend failed in $mf_iwt"
      mf_attribution=amended
    else
      mf_squash attribution
      mf_attribution=squashed
    fi
  else
    mf_attribution=clean
  fi

  # The sha is read AFTER any attribution rewrite — the ledger must point
  # at the commit that survives, and the integration branch only ever
  # grows from here, so this row stays an ancestor of the deliverable.
  if mf_ledger_write "$(mf_head)"; then mf_ledger_state=written; else mf_ledger_state=failed; fi

  # Cleanup — idempotent and best-effort: a retry after a completed
  # cleanup finds nothing to remove and reports done.
  mf_cleanup='done'
  if [ -d "$mf_wt" ]; then
    git -C "$mf_iwt" worktree remove --force "$mf_wt" >/dev/null 2>&1 || mf_cleanup=failed
  fi
  git -C "$mf_iwt" worktree prune >/dev/null 2>&1 || true
  if git -C "$mf_iwt" rev-parse -q --verify "refs/heads/$mf_branch" >/dev/null 2>&1; then
    git -C "$mf_iwt" branch -D "$mf_branch" >/dev/null 2>&1 || mf_cleanup=failed
  fi
fi

emit_frame rc=0 "tip=$(mf_head)" "commit=$mf_commit" "attribution=$mf_attribution" \
  "ledger=$mf_ledger_state" "cleanup=$mf_cleanup"
