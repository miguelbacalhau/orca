# shellcheck shell=bash
#
# orca spec — the work loop's one question about the contract: did
# spec.md move? Sourced by orca.sh; lib.sh is already loaded.
#
# Usage:
#   orca.sh spec mark <run-dir>
#   orca.sh spec changed <run-dir> <mark>
#
# The loop asks it around every reconciliation read and every escalation
# (the escalating agent edits spec.md directly and its schema does not
# say whether it did), because nothing else can answer: the workflow has
# no filesystem. `mark` takes the reading; `changed` compares the file
# now against an earlier reading and hands back the current one, so a
# chain of brackets never needs a second call per step.
#
# A mark is spec.md's git blob id (`hash-object --no-filters`: content
# only, no attributes, nothing written to any object store). It is a
# marker — opaque to the workflow, which passes it back verbatim — so a
# malformed one is a typed BAD_ARGS here, never a silent "changed".
#
# Fail-soft by answer, not by exit: when spec.md cannot be read NOW,
# `changed` answers changed=unknown (no mark) with rc=0, and the caller
# reads unknown exactly like yes — "assume it moved", the conservative
# path. `mark` has no prior reading to compare, so an unreadable spec is
# its typed failure (SPEC_UNREADABLE), which the caller reads the same
# way.
#
# Frame keys: rc, mark (mark; changed=yes|no), changed (changed only).

spec_usage="usage: orca.sh spec mark <run-dir> | orca.sh spec changed <run-dir> <mark>"
spec_cmd="${1:-}"
case "$spec_cmd" in
  mark)    [ $# -eq 2 ] || fail BAD_ARGS "$spec_usage" ;;
  changed) [ $# -eq 3 ] || fail BAD_ARGS "$spec_usage" ;;
  *)       fail BAD_ARGS "$spec_usage" ;;
esac
spec_rd="$2"
is_run_dir "$spec_rd" || fail BAD_ARGS "not a run directory (an absolute directory inside .orca/): $spec_rd"

spec_read() { # -> the current mark on stdout; return 1 when unreadable
  local h
  [ -f "$spec_rd/spec.md" ] && [ -r "$spec_rd/spec.md" ] || return 1
  h="$(git -C "$spec_rd" hash-object --no-filters -- spec.md 2>/dev/null)" || return 1
  is_marker "$h" || return 1
  printf '%s' "$h"
}

if [ "$spec_cmd" = mark ]; then
  spec_now="$(spec_read)" || fail SPEC_UNREADABLE "could not read $spec_rd/spec.md"
  emit_frame rc=0 "mark=$spec_now"
  exit 0
fi

spec_prior="$3"
is_marker "$spec_prior" || fail BAD_ARGS "not a spec mark: $spec_prior"
if ! spec_now="$(spec_read)"; then
  emit_frame rc=0 changed=unknown
  exit 0
fi
if [ "$spec_now" = "$spec_prior" ]; then
  emit_frame rc=0 changed=no "mark=$spec_now"
else
  emit_frame rc=0 changed=yes "mark=$spec_now"
fi
