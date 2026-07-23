#!/usr/bin/env bash
#
# orca CLI — the single entry point for the plugin's deterministic
# verbs. The relay contract is one stable string in workflow JS and
# agent prompts:
#
#   bash "$PLUGIN_ROOT/scripts/orca.sh" <verb> [args...]
#
# The dispatcher is a case statement and nothing more (no
# option-parsing framework, no plugin system for the plugin): it
# sources lib.sh once via its own absolute location, then sources the
# verb file with the remaining arguments in place. Sourcing over
# exec'ing verbs is deliberate — every verb is a short-lived process
# already, so process isolation buys nothing, and lib.sh's fail()
# exiting the whole process is exactly the wanted typed-failure shape.
#
# Runtime envelope: bash 3.2 + git (>= 2.31) + coreutils.

set -uo pipefail

orca_scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh disable=SC1091
source "$orca_scripts_dir/lib.sh"

verb="${1:-}"
[ $# -gt 0 ] && shift

case "$verb" in
  self-test)
    # Smoke verb: proves dispatch, lib loading, and the frame path
    # end-to-end without touching a repository.
    emit_frame rc=0 verb=self-test "probe.b64=$(b64_encode_str 'orca self-test')"
    ;;
  *)
    fail UNKNOWN_VERB "unknown verb '${verb}' — usage: orca.sh <verb> [args...]; verbs: self-test"
    ;;
esac
