#!/usr/bin/env bash
#
# orca triage — the read-only discovery spine of orca:feature's and
# orca:debug's Step 0: what is waiting under .orca/, and the byte-exact
# resume handles for anything interrupted. Both skills call the same
# subcommand and read only their own line types; the "is it actually live
# right now" check stays conversational — only the session can inspect its
# own task list and background tasks. No bare-layout requirement: triage
# runs before the preflight.
#
# Usage:
#   triage.sh discover
#
# Output contract — one machine-readable line per fact, TAB-separated:
#
#   RUN:<TAB><run-dir><TAB>interrupted|unlaunched
#       Feature runs: .orca/*/spec.md at depth 1 (feat-briefs/ has none;
#       debug runs keep theirs nested at fix/spec.md) with no sibling
#       report.md. interrupted -> the workflow launched; followed by:
#         RUNID:<TAB><id>                the LAST **Workflow run:** line
#         ARGS:<TAB><json|absent>        from that run's own record only —
#                                        the lines following the last run
#                                        line; a record cut short (session
#                                        died between the two appends)
#                                        reports absent, never an older
#                                        launch's values under a newer runId
#         REVIEWER:<TAB><value|absent>   legacy fallback, pre-args records;
#         AGENTS:<TAB><json|absent>      same adjacency rule
#       unlaunched -> spec.md carries no runId line: the run died before
#       its workflow launched (not resumable).
#   DONE:<TAB><run-dir>
#       Finished feature runs: depth-1 spec.md WITH a sibling report.md.
#       Emitted in directory order (timestamped names -> oldest first);
#       consumed by orca:followup's run pick.
#   BRIEF:<TAB><path>
#       Queued briefs: .orca/feat-briefs/*.md, top level only (drafts/
#       does not count).
#   CASE:<TAB><slug><TAB>interrupted|ready
#       Open cases: .orca/bug-cases/<slug>/case.md. interrupted -> the LAST
#       **Workflow run:**/**Workflow args:** pair names a run dir with no
#       report.md; followed by the same RUNID:/ARGS: lines. ready -> never
#       launched, or the last run completed and left the case open.
#
#   Exit 0 always — empty output means nothing is waiting. The only typed
#   failure: FAIL:<TAB>NOT_GIT<TAB><detail>, exit 1.
#
# The ARGS payloads are the point: a resume must replay the launch args
# byte-identical (any drift changes agent prompts and re-runs completed
# stages instead of replaying them from the journal), and extracting the
# one-line JSON here keeps it out of model transcription.

set -uo pipefail

fail() { # <reason> <detail> — typed failure, exit 1
  printf 'FAIL:\t%s\t%s\n' "$1" "$2"
  exit 1
}

resolve_repo() {
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -z "$common_dir" ]]; then
    fail NOT_GIT "not inside a git repository — nothing to triage"
  fi
  repo_root="$(dirname "$common_dir")"
}

# Line number of the LAST "**Workflow run:**" line in a file; empty when none.
last_run_line() { # <file>
  grep -n '^\*\*Workflow run:\*\*' "$1" | tail -1 | cut -d: -f1
}

# Value of the first "**<label>:** <value>" line at or after line <from-line>;
# empty when none. Companion lines are read only from the record that follows
# the LAST run line — a session that died between appending the run line and
# its args line yields `absent`, never an older launch's values paired with
# the newer runId.
record_value() { # <file> <label> <from-line>
  tail -n "+$3" "$1" | sed -n "s/^\*\*$2:\*\*[[:space:]]*//p" | head -1
}

cmd_discover() {
  resolve_repo
  local orca="$repo_root/.orca"
  local runid args value

  # --- feature runs: .orca/*/spec.md at depth 1, no sibling report.md ---
  # A sibling report.md means the run finished; DONE: lines feed
  # orca:followup's run pick, in directory order (timestamped names, so
  # oldest first — the last line is the newest run).
  local spec dir run_ln
  for spec in "$orca"/*/spec.md; do
    [[ -f "$spec" ]] || continue
    dir="$(dirname "$spec")"
    if [[ -f "$dir/report.md" ]]; then
      printf 'DONE:\t%s\n' "$dir"
      continue
    fi
    run_ln="$(last_run_line "$spec")"
    if [[ -z "$run_ln" ]]; then
      printf 'RUN:\t%s\tunlaunched\n' "$dir"
      continue
    fi
    runid="$(record_value "$spec" "Workflow run" "$run_ln")"
    printf 'RUN:\t%s\tinterrupted\n' "$dir"
    printf 'RUNID:\t%s\n' "$runid"
    args="$(record_value "$spec" "Workflow args" "$run_ln")"
    printf 'ARGS:\t%s\n' "${args:-absent}"
    value="$(record_value "$spec" "Workflow reviewer" "$run_ln")"
    printf 'REVIEWER:\t%s\n' "${value:-absent}"
    value="$(record_value "$spec" "Workflow agents" "$run_ln")"
    printf 'AGENTS:\t%s\n' "${value:-absent}"
  done

  # --- queued briefs: top level only ---
  local brief
  for brief in "$orca"/feat-briefs/*.md; do
    [[ -f "$brief" ]] || continue
    printf 'BRIEF:\t%s\n' "$brief"
  done

  # --- open cases: interrupted iff the last launch's run dir lacks report.md ---
  local casemd casedir rundir
  for casemd in "$orca"/bug-cases/*/case.md; do
    [[ -f "$casemd" ]] || continue
    casedir="$(dirname "$casemd")"
    run_ln="$(last_run_line "$casemd")"
    if [[ -z "$run_ln" ]]; then
      printf 'CASE:\t%s\tready\n' "$(basename "$casedir")"
      continue
    fi
    runid="$(record_value "$casemd" "Workflow run" "$run_ln")"
    args="$(record_value "$casemd" "Workflow args" "$run_ln")"
    # The recorded args carry the run dir; the sole writer's canonical JSON
    # makes the grep safe. A pair with no locatable run dir stays
    # interrupted — never guessed ready.
    rundir="$(printf '%s' "$args" \
      | grep -o '"runDir"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
      | sed 's/^.*:[[:space:]]*"//; s/"$//')"
    if [[ -n "$rundir" && -f "$rundir/report.md" ]]; then
      printf 'CASE:\t%s\tready\n' "$(basename "$casedir")"
      continue
    fi
    printf 'CASE:\t%s\tinterrupted\n' "$(basename "$casedir")"
    printf 'RUNID:\t%s\n' "$runid"
    printf 'ARGS:\t%s\n' "${args:-absent}"
  done

  exit 0
}

case "${1:-}" in
  discover) cmd_discover ;;
  *)        fail BAD_ARGS "usage: triage.sh discover" ;;
esac
