# shellcheck shell=bash
#
# orca commit-verify — one verb call for everything between (and
# after) commit-agent attempts: read the head, judge the span against
# the banned-attribution regex, and converge the worktree to a clean,
# attributable commit. Sourced by orca.sh; lib.sh is already loaded.
#
# Usage:
#   orca.sh commit-verify <worktree> <base-sha> <id> \
#       --branch <integration-branch> --title-b64 <b64> [--final]
#
# <base-sha> is the worktree head BEFORE the commit agent ran — the
# caller holds it from worktree-item's frame (per-item path) or from
# commit-prepare's base marker (integration-fixes path); this verb can
# never read it itself, the agent has already run.
#
# Decision table (converge, don't replay — every branch observes
# current repo state, never assumes a previous invocation didn't run):
#
#   head unmoved from <base-sha>:
#     tree clean AND commits exist past <integration-branch>
#       (a rebuilt/resumed item whose work is already committed):
#       span clean, tip not wip:  action=accepted     (tip kept)
#       span clean, tip is wip:   action=wip_rewritten (amend fallback —
#         a salvaged wip: tip marks a blocked round's partial work,
#         never a finished item; amend, not reset: only the tip needs
#         the new message, a wip deeper in the span is honest history)
#       span banned (prior-run commits predate this run's checks):
#         action=prior_squashed  (reset --soft to the merge-base with
#         <integration-branch>, one fresh fallback commit — the item IS
#         built; blocking it on "no commit" would be a false premise)
#     otherwise: action=needs_commit — the caller re-runs the commit
#       agent (also the retry arrival after a half-run violation_reset:
#       HEAD back at base, changes still staged)
#
#   head moved:
#     span clean:               action=accepted
#     span banned, not --final: action=violation_reset (reset --soft to
#       <base-sha>; the caller re-runs the commit agent with a warning)
#     span banned, --final:     action=fallback_rewritten (reset --soft
#       + one fallback commit; reset + fresh commit, not --amend — the
#       banned marker may sit below the tip)
#
# The fallback message is composed HERE — `chore: <title>`, or
# `chore: complete work item <id>` when the title itself trips the
# banned regex — because that choice needs the regex, and the regex has
# exactly one holder: lib.sh.
#
# Frame keys: rc, action, hash, message.b64 (hash/message only on
# actions that leave a commit standing). <base-sha> and the emitted hash
# are markers (lib.sh is_marker): the base is checked on arrival, the
# hash before it is emitted, so the caller never validates a sha itself.

cv_wt=""
cv_base=""
cv_id=""
cv_branch=""
cv_title_b64=""
cv_final=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)    cv_branch="${2:-}"; shift 2 || break ;;
    --title-b64) cv_title_b64="${2:-}"; shift 2 || break ;;
    --final)     cv_final=1; shift ;;
    -*)          fail BAD_ARGS "unknown commit-verify flag: $1" ;;
    *)
      if   [ -z "$cv_wt" ];   then cv_wt="$1"
      elif [ -z "$cv_base" ]; then cv_base="$1"
      elif [ -z "$cv_id" ];   then cv_id="$1"
      else fail BAD_ARGS "unexpected commit-verify argument: $1"
      fi
      shift ;;
  esac
done
usage="usage: orca.sh commit-verify <worktree> <base-sha> <id> --branch <integration-branch> --title-b64 <b64> [--final]"
if [ -z "$cv_wt" ] || [ -z "$cv_base" ] || [ -z "$cv_id" ] || [ -z "$cv_branch" ] || [ -z "$cv_title_b64" ]; then
  fail BAD_ARGS "$usage"
fi
[ -d "$cv_wt" ] || fail BAD_ARGS "worktree is not a directory: $cv_wt"
is_marker "$cv_base" || fail BAD_ARGS "base-sha is not a commit base marker: $cv_base"

cv_title="$(printf '%s' "$cv_title_b64" | tr -d '[:space:]' | b64_decode 2>/dev/null)" \
  || fail BAD_ARGS "--title-b64 does not decode as base64"

if is_banned "$cv_title"; then
  cv_fallback="chore: complete work item $cv_id"
else
  cv_fallback="chore: $cv_title"
fi

cv_head() {
  local sha
  sha="$(git -C "$cv_wt" rev-parse HEAD)" || fail GIT_ERROR "could not read HEAD in $cv_wt"
  is_marker "$sha" || fail GIT_ERROR "HEAD of $cv_wt is not a commit id: $sha"
  printf '%s' "$sha"
}

cv_emit() { # <action> <hash> <message>
  emit_frame rc=0 "action=$1" "hash=$2" "message.b64=$(b64_encode_str "$3")"
  exit 0
}

cv_now="$(cv_head)"

if [ "$cv_now" = "$cv_base" ]; then
  cv_status="$(git -C "$cv_wt" status --porcelain)" \
    || fail GIT_ERROR "git status failed in $cv_wt"
  cv_ahead="$(git -C "$cv_wt" rev-list --count "$cv_branch..HEAD")" \
    || fail GIT_ERROR "rev-list against $cv_branch failed in $cv_wt"
  if [ -z "$cv_status" ] && [ "$cv_ahead" -gt 0 ]; then
    cv_span="$(git -C "$cv_wt" log --format=%B "$cv_branch..HEAD")" \
      || fail GIT_ERROR "git log failed in $cv_wt"
    cv_tip="$(git -C "$cv_wt" log -1 --format=%B)" \
      || fail GIT_ERROR "git log failed in $cv_wt"
    if ! is_banned "$cv_span"; then
      if [[ $cv_tip =~ ^[Ww][Ii][Pp]: ]]; then
        git -C "$cv_wt" commit --amend -m "$cv_fallback" >/dev/null \
          || fail GIT_ERROR "wip-rewrite amend failed in $cv_wt"
        cv_emit wip_rewritten "$(cv_head)" "$cv_fallback"
      fi
      cv_emit accepted "$cv_base" "$cv_tip"
    fi
    cv_mb="$(git -C "$cv_wt" merge-base "$cv_branch" HEAD)" \
      || fail GIT_ERROR "merge-base against $cv_branch failed in $cv_wt"
    if ! git -C "$cv_wt" reset --soft "$cv_mb" \
      || ! git -C "$cv_wt" commit -m "$cv_fallback" >/dev/null; then
      fail GIT_ERROR "prior-span squash failed in $cv_wt"
    fi
    cv_emit prior_squashed "$(cv_head)" "$cv_fallback"
  fi
  emit_frame rc=0 action=needs_commit
  exit 0
fi

cv_span="$(git -C "$cv_wt" log --format=%B "$cv_base..HEAD")" \
  || fail GIT_ERROR "git log failed in $cv_wt"
cv_tip="$(git -C "$cv_wt" log -1 --format=%B)" \
  || fail GIT_ERROR "git log failed in $cv_wt"
if ! is_banned "$cv_span"; then
  cv_emit accepted "$cv_now" "$cv_tip"
fi
if [ "$cv_final" -eq 0 ]; then
  # <base-sha>, not HEAD~1: the agent may have made zero or several commits.
  git -C "$cv_wt" reset --soft "$cv_base" \
    || fail GIT_ERROR "violation reset failed in $cv_wt"
  emit_frame rc=0 action=violation_reset
  exit 0
fi
if ! git -C "$cv_wt" reset --soft "$cv_base" \
  || ! git -C "$cv_wt" commit -m "$cv_fallback" >/dev/null; then
  fail GIT_ERROR "fallback rewrite failed in $cv_wt"
fi
cv_emit fallback_rewritten "$(cv_head)" "$cv_fallback"
