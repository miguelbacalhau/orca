# shellcheck shell=bash
#
# orca loop — the commit half of an objective's phase loop: the tree the
# commit should hold, and whether the implementer's commit stands. The
# skill sequences the phase conversationally and the round engine
# (`orca.sh rounds`) decides each round; this verb answers the two
# questions the commit step cannot answer by judgment.
#
# Usage:
#   orca.sh loop snapshot <worktree> <dir>
#   orca.sh loop check <worktree> <base-sha> <tree>
#
# <worktree> is any path inside the work tree (normalized to its top
# level); <dir> is the phase's rounds directory — scratch that must never
# be committed.
#
# snapshot — the tree `git add -A` would commit right now, built in a
#   throwaway index (blobs go to the object store, as the commit would),
#   recorded in <dir>/snapshot (round=<N>, tree=<sha>; temp file +
#   rename) against N, the latest review round in <dir>/reviews/ (0 when
#   none). While <dir>/snapshot names that same round and a tree the
#   repository holds, the recorded tree is returned instead (kept=yes),
#   so every commit-only retry, and a session that resumes the commit,
#   judges against the tree that was checked and reviewed; a new one is
#   taken only once a new review round exists. <dir> must be an existing
#   directory (BAD_ARGS); a snapshot path that is a symlink or not a
#   regular file is WRITE_ERROR. An objective's phase directory sits
#   outside every worktree of the bare layout, so the tree never carries it.
#   Frame keys: rc, tree, kept (yes|no), round.
#
# check — after the implementer's commit step; read-only except the
# reset. Converges from observed state, like commit-verify:
#
#   HEAD == base                        action=needs_commit     none
#   base not an ancestor of HEAD        action=diverged         none — history
#                                       was rewritten under the phase; the
#                                       skill asks the user
#   HEAD moved, span banned             action=violation_reset  reset --soft
#                                       <base>; the changes stay staged
#   HEAD moved, tree dirty              action=incomplete       none — the
#                                       commit missed files
#   HEAD^{tree} != <tree>               action=content_reset    reset --soft
#                                       <base> — the commit holds changes
#                                       made after the snapshot (a commit
#                                       hook rewriting code, an edit in
#                                       the commit turn); they stay staged
#                                       for the next checks and review
#   HEAD moved, span clean, tree clean, action=accepted         none
#   committed tree == <tree>
#
#   The span is every commit message in <base>..HEAD, judged by
#   is_banned. Several commits are accepted (the prompt asks for one).
#   Banned is judged before dirty: the reset keeps the working tree, so
#   the recommit picks up the missed files too. Content is judged last,
#   on a commit that is otherwise acceptable.
#   Frame keys: rc, action, head and message.b64 (accepted only — the new
#   HEAD and its message).
#
#   any subcommand:
#     FAIL:<TAB><reason><TAB><detail>    exit 1
#       reasons: BAD_ARGS BAD_PATH NOT_GIT UNBORN GIT_ERROR WRITE_ERROR
#
# Sourced by orca.sh with the verb arguments in place; lib.sh is already
# loaded.

loop_usage="usage: orca.sh loop snapshot <worktree> <dir> | orca.sh loop check <worktree> <base-sha> <tree>"
loop_cmd="${1:-}"
case "$loop_cmd" in
  snapshot) [ $# -eq 3 ] || fail BAD_ARGS "$loop_usage" ;;
  check)    [ $# -eq 4 ] || fail BAD_ARGS "$loop_usage" ;;
  *)        fail BAD_ARGS "$loop_usage" ;;
esac

loop_nl='
'
loop_check_path() { # <path> — a frame value must not carry a newline
  case "$1" in
    *"$loop_nl"*) fail BAD_PATH "a path carries a newline, which the frame cannot carry: $1" ;;
  esac
}
# The raw argument first: command substitution strips trailing newlines,
# so `repo<LF>` must be refused before any $(…) can turn it into `repo`.
loop_check_path "$2"

loop_git_path() { # <git-args...> — sets loop_path to git's one-line answer, trailing newlines kept
  loop_path="$(git "$@" 2>/dev/null && printf x)" || { loop_path=""; return 1; }
  loop_path="${loop_path%x}"
  loop_path="${loop_path%"$loop_nl"}"
  loop_check_path "$loop_path"
}

[ -d "$2" ] || fail BAD_ARGS "not a directory: $2"
loop_git_path -C "$2" rev-parse --show-toplevel \
  || fail NOT_GIT "$2 is not inside a git working tree"
loop_wt="$loop_path"
[ -n "$loop_wt" ] || fail NOT_GIT "$2 is not inside a git working tree"

loop_read_head() { # sets loop_head — HEAD's commit id (no subshell, so fail exits the verb)
  loop_head="$(git -C "$loop_wt" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" \
    || fail UNBORN "$loop_wt has no commit yet — the loop needs a base to commit on"
  is_marker "$loop_head" || fail GIT_ERROR "HEAD of $loop_wt is not a commit id: $loop_head"
}

loop_read_status() { # sets loop_porcelain — every change, untracked files forced on
  loop_porcelain="$(git -C "$loop_wt" status --porcelain --untracked-files=all)" \
    || fail GIT_ERROR "git status failed in $loop_wt"
}

# loop_review_round <dir> — the highest N with reviews/round-1..N.json
# all present, 0 when none: the review round a snapshot belongs to.
loop_review_round() {
  local n=0
  while [ -f "$1/reviews/round-$((n + 1)).json" ]; do n=$((n + 1)); done
  printf '%s' "$n"
}

if [ "$loop_cmd" = snapshot ]; then
  loop_dir="$3"
  [ -d "$loop_dir" ] && [ ! -L "$loop_dir" ] || fail BAD_ARGS "not a directory: $loop_dir"
  loop_file="$loop_dir/snapshot"
  if [ -L "$loop_file" ] || { [ -e "$loop_file" ] && [ ! -f "$loop_file" ]; }; then
    fail WRITE_ERROR "$loop_file is a symlink or not a regular file — nothing written"
  fi
  loop_round="$(loop_review_round "$loop_dir")"
  # The tree recorded at this review round still stands: commit-only
  # retries and a resumed session judge against the same tree.
  if [ -f "$loop_file" ]; then
    loop_kept="$(sed -n 's/^tree=//p' "$loop_file" | head -1)"
    if [ "$(sed -n 's/^round=//p' "$loop_file" | head -1)" = "$loop_round" ] && is_marker "$loop_kept" \
      && git -C "$loop_wt" cat-file -e "$loop_kept^{tree}" 2>/dev/null; then
      emit_frame rc=0 "tree=$loop_kept" kept=yes "round=$loop_round"
      exit 0
    fi
  fi
  worktree_tree "$loop_wt" || fail GIT_ERROR "could not build the tree of $loop_wt"
  # shellcheck disable=SC2154  # set by lib.sh's worktree_tree
  loop_tree="$worktree_tree_id"
  loop_tmp="$(mktemp "$loop_dir/.snapshot.XXXXXX" 2>/dev/null)" \
    || fail WRITE_ERROR "could not create a temp file in $loop_dir"
  if ! printf 'round=%s\ntree=%s\n' "$loop_round" "$loop_tree" >"$loop_tmp" 2>/dev/null \
    || ! mv -f "$loop_tmp" "$loop_file" 2>/dev/null; then
    rm -f "$loop_tmp" 2>/dev/null
    fail WRITE_ERROR "could not write $loop_file"
  fi
  emit_frame rc=0 "tree=$loop_tree" kept=no "round=$loop_round"
  exit 0
fi

if [ "$loop_cmd" = check ]; then
  loop_base="$3"
  loop_tree="$4"
  is_marker "$loop_base" || fail BAD_ARGS "base-sha is not a commit id: $loop_base"
  is_marker "$loop_tree" || fail BAD_ARGS "tree is not an object id: $loop_tree"
  loop_read_head
  loop_now="$loop_head"
  if [ "$loop_now" = "$loop_base" ]; then
    emit_frame rc=0 action=needs_commit
    exit 0
  fi
  if ! git -C "$loop_wt" merge-base --is-ancestor "$loop_base" "$loop_now" 2>/dev/null; then
    emit_frame rc=0 action=diverged
    exit 0
  fi
  loop_span="$(git -C "$loop_wt" log --format=%B "$loop_base..$loop_now")" \
    || fail GIT_ERROR "git log failed in $loop_wt"
  if is_banned "$loop_span"; then
    git -C "$loop_wt" reset -q --soft "$loop_base" \
      || fail GIT_ERROR "violation reset failed in $loop_wt"
    emit_frame rc=0 action=violation_reset
    exit 0
  fi
  loop_read_status
  if [ -n "$loop_porcelain" ]; then
    emit_frame rc=0 action=incomplete
    exit 0
  fi
  loop_committed="$(git -C "$loop_wt" rev-parse "$loop_now^{tree}")" \
    || fail GIT_ERROR "could not read the tree of HEAD in $loop_wt"
  if [ "$loop_committed" != "$loop_tree" ]; then
    git -C "$loop_wt" reset -q --soft "$loop_base" \
      || fail GIT_ERROR "content reset failed in $loop_wt"
    emit_frame rc=0 action=content_reset
    exit 0
  fi
  loop_tip="$(git -C "$loop_wt" log -1 --format=%B "$loop_now")" \
    || fail GIT_ERROR "git log failed in $loop_wt"
  emit_frame rc=0 action=accepted "head=$loop_now" "message.b64=$(b64_encode_str "$loop_tip")"
  exit 0
fi
