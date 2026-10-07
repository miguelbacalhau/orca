# shellcheck shell=bash
#
# orca notes — persist a note the workflow holds and nothing else
# records. Sourced by orca.sh; lib.sh is already loaded.
#
# Usage:
#   orca.sh notes write <run-dir> <name> <content-b64>
#
# Names are a closed vocabulary, each mapping to one fixed file in the
# run directory:
#
#   integration-fixes -> <run-dir>/integration-fixes.json — the
#     integration fixer's declines and escalations (that pass has no
#     plan file to carry Deviations, so an unpersisted return would be
#     the only record)
#
# The content arrives base64-encoded (arbitrary bytes never
# ride a command line raw) and is written byte-exact — the caller owns
# its trailing newline. Atomic: a temp file beside the target, then a
# rename, so a reader never observes a half-written note.
#
# Typed failures: BAD_ARGS (usage, run dir, name, undecodable content),
# WRITE_ERROR. The caller treats both as non-fatal (the notes also ride
# the workflow result).
#
# Frame keys: rc, written=<path>

nt_usage="usage: orca.sh notes write <run-dir> integration-fixes <content-b64>"
[ $# -eq 4 ] && [ "$1" = write ] || fail BAD_ARGS "$nt_usage"
nt_rd="$2"
nt_name="$3"
nt_b64="$4"
is_run_dir "$nt_rd" || fail BAD_ARGS "not a run directory (an absolute directory inside .orca/): $nt_rd"
case "$nt_name" in
  integration-fixes) nt_file="$nt_rd/integration-fixes.json" ;;
  *) fail BAD_ARGS "unknown note '$nt_name' — notes: integration-fixes" ;;
esac
# base64 --decode exits 0 on some garbage (macOS), so the alphabet is
# checked first.
[[ $nt_b64 =~ ^[A-Za-z0-9+/=[:space:]]+$ ]] || fail BAD_ARGS "content is not base64"

nt_tmp="$(mktemp "$nt_rd/.notes.XXXXXX" 2>/dev/null)" \
  || fail WRITE_ERROR "could not create a temp file in $nt_rd"
if ! printf '%s' "$nt_b64" | tr -d '[:space:]' | b64_decode >"$nt_tmp" 2>/dev/null; then
  rm -f "$nt_tmp"
  fail BAD_ARGS "content does not decode as base64"
fi
mv -f "$nt_tmp" "$nt_file" 2>/dev/null || {
  rm -f "$nt_tmp"
  fail WRITE_ERROR "could not write $nt_file"
}

emit_frame rc=0 "written=$nt_file"
