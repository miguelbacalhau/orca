# shellcheck shell=bash
#
# orca loop — the deterministic half of /orca:loop: where the loop's
# scratch lives, what it starts from, and whether the implementer's
# commit stands. The skill sequences the loop conversationally; this
# verb answers the two questions it cannot answer by judgment.
#
# Usage:
#   orca.sh loop start <worktree>
#   orca.sh loop snapshot <worktree> <dir>
#   orca.sh loop check <worktree> <base-sha> <tree>
#   orca.sh loop finish <dir>
#
# start — read-only except the loop directory it makes.
#   Frame keys:
#     rc
#     worktree  the argument's work-tree top level (a subdirectory is
#               accepted and normalized)
#     branch    the checked-out branch (a commit needs one: DETACHED)
#     dirty     yes|no — `git status --porcelain --untracked-files=all`
#               non-empty (forced: a status.showUntrackedFiles=no config
#               must not hide what `git add -A` would commit). The skill
#               never starts on yes; it asks the user to clean up and
#               runs start again
#     base      HEAD — meaningful only when dirty=no
#     dir       <repo-root>/.orca/loops/<key>, <key> the branch through
#               lib.sh's notes_key. Created fresh with reviews/ inside
#               and an `owner` file naming the branch: a directory left
#               by a dead session on the same branch is emptied, never
#               reused; one owned by a different branch with the same
#               key (feature/x vs feature-x) is KEY_COLLISION, untouched.
#               The skill removes it through `finish` when the loop ends
#     run_dir   the run whose report.md carries **Deliverable:**
#               `<branch>` — the same match /orca:review makes; the
#               newest (last in timestamp-named order) when several
#               do — or `-`
#   <repo-root> is the common dir's parent, as everywhere. In a
#   conventional checkout that is the checkout itself, so .orca/ is
#   added to the clone's info/exclude first (secrets.sh's and the config
#   verb's ensure_exclude, behaviorally identical): the loop directory
#   must never show up as a change, be staged by the implementer's
#   `git add -A`, or land in a reviewer's subject. A loop directory git
#   tracks anything under, or would still not ignore as a whole, is
#   LOOP_DIR_UNIGNORED, nothing left behind.
#   Every path is checked before anything is deleted: .orca/,
#   .orca/loops/, or the loop directory being a symlink (or not a
#   directory) is UNSAFE_LOOP_DIR — refused outright, never resolved,
#   so no link target can talk its way past the check — and a path
#   carrying a newline, which would break the frame, is BAD_PATH. A
#   previous directory that cannot be fully removed is WRITE_ERROR:
#   stale findings or declines must never survive into a new loop.
#
# snapshot — read-only (it writes blobs to the object store, as the
#   commit would, and nothing else): the tree `git add -A` would commit
#   right now, built in a throwaway index. The skill takes it after the
#   last checks and review, before the first commit request, and keeps
#   it across commit-only retries, so check can tell whether the commit
#   holds exactly what was checked and reviewed. A tree that would carry
#   anything under <dir> (an ignore rule changed during the loop) is
#   LOOP_DIR_UNIGNORED: the loop's scratch is never committed.
#   Frame keys: rc, tree.
#
# check — after the implementer's commit step; read-only except the
# reset. Converges from observed state, like commit-verify:
#
#   HEAD == base                        action=needs_commit     none
#   base not an ancestor of HEAD        action=diverged         none — history
#                                       was rewritten under the loop; the
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
# finish — the loop's cleanup: removes <dir>, the `dir` start printed,
#   after re-proving it is one: an absolute path to a plain directory
#   under a plain .orca/loops/ under a plain .orca/ (none of the three a
#   symlink, so none swapped in since start), holding start's owner
#   file. Anything else is UNSAFE_LOOP_DIR, nothing deleted; a checkout
#   tracking files under it is LOOP_DIR_UNIGNORED, nothing deleted.
#   A git query that fails where an answer guards a deletion is
#   GIT_ERROR, never read as "nothing tracked".
#   Frame keys: rc, removed=yes|no (no — already gone; idempotent).
#
#   any subcommand:
#     FAIL:<TAB><reason><TAB><detail>    exit 1
#       reasons: BAD_ARGS BAD_PATH NOT_GIT OLD_GIT DETACHED UNBORN
#                GIT_ERROR WRITE_ERROR UNSAFE_LOOP_DIR KEY_COLLISION
#                LOOP_DIR_UNIGNORED
#
# Sourced by orca.sh with the verb arguments in place; lib.sh is already
# loaded.

loop_usage="usage: orca.sh loop start <worktree> | orca.sh loop snapshot <worktree> <dir> | orca.sh loop check <worktree> <base-sha> <tree> | orca.sh loop finish <dir>"
loop_cmd="${1:-}"
case "$loop_cmd" in
  start|finish) [ $# -eq 2 ] || fail BAD_ARGS "$loop_usage" ;;
  snapshot)     [ $# -eq 3 ] || fail BAD_ARGS "$loop_usage" ;;
  check)        [ $# -eq 4 ] || fail BAD_ARGS "$loop_usage" ;;
  *)            fail BAD_ARGS "$loop_usage" ;;
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

loop_plain_dir() { # <path> — an existing directory that is not a symlink
  [ ! -L "$1" ] && [ -d "$1" ]
}

# The checkout the scratch sits in, if any: the target itself in a
# conventional checkout, the primary checkout for a linked worktree of
# one, none in the bare layout. Its tracked files are never deleted.
loop_guard_tracked() { # <dir> — sets loop_host; fails when the host tracks files under <dir>
  local tracked
  loop_host=""
  if loop_git_path -C "$(dirname "$1")" rev-parse --show-toplevel; then loop_host="$loop_path"; fi
  [ -n "$loop_host" ] || return 0
  tracked="$(git -C "$loop_host" ls-files -- "$1" 2>/dev/null)" \
    || fail GIT_ERROR "could not ask $loop_host what it tracks under $1 — nothing deleted"
  [ -z "$tracked" ] \
    || fail LOOP_DIR_UNIGNORED "git tracks files under $1 — the loop will not delete committed files; ignore .orca/ in $loop_host"
}

if [ "$loop_cmd" = finish ]; then
  loop_dir="$2"
  case "$loop_dir" in /*) ;; *) fail BAD_ARGS "not an absolute path: $loop_dir" ;; esac
  if [ ! -e "$loop_dir" ] && [ ! -L "$loop_dir" ]; then
    emit_frame rc=0 removed=no
    exit 0
  fi
  loop_parent="$(dirname "$loop_dir")"
  loop_plain_dir "$loop_dir" \
    || fail UNSAFE_LOOP_DIR "$loop_dir is not a plain directory — remove it by hand"
  if [ "$(basename "$loop_parent")" != loops ] || [ "$(basename "$(dirname "$loop_parent")")" != .orca ] \
    || ! loop_plain_dir "$loop_parent" || ! loop_plain_dir "$(dirname "$loop_parent")"; then
    fail UNSAFE_LOOP_DIR "$loop_dir is not under a plain .orca/loops/ — the loop never deletes through a link"
  fi
  [ -f "$loop_dir/owner" ] || fail UNSAFE_LOOP_DIR "$loop_dir has no owner file — not a loop directory start made"
  loop_guard_tracked "$loop_dir"
  rm -rf "$loop_dir" || fail WRITE_ERROR "could not remove $loop_dir"
  emit_frame rc=0 removed=yes
  exit 0
fi

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

if [ "$loop_cmd" = snapshot ]; then
  loop_index="$(git -C "$loop_wt" rev-parse --path-format=absolute --git-path index 2>/dev/null)" \
    || fail GIT_ERROR "could not locate the index of $loop_wt"
  loop_tmp="$(mktemp -d "${TMPDIR:-/tmp}/orca-loop.XXXXXX")" \
    || fail WRITE_ERROR "could not create a scratch index"
  [ ! -f "$loop_index" ] || cp "$loop_index" "$loop_tmp/index" 2>/dev/null \
    || { rm -rf "$loop_tmp"; fail WRITE_ERROR "could not copy the index of $loop_wt"; }
  if ! GIT_INDEX_FILE="$loop_tmp/index" git -C "$loop_wt" add -A >/dev/null 2>&1 \
    || ! loop_tree="$(GIT_INDEX_FILE="$loop_tmp/index" git -C "$loop_wt" write-tree 2>/dev/null)"; then
    rm -rf "$loop_tmp"
    fail GIT_ERROR "could not build the tree of $loop_wt"
  fi
  case "$3/" in
    "$loop_wt"/*)
      if ! loop_scratch="$(GIT_INDEX_FILE="$loop_tmp/index" git -C "$loop_wt" ls-files -- "$3" 2>/dev/null)"; then
        rm -rf "$loop_tmp"
        fail GIT_ERROR "could not list the snapshot of $loop_wt"
      fi
      if [ -n "$loop_scratch" ]; then
        rm -rf "$loop_tmp"
        fail LOOP_DIR_UNIGNORED "the commit would carry the loop's scratch under $3 — an ignore rule changed during the loop; ignore .orca/ again"
      fi
      ;;
  esac
  rm -rf "$loop_tmp"
  is_marker "$loop_tree" || fail GIT_ERROR "write-tree in $loop_wt returned no tree id: $loop_tree"
  emit_frame rc=0 "tree=$loop_tree"
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

# ---- start ------------------------------------------------------------

loop_git_path -C "$loop_wt" rev-parse --path-format=absolute --git-common-dir || true
common_dir="$loop_path"
if [ -z "$common_dir" ]; then
  fail OLD_GIT "git $(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -1) lacks --path-format (orca needs git >= 2.31) — upgrade git"
fi
repo_root="$(dirname "$common_dir")"

loop_branch="$(git -C "$loop_wt" symbolic-ref -q --short HEAD 2>/dev/null)" \
  || fail DETACHED "$loop_wt has a detached HEAD — check out the branch the commit belongs on"
loop_read_head
loop_base="$loop_head"

# Conventional checkout only (the bare layout's .orca/ sits outside every
# worktree). Must stay behaviorally identical to secrets.sh's.
if [ "$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null)" != true ]; then
  mkdir -p "$common_dir/info" 2>/dev/null || true
  grep -qxF '.orca/' "$common_dir/info/exclude" 2>/dev/null \
    || printf '.orca/\n' >>"$common_dir/info/exclude" 2>/dev/null || true
fi

loop_key="$(notes_key "$loop_branch")"
case "$loop_key" in
  ''|.|..) fail BAD_ARGS "branch $loop_branch has no usable key" ;;
esac
loop_check_path "$repo_root"
loop_parent="$repo_root/.orca/loops"
loop_dir="$loop_parent/$loop_key"

# Nothing is deleted until the path is proven to be what it says: a
# symlinked .orca/ or .orca/loops/ would aim the rm -rf below anywhere.
# Links are refused, never resolved — resolution is where a crafted
# target (one ending in a newline) slips past a comparison.
for loop_component in "$repo_root/.orca" "$loop_parent"; do
  if [ -L "$loop_component" ] || { [ -e "$loop_component" ] && [ ! -d "$loop_component" ]; }; then
    fail UNSAFE_LOOP_DIR "$loop_component is a symlink or not a directory — the loop never deletes through a link"
  fi
  mkdir "$loop_component" 2>/dev/null || loop_plain_dir "$loop_component" \
    || fail WRITE_ERROR "could not create $loop_component"
done
if [ -L "$loop_dir" ] || { [ -e "$loop_dir" ] && [ ! -d "$loop_dir" ]; }; then
  fail UNSAFE_LOOP_DIR "$loop_dir is a symlink or not a directory — remove it by hand"
fi

# A key shared by two branches (feature/x, feature-x) must not let one
# loop wipe the other's live state.
if [ -f "$loop_dir/owner" ]; then
  loop_owner="$(cat "$loop_dir/owner" 2>/dev/null)"
  [ "$loop_owner" = "$loop_branch" ] \
    || fail KEY_COLLISION "$loop_dir belongs to a loop on $loop_owner, which shares this branch's key — finish that loop first, or remove $loop_dir if its session is gone"
fi

# Its host checkout's tracked files are never deleted, and git must
# ignore the scratch there.
loop_guard_tracked "$loop_dir"

if ! rm -rf "$loop_dir" 2>/dev/null || [ -e "$loop_dir" ]; then
  fail WRITE_ERROR "could not clear $loop_dir — a previous loop's findings and declines would survive; remove it by hand"
fi
mkdir -p "$loop_dir/reviews" 2>/dev/null || fail WRITE_ERROR "could not create $loop_dir"
printf '%s\n' "$loop_branch" >"$loop_dir/owner" 2>/dev/null \
  || fail WRITE_ERROR "could not write $loop_dir/owner"

# The directory itself must be ignored: git cannot re-include a file
# below an excluded directory, so that covers everything the loop writes.
if [ -n "$loop_host" ] && ! git -C "$loop_host" check-ignore -q "$loop_dir" 2>/dev/null; then
  rm -rf "$loop_dir"
  fail LOOP_DIR_UNIGNORED "$loop_dir is inside the checkout $loop_host and git does not ignore it — it would be committed; ignore .orca/ there"
fi

loop_read_status
if [ -n "$loop_porcelain" ]; then loop_dirty=yes; else loop_dirty=no; fi

loop_run_dir=-
for loop_report in "$repo_root/.orca"/*/report.md; do
  [ -f "$loop_report" ] || continue
  case "$loop_report" in *"$loop_nl"*) continue ;; esac
  if grep -qF "**Deliverable:** \`$loop_branch\`" "$loop_report" 2>/dev/null; then
    loop_run_dir="$(dirname "$loop_report")"
  fi
done

emit_frame rc=0 "worktree=$loop_wt" "branch=$loop_branch" "dirty=$loop_dirty" \
  "base=$loop_base" "dir=$loop_dir" "run_dir=$loop_run_dir"
