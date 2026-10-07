# shellcheck shell=bash
#
# orca archive — move a superseded attempt's artifacts out of the way
# before the next attempt writes over them. Sourced by orca.sh; lib.sh
# is already loaded.
#
# Usage:
#   orca.sh archive attempt <run-dir> <id|integration>
#
# Two parts, always both, each reported on its own:
#
#   plan — <run-dir>/plans/<id>.md moves to the first free
#   plans/<id>.round<N>.md, N unbounded. A superseded plan left in place
#   reads as finished work to a fresh planner (the W3 stall: a replan
#   agent endorsed its predecessor's plan as "already complete"); with a
#   fixed 0-3 slot list a fifth archive silently no-opped and left it
#   there. The integration pass has no plan file, so its part is none.
#
#   reviews — everything named <id>-* under <run-dir>/reviews/ moves into
#   the first prev<N>/ holding nothing of <id>, N unbounded (the same
#   shape as /orca:retry's archive, so a retry's snapshot and an in-run
#   replan's never collide). review() writes fixed round<N> names, so
#   without this a relaunch's round0 overwrote the old one while the old
#   round1/round2 survived beside it — and a stale round2 carrying
#   Critical/High next to a fresh clean round0 reads as an item that
#   exhausted its fix rounds when it never did. For `integration` the
#   same move replaces the old delete: a reviewer switch on retry can
#   leave the other reviewer's integration artifact beside the fresh
#   one, and the fixer must see exactly one — archived, not destroyed.
#
# Each part answers archived (moved), none (nothing to move), or failed
# (a mv/mkdir error) — with rc=0 either way. Fail-soft is the caller's
# contract per part (a failed plan move must not stop the review move),
# so a part's failure rides the frame instead of exiting. Bad arguments
# are typed BAD_ARGS.
#
# Frame keys: rc, plan=archived|none|failed, reviews=archived|none|failed

ar_usage="usage: orca.sh archive attempt <run-dir> <id|integration>"
[ $# -eq 3 ] && [ "$1" = attempt ] || fail BAD_ARGS "$ar_usage"
ar_rd="$2"
ar_id="$3"
is_run_dir "$ar_rd" || fail BAD_ARGS "not a run directory (an absolute directory inside .orca/): $ar_rd"
# The id lands in a glob and in file names: no glob characters, no
# slashes, no leading dot.
[[ $ar_id =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail BAD_ARGS "id is not a work-item id: $ar_id"

ar_exists() { [ -e "$1" ] || [ -L "$1" ]; }

ar_holds() { # <dir> — the dir holds something named <id>-*
  local f
  for f in "$1/$ar_id-"*; do
    ar_exists "$f" && return 0
  done
  return 1
}

ar_plan=none
ar_plans="$ar_rd/plans"
if ar_exists "$ar_plans/$ar_id.md"; then
  ar_n=0
  while ar_exists "$ar_plans/$ar_id.round$ar_n.md"; do ar_n=$((ar_n + 1)); done
  if mv "$ar_plans/$ar_id.md" "$ar_plans/$ar_id.round$ar_n.md" 2>/dev/null; then
    ar_plan=archived
  else
    ar_plan=failed
  fi
fi

ar_reviews=none
ar_dir="$ar_rd/reviews"
if ar_holds "$ar_dir"; then
  ar_n=0
  while ar_holds "$ar_dir/prev$ar_n"; do ar_n=$((ar_n + 1)); done
  ar_reviews=archived
  if mkdir -p "$ar_dir/prev$ar_n" 2>/dev/null; then
    for ar_f in "$ar_dir/$ar_id-"*; do
      ar_exists "$ar_f" || continue
      mv "$ar_f" "$ar_dir/prev$ar_n/" 2>/dev/null || ar_reviews=failed
    done
  else
    ar_reviews=failed
  fi
fi

emit_frame rc=0 "plan=$ar_plan" "reviews=$ar_reviews"
