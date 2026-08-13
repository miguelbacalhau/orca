# shellcheck shell=bash
#
# orca init-link — the mechanical core of orca:init's root-link step:
# symlinking the default worktree's agent-context files (.claude,
# CLAUDE.md) at the repository root, so a session started there
# auto-injects the repo's conventions into every stage agent. The skill
# stays the conversational shell (the why, the consent gate, the
# root-session recommendation); this script owns detection and the
# links. It only ever creates links where the root has nothing: a real
# entry or a link pointing elsewhere is reported, never touched.
#
# Usage:
#   orca.sh init-link check
#   orca.sh init-link apply
#
# Output contract — one machine-readable line per fact, TAB-separated:
#
#   check (read-only; run from anywhere inside the repository):
#     BRANCH:<TAB><name>                      the bare HEAD's default branch
#     WORKTREE:<TAB><path>                    the worktree holding that branch
#     LINK:<TAB><name><TAB><STATE><TAB><detail>   one per name (.claude, CLAUDE.md)
#       STATE: NO_SOURCE   the worktree has no such file — nothing to offer
#              LINKED      the root link already resolves to the worktree copy
#              LINKABLE    source exists and the root slot is empty
#              CONFLICT    the root slot is occupied (real entry, or a link
#                          pointing elsewhere) — never overwritten
#     Exit 0; states are facts for the skill to relay, not gates.
#
#   apply (mutating): creates a relative symlink per LINKABLE name and
#   reports everything else untouched:
#     LINKED:<TAB><name><TAB><target>
#     SKIPPED:<TAB><name><TAB><reason>
#
#   any subcommand:
#     FAIL:<TAB><reason><TAB><detail>    exit 1
#       reasons: NOT_GIT OLD_GIT NOT_BARE NO_WORKTREE LINK_ERROR BAD_ARGS
#
# Sourced by orca.sh (orca.sh init-link ...); helpers are prefixed
# init_link_ so nothing collides with lib.sh.

init_link_sub="${1:-}"
case "$init_link_sub" in
  check|apply) ;;
  *) fail BAD_ARGS "usage: orca.sh init-link <check|apply>" ;;
esac

resolve_repo   # sets common_dir, repo_root, is_bare; NOT_GIT/OLD_GIT typed
# shellcheck disable=SC2154  # is_bare/repo_root/common_dir are resolve_repo's
[ "$is_bare" = "true" ] || fail NOT_BARE "conventional checkout at $repo_root — init-link applies to the bare-with-worktrees layout (orca:init converts)"

# shellcheck disable=SC2154  # common_dir is resolve_repo's
init_link_branch="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
[ -n "$init_link_branch" ] || fail NO_WORKTREE "the bare repository's HEAD names no default branch"

# The default worktree is wherever the default branch is checked out —
# resolved from the worktree list, not assumed to be <root>/<branch>.
init_link_wt=""
init_link_cur=""
while IFS= read -r init_link_line; do
  case "$init_link_line" in
    "worktree "*) init_link_cur="${init_link_line#worktree }" ;;
    "branch refs/heads/$init_link_branch") init_link_wt="$init_link_cur" ;;
  esac
done <<EOF
$(git --git-dir="$common_dir" worktree list --porcelain 2>/dev/null)
EOF
[ -n "$init_link_wt" ] || fail NO_WORKTREE "no worktree has the default branch '$init_link_branch' checked out — create it first (orca:init)"

# Link targets are root-relative when the worktree sits under the root
# (the layout's normal shape), so the links survive the root moving.
case "$init_link_wt" in
  "$repo_root"/*) init_link_rel="${init_link_wt#"$repo_root"/}" ;;
  *) init_link_rel="$init_link_wt" ;;
esac

init_link_state() { # <name> — STATE<TAB>detail on stdout
  local name="$1" src root_entry
  src="$init_link_wt/$name"
  root_entry="$repo_root/$name"
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    printf 'NO_SOURCE\t%s has no %s\n' "$init_link_rel" "$name"
    return
  fi
  if [ -L "$root_entry" ]; then
    if [ "$(canonicalize "$root_entry")" = "$(canonicalize "$src")" ]; then
      printf 'LINKED\t-> %s\n' "$(readlink "$root_entry")"
    else
      printf 'CONFLICT\texisting link -> %s — the user'\''s to change, not orca'\''s\n' "$(readlink "$root_entry")"
    fi
    return
  fi
  if [ -e "$root_entry" ]; then
    printf 'CONFLICT\ta real %s exists at the root — never overwritten\n' "$name"
    return
  fi
  printf 'LINKABLE\t%s/%s\n' "$init_link_rel" "$name"
}

if [ "$init_link_sub" = "check" ]; then
  printf 'BRANCH:\t%s\n' "$init_link_branch"
  printf 'WORKTREE:\t%s\n' "$init_link_wt"
  for init_link_name in .claude CLAUDE.md; do
    printf 'LINK:\t%s\t%s\n' "$init_link_name" "$(init_link_state "$init_link_name")"
  done
  exit 0
fi

for init_link_name in .claude CLAUDE.md; do
  init_link_st="$(init_link_state "$init_link_name")"
  init_link_kind="${init_link_st%%	*}"
  init_link_detail="${init_link_st#*	}"
  case "$init_link_kind" in
    LINKABLE)
      if ln -s "$init_link_rel/$init_link_name" "$repo_root/$init_link_name" 2>/dev/null; then
        printf 'LINKED:\t%s\t%s\n' "$init_link_name" "$init_link_rel/$init_link_name"
      else
        fail LINK_ERROR "could not create $repo_root/$init_link_name -> $init_link_rel/$init_link_name"
      fi
      ;;
    LINKED) printf 'SKIPPED:\t%s\talready linked %s\n' "$init_link_name" "$init_link_detail" ;;
    *) printf 'SKIPPED:\t%s\t%s\n' "$init_link_name" "$init_link_detail" ;;
  esac
done
