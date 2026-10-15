# shellcheck shell=bash disable=SC2154
#
# orca council — the deterministic half of orca:council's membership:
# which seats sit, on which models, and where the astra seat's courier
# stages its files. The skill launches council.workflow.js with exactly
# what this prints; deciding who sits is never conversational.
#
# Usage:
#   orca.sh council resolve
#
# The roster is the config's `council` key (written only by orca.sh
# config, so already validated), else ORCA_COUNCIL_DEFAULT. Codex
# availability follows the reviewer's convention:
#
#   key absent  → detect. A codex missing from PATH or below the minimum
#                 version drops every astra seat (DROPPED: lines) and the
#                 council sits with its Claude seats.
#   key pinned  → a pinned astra seat with no usable codex binary is a
#                 typed NO_CODEX — the user asked for that seat, so it is
#                 fixed, never silently vacated.
#
# Detection is binary-at-version ONLY (lib.sh's codex_binary_check, the
# preflight's own). An installed codex that is unauthenticated or no
# longer speaks the `codex exec` flags orca.sh codex drives is
# CODEX_UNUSABLE under either provenance: a broken install is something
# to fix, not to route around.
#
# Output — one TAB-separated line per fact:
#   ROOT:<TAB><dir>        the checkout the members explore: the current
#                          worktree's top level, else the physical $PWD
#   SOURCE:<TAB>pinned|default
#   MEMBER:<TAB><seat><TAB><name><TAB><claude|codex><TAB><model>
#                          one per sitting seat, roster order; seat is the
#                          1-based roster position, model the Claude alias
#                          or the Codex model id
#   DROPPED:<TAB><seat><TAB><name><TAB><reason>
#                          one per vacated astra seat (default roster only)
#   SCRATCH:<TAB><dir>     a fresh directory for the astra courier's prompt
#                          and payload — only when a codex seat sits; the
#                          skill removes it after the merge
#
#   FAIL:<TAB><reason><TAB><detail>    exit 1
#     reasons: BAD_ARGS NOT_GIT OLD_GIT NO_CODEX CODEX_UNUSABLE WRITE_ERROR,
#              plus the config parser's own (PARSE_ERROR, BAD_COUNCIL, …)
#              — every one of those is fixed through orca:config
#
# Read-only apart from the scratch directory. Sourced by orca.sh with the
# verb arguments in place; lib.sh is already loaded.

[ "${1:-}" = resolve ] && [ $# -eq 1 ] || fail BAD_ARGS "usage: orca.sh council resolve"

resolve_repo   # NOT_GIT/OLD_GIT typed; sets repo_root
council_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$council_root" ] || council_root="$(pwd -P)"

if ! council_cfg="$(config_parse "$repo_root/.orca/config")"; then
  printf '%s\n' "$council_cfg"
  exit 1
fi
council_roster="$(config_lookup "$council_cfg" council)"
council_source=pinned
if [ -z "$council_roster" ]; then
  council_roster="$ORCA_COUNCIL_DEFAULT"
  council_source=default
fi

council_wants_codex=0
case ",$council_roster," in
  *,astra,*) council_wants_codex=1 ;;
esac

council_codex_ok=0
if [ "$council_wants_codex" -eq 1 ]; then
  codex_binary_check
  if [ "$codex_binary_ok" -eq 1 ]; then
    codex login status >/dev/null 2>&1 </dev/null \
      || fail CODEX_UNUSABLE "codex is installed but not authenticated — run 'codex login' (orca:doctor walks this through)"
    council_help="$(codex exec --help 2>&1 </dev/null || true)"
    council_missing=""
    for council_flag in --model --output-schema --output-last-message --sandbox --cd; do
      case "$council_help" in
        *"$council_flag"*) ;;
        *) council_missing="${council_missing:+$council_missing, }$council_flag" ;;
      esac
    done
    [ -z "$council_missing" ] \
      || fail CODEX_UNUSABLE "codex ${codex_version:-unknown} has no 'codex exec' $council_missing — upgrade the Codex CLI (orca:doctor walks this through)"
    council_codex_ok=1
  elif [ "$council_source" = pinned ]; then
    fail NO_CODEX "$codex_binary_reason — the pinned council seats astra; install or upgrade the Codex CLI (orca:doctor walks this through), or drop astra with orca:config council=…"
  fi
fi

printf 'ROOT:\t%s\n' "$council_root"
printf 'SOURCE:\t%s\n' "$council_source"
council_seat=0
council_rest="$council_roster,"
while [ -n "$council_rest" ]; do
  council_name="${council_rest%%,*}"
  council_rest="${council_rest#*,}"
  council_seat=$((council_seat + 1))
  if [ "$council_name" != astra ]; then
    printf 'MEMBER:\t%s\t%s\tclaude\t%s\n' "$council_seat" "$council_name" "$council_name"
  elif [ "$council_codex_ok" -eq 1 ]; then
    printf 'MEMBER:\t%s\tastra\tcodex\t%s\n' "$council_seat" "$ORCA_ASTRA_MODEL"
  else
    printf 'DROPPED:\t%s\tastra\t%s\n' "$council_seat" "$codex_binary_reason"
  fi
done

if [ "$council_codex_ok" -eq 1 ]; then
  council_scratch="$(mktemp -d "${TMPDIR:-/tmp}/orca-council.XXXXXX")" \
    || fail WRITE_ERROR "could not create a scratch directory for the astra seat"
  printf 'SCRATCH:\t%s\n' "$(canonicalize "$council_scratch")"
fi
exit 0
