# shellcheck shell=bash disable=SC2154
#
# orca provision — the composite worktree-arrival ritual: place the
# secrets, then run `.orca/setup`. A distinct word from `setup` because it
# is not the setup verb but the SEQUENCE, and the nine call sites need one
# thing to say. The order is load-bearing: an install often needs the
# .npmrc or .env that placement provides, so secrets go in first.
#
# Usage:
#   orca.sh provision <worktree> <arrival>
#
# <arrival> is created | branch_resumed | reused | integrate — the value
# reaches the script as ORCA_ARRIVAL, so a script can be cheap on a warm
# tree. Every arrival provisions: items merging into the integration
# branch change dependencies, which is why the work loop provisions the
# integration worktree again with `integrate` before verification.
#
# Reviews are the one worktree kind that never provisions: they read a
# diff, need no build, and already run stripped of secrets — the same
# least-privilege argument says no install either.
#
# Output: secrets placement's typed lines, then setup's, then one frame:
#   rc             always 0 — provisioning is ADVISORY, never fatal. A
#                  failed install must not kill an item before its agent
#                  runs; the agent may be what fixes the build.
#   arrival        echoed back
#   setup          absent | ok | failed | timeout
#   setup_stamped  yes | no | '-' (no script) — `no` means the script has
#                  no valid provenance header: hand-written, or edited
#                  past `setup install`, so its drift check is stale
#   setup_rc       the script's exit status; '-' when it never ran
#   setup_seconds  its wall clock; '-' when it never ran
#   setup_tail.b64 last 4 KB of the captured log — on failure and timeout
#                  only, and the ONLY channel that reaches anyone in time:
#                  a workflow's log() lines are invisible mid-run
#                  (anthropics/claude-code#74419), so the loops turn this
#                  into a `Provisioning:` line in the agent's prompt.
#
# A secrets FAIL (misuse only, by that verb's contract) is the typed
# failure and exits 1, exactly as in worktree-item.sh.
#
# Two emission modes, one implementation. Dispatched as a verb, this file
# parses its arguments and closes with the frame; sourced with
# ORCA_PROVISION_LIB=1 (worktree-item does this, folding the result into
# its own frame — two frames in one output would be one frame to the
# relay decoder), it only defines provision_ritual.
#
# Sourced by orca.sh with the verb arguments in place; lib.sh is loaded.

# provision_ritual <worktree> <arrival> — the sequence. Prints both verbs'
# typed lines; sets provision_setup, provision_rc, provision_seconds and
# provision_tail (base64, empty when there is nothing to carry). Returns 1
# only when secrets placement failed its own misuse gate.
provision_ritual() {
  local wt="$1" arrival="$2" out line unstamped=0
  provision_setup=absent
  provision_stamped="-"
  provision_rc="-"
  provision_seconds="-"
  provision_tail=""

  # Placement's typed lines (LINKED/UNIGNORED/SKIPPED_*) pass through; its
  # own misuse FAIL line is the typed failure, so no re-wrapping.
  bash "$orca_scripts_dir/orca.sh" secrets place "$wt" || return 1

  # setup run exits nonzero only on misuse (a bad arrival, a worktree that
  # is not one); its typed FAIL line is then provision's typed failure.
  if ! out="$(bash "$orca_scripts_dir/orca.sh" setup run "$wt" "$arrival" 2>&1)"; then
    printf '%s\n' "$out"
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      # The tail is a frame value, not a pass-through line — it would be a
      # multi-KB blob in the caller's log for no reader.
      SETUP_TAIL:*) provision_tail="${line#SETUP_TAIL:	}" ;;
      SETUP:*)
        printf '%s\n' "$line"
        # `unstamped` is a flag on the script, not an outcome: it precedes
        # the outcome line and rides its own frame key.
        case "$line" in
          "SETUP:	absent")    provision_setup=absent ;;
          "SETUP:	unstamped") unstamped=1 ;;
          "SETUP:	ok	"*)
            provision_setup=ok
            provision_rc=0
            provision_seconds="${line#SETUP:	ok	}" ;;
          "SETUP:	failed	"*)
            provision_setup=failed
            line="${line#SETUP:	failed	}"
            provision_rc="${line%%	*}"
            provision_seconds="${line#*	}" ;;
          "SETUP:	timeout	"*)
            provision_setup=timeout
            provision_rc=124
            provision_seconds="${line#SETUP:	timeout	}" ;;
        esac
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<PROVISION_OUT
$out
PROVISION_OUT
  if [ "$provision_setup" != absent ]; then
    if [ "$unstamped" -eq 1 ]; then provision_stamped=no; else provision_stamped=yes; fi
  fi
  return 0
}

if [ "${ORCA_PROVISION_LIB:-}" != "1" ]; then
  [ $# -eq 2 ] || fail BAD_ARGS "usage: orca.sh provision <worktree> <arrival>"
  provision_ritual "$1" "$2" || exit 1
  if [ -n "$provision_tail" ]; then
    emit_frame rc=0 "arrival=$2" "setup=$provision_setup" "setup_stamped=$provision_stamped" \
      "setup_rc=$provision_rc" "setup_seconds=$provision_seconds" "setup_tail.b64=$provision_tail"
  else
    emit_frame rc=0 "arrival=$2" "setup=$provision_setup" "setup_stamped=$provision_stamped" \
      "setup_rc=$provision_rc" "setup_seconds=$provision_seconds"
  fi
fi
