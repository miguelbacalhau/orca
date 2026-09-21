# shellcheck shell=bash disable=SC2154
#
# orca codex — the transport for the cross-model reviewer: run one
# Codex review non-interactively and land its JSON findings on disk.
#
# Usage:
#   orca.sh codex <prompt-file> --cwd <dir> --out <file>
#                 [--archive <file>] [--timeout <s>]
#
# Why a verb and not an MCP tool. Through orca 0.32.0 the reviewer was
# reached over MCP, via a bundled registration that ran `codex
# mcp-server`. The Codex CLI removed that subcommand (gone by 0.155.1,
# where `codex mcp` only MANAGES external servers and nothing in the
# binary serves MCP), and the removal is silent in the worst way: an
# unknown subcommand is taken as a TUI prompt, so the server died with
# "stdin is not a terminal" and every review failed as "Connection
# closed" deep inside a run. `codex exec` is the supported
# non-interactive entry point and is a better fit anyway:
#
#   --output-schema  makes the findings shape a hard contract enforced
#                    by Codex, not a plea in the prompt
#   -o <file>        writes the final message straight to disk, so the
#                    artifact is verbatim BY CONSTRUCTION — no courier
#                    transcribes it, so no courier can corrupt it
#   -s read-only     the review never writes into the worktree
#   -C <dir>         the item's worktree as the working root
#
# The prompt arrives as a FILE and is fed on stdin (`codex exec -`):
# review prompts are multi-KB, multi-line, and full of quotes and
# backticks, and argv quoting of that through an agent's shell call is
# a corruption channel. The agent Writes the prompt, this verb moves
# bytes.
#
# The prompt file is passed by path but never inspected: what Codex is
# asked is the agent's judgment, what happens to the process is this
# verb's.
#
# Auth, model, and reasoning effort come from the user's own codex
# config — orca pins none of them. The binary is whatever `codex` is
# first on $PATH, exactly as the MCP registration was: a shadowed or
# tampered `codex` there runs with the review's permissions, so PATH
# hygiene stays part of the review trust story.
#
# Output — always one frame, never a typed failure for a review that
# merely went badly (a failed review is a retryable workflow outcome,
# and the loops need the reason, not an exit status):
#   rc        0 when the payload landed, 1 otherwise
#   status    ok | timeout | exec_failed | no_output | bad_payload
#   out       the artifact path (echoed; on rc=1 nothing was written)
#   archive   the round-archive path, or '-'
#   bytes     size of the payload written; 0 on failure
#   seconds   wall clock of the codex call
#   tail.b64  last 4 KB of the codex log — on rc=1 only. A workflow's
#             log() is invisible mid-run (anthropics/claude-code#74419),
#             so this is the only channel that reaches a human in time.
#
# Typed failures are MISUSE only, by the same contract the other verbs
# keep: BAD_ARGS, NO_CODEX, WRITE_ERROR.
#
# Nothing is written to <out> (or <archive>) unless the payload passed
# the checks — a missing artifact is a retryable failure, a corrupt one
# is a silent lie.
#
# Sourced by orca.sh with the verb arguments in place; lib.sh (fail,
# emit_frame, b64_encode) is already loaded.

# Wall-clock cap for one review, in seconds. Deliberately BELOW the
# twenty minutes the review agents give the Bash tool (and that
# orca:doctor writes as BASH_MAX_TIMEOUT_MS), not equal to it: the whole
# point of capping here is that a wedged codex dies with a reported
# reason rather than being killed from outside with none, and two equal
# deadlines race — the outer one can land during the watchdog's
# five-second KILL escalation or mid-frame, which is exactly the report
# being protected. Eighteen minutes leaves ~2 minutes of headroom for
# the escalation, the payload checks, and emission. Twenty minutes
# outside was itself sized by a cold adversarial review of a large diff
# (a real one on this repo runs ~4).
CODEX_TIMEOUT=1080

codex_prompt=""
codex_cwd=""
codex_out=""
codex_archive=""
codex_cap="$CODEX_TIMEOUT"

[ $# -ge 1 ] || fail BAD_ARGS "usage: orca.sh codex <prompt-file> --cwd <dir> --out <file> [--archive <file>] [--timeout <s>]"
codex_prompt="$1"; shift
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)     [ $# -ge 2 ] || fail BAD_ARGS "--cwd needs a value";     codex_cwd="$2";     shift 2 ;;
    --out)     [ $# -ge 2 ] || fail BAD_ARGS "--out needs a value";     codex_out="$2";     shift 2 ;;
    --archive) [ $# -ge 2 ] || fail BAD_ARGS "--archive needs a value"; codex_archive="$2"; shift 2 ;;
    --timeout) [ $# -ge 2 ] || fail BAD_ARGS "--timeout needs a value"; codex_cap="$2";     shift 2 ;;
    *) fail BAD_ARGS "unknown argument '$1' — usage: orca.sh codex <prompt-file> --cwd <dir> --out <file> [--archive <file>] [--timeout <s>]" ;;
  esac
done

[ -n "$codex_cwd" ] || fail BAD_ARGS "--cwd is required"
[ -n "$codex_out" ] || fail BAD_ARGS "--out is required"

# A newline in a path would be a second line inside the frame, which the
# decoder reads as another key — lib.sh's framing contract says a value
# outside a .b64 key never contains one. Refused up front rather than
# encoded: every caller's paths are run-directory paths, so this can only
# ever be a mistake, and a typed failure names it.
for codex_p in "$codex_prompt" "$codex_cwd" "$codex_out" "$codex_archive"; do
  [[ "$codex_p" == *$'\n'* ]] && fail BAD_ARGS "paths may not contain newlines"
done

# Canonicalize before anything uses these. The codex call runs in a
# subshell that cds into the worktree, and a redirection is applied AFTER
# the cd — so a relative prompt path would be opened somewhere else than
# the one just validated, or not at all. Absolute-from-here removes the
# whole class, for the destinations too.
codex_prompt="$(canonicalize "$codex_prompt")"
codex_cwd="$(canonicalize "$codex_cwd")"
codex_out="$(canonicalize "$codex_out")"
[ -n "$codex_archive" ] && codex_archive="$(canonicalize "$codex_archive")"

[ -f "$codex_prompt" ] || fail BAD_ARGS "prompt file not found: $codex_prompt"
[ -s "$codex_prompt" ] || fail BAD_ARGS "prompt file is empty: $codex_prompt"
[ -d "$codex_cwd" ] || fail BAD_ARGS "--cwd is not a directory: $codex_cwd"
[[ "$codex_cap" =~ ^[0-9]+$ ]] && [ "$codex_cap" -gt 0 ] || fail BAD_ARGS "--timeout must be a positive integer: $codex_cap"
command -v codex >/dev/null 2>&1 || fail NO_CODEX "codex not on PATH — install the Codex CLI from its official non-npm distribution (orca:doctor walks this through), or pin reviewer=claude via orca:config"

codex_schema="$orca_scripts_dir/codex-findings.schema.json"
[ -f "$codex_schema" ] || fail WRITE_ERROR "missing bundled schema: $codex_schema"

codex_scratch="$(mktemp -d "${TMPDIR:-/tmp}/orca-codex.XXXXXX")" \
  || fail WRITE_ERROR "could not create a scratch directory for the codex log"
codex_log="$codex_scratch/codex.log"
codex_payload="$codex_scratch/payload.json"
codex_flag="$codex_scratch/timedout"

# The same hand-rolled watchdog setup.sh uses, and for the same reason:
# stock macOS has no timeout(1). Job control gives the child its own
# process group so TERM reaches whatever codex spawned; the sentinel
# file, not the exit status, is the timeout's evidence, since a process
# is free to exit 143 on its own.
codex_start="$(date +%s)"
set -m
(
  cd "$codex_cwd" || exit 125
  exec codex exec \
    --sandbox read-only \
    --cd "$codex_cwd" \
    --output-schema "$codex_schema" \
    --output-last-message "$codex_payload" \
    - <"$codex_prompt"
) >"$codex_log" 2>&1 &
codex_child=$!
( sleep "$codex_cap" ; trap '' TERM ; : >"$codex_flag" ; kill -TERM -"$codex_child" 2>/dev/null ; \
  sleep 5 ; kill -KILL -"$codex_child" 2>/dev/null ) &
codex_watcher=$!
set +m
wait "$codex_child" 2>/dev/null
codex_rc=$?
# Once the deadline fires, finish the KILL escalation even if Codex itself
# exits on TERM: its children may still be alive. The watcher's TERM trap
# also protects the race between checking the flag and cancelling it.
[ -e "$codex_flag" ] || kill -TERM -"$codex_watcher" 2>/dev/null
wait "$codex_watcher" 2>/dev/null
codex_seconds=$(( $(date +%s) - codex_start ))
[ -e "$codex_flag" ] && codex_rc=124

codex_give_up() { # <status> — frame the failure with the log tail, clean up, exit 0
  emit_frame rc=1 "status=$1" "out=$codex_out" "archive=${codex_archive:--}" \
    bytes=0 "seconds=$codex_seconds" \
    "tail.b64=$(tail -c 4096 "$codex_log" 2>/dev/null | b64_encode)"
  rm -rf "$codex_scratch"
  exit 0
}

if [ "$codex_rc" -eq 124 ]; then
  codex_give_up timeout
elif [ "$codex_rc" -ne 0 ]; then
  codex_give_up exec_failed
elif [ ! -s "$codex_payload" ]; then
  codex_give_up no_output
fi

# Validate the entire JSON document before replacing either destination.
# An inner object's closing brace is not evidence that the document is
# complete. Codex enforces the finding schema; this portable awk guard
# checks JSON syntax and the top-level findings array without changing
# bytes or counting findings (which remains the review agent's job).
LC_ALL=C awk -f "$orca_scripts_dir/codex-payload.awk" "$codex_payload" \
  || codex_give_up bad_payload

# Publish by rename, never by writing into the destination. A cp into
# the final path can truncate an existing artifact if it is interrupted
# or the disk fills, and a re-review round's destination usually DOES
# already exist — the contract this verb sells is that a review lands
# whole or leaves what was there untouched. Staging beside the
# destination keeps the rename within one filesystem, where it is
# atomic. Both stages are prepared before either is published, so an
# archive that cannot be written no longer leaves the artifact already
# replaced.
codex_stage() { # <destination> — stage the payload beside it, echo the stage path
  local dir stage
  dir="$(dirname "$1")"
  mkdir -p "$dir" || fail WRITE_ERROR "could not create $dir"
  stage="$(mktemp "$dir/.orca-codex.XXXXXX")" || fail WRITE_ERROR "could not stage into $dir"
  cp "$codex_payload" "$stage" || { rm -f "$stage"; fail WRITE_ERROR "could not write $stage"; }
  printf '%s' "$stage"
}
codex_out_stage="$(codex_stage "$codex_out")"
codex_archive_stage=""
if [ -n "$codex_archive" ]; then
  codex_archive_stage="$(codex_stage "$codex_archive")" \
    || { rm -f "$codex_out_stage"; fail WRITE_ERROR "could not stage the round archive"; }
fi
mv "$codex_out_stage" "$codex_out" \
  || { rm -f "$codex_out_stage" "$codex_archive_stage"; fail WRITE_ERROR "could not publish $codex_out"; }
if [ -n "$codex_archive_stage" ]; then
  mv "$codex_archive_stage" "$codex_archive" \
    || { rm -f "$codex_archive_stage"; fail WRITE_ERROR "could not publish $codex_archive"; }
fi

codex_bytes="$(wc -c <"$codex_payload" | tr -d ' ')"
rm -rf "$codex_scratch"
emit_frame rc=0 status=ok "out=$codex_out" "archive=${codex_archive:--}" \
  "bytes=$codex_bytes" "seconds=$codex_seconds"
