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
# The `status` subcommand adds the other half of the picture for
# orca:status's dashboard: the runs' git footprint — feature/* branches and
# orca-* worktrees — joined to their run directories by slug.
#
# Usage:
#   triage.sh discover
#   triage.sh status
#
# discover output contract — one machine-readable line per fact,
# TAB-separated:
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
#   DONE:<TAB><run-dir><TAB>clean|leftovers|unknown
#       Finished feature runs: depth-1 spec.md WITH a sibling report.md.
#       Emitted in directory order (timestamped names -> oldest first);
#       consumed by orca:retry's and orca:followup's run picks. The third
#       field routes recovery: `leftovers` when report.md's "## Blocked"
#       section lists anything other than "None" (-> orca:retry has unmet
#       items to finish), `clean` when it is "None" (-> orca:followup owns
#       what remains), `unknown` when the section cannot be found (a
#       hand-edited or pre-plugin report). Grep-only and fail-open: unknown
#       still gets retry offered — the audit is the real check, this marker
#       is routing sugar.
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
# status output contract — TAB-separated, one line per git fact. Only the
# runs' own footprint is emitted — the feature/* branch namespace and
# orca-* worktree directory names; the user's branches and worktrees never
# appear. The last field of each line joins the fact to the newest .orca
# run directory carrying its slug (run dirs, orca-<slug> worktree names,
# and feature/<slug>[-<ID>] branch names all carry the slug by
# construction); no surviving run directory reads `orphan`.
#
#   TRUNK:<TAB><branch>
#       The bare repo HEAD's symbolic-ref — the same source preflight's
#       TRUNK_CANDIDATE reads. Absent when HEAD is detached or unset;
#       integration merged-ness then reports unknown, never a guessed
#       trunk.
#   BRANCH:<TAB>feature/<slug><TAB>merged|unmerged|unknown<TAB>ahead:<n|unknown><TAB><run-dir|orphan>
#       Integration branches — feature/* with no -W<N>-shaped suffix —
#       tested against the trunk. ahead:<n> counts the commits the trunk
#       lacks, so "unmerged by one WIP commit" and "unmerged by the whole
#       feature" read differently.
#   ITEMBR:<TAB>feature/<slug>-<ID><TAB>merged|unmerged|unknown<TAB><run-dir|orphan>
#       Item branches (-W<N>-shaped suffix), tested against their
#       integration branch — or against the trunk when that branch is gone
#       (landed and deleted), unknown when neither target exists. merged
#       means a lossless prune; unmerged corroborates a kept blocked item.
#   WORKTREE:<TAB><path><TAB><branch|detached><TAB><run-dir|orphan>
#       orca-* worktree directories only: orca-<slug>[-W<N>] joins its
#       feature run dir (*-feat-<slug>), orca-bug-<slug>[-H<N>] and
#       orca-fix-<slug> join their debug run dir (*-bug-<slug>).
#
#   Read-only, exit 0 always — empty output (beyond TRUNK:) means git holds
#   no orca footprint. Shares discover's only typed failure, FAIL: NOT_GIT.
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

# clean|leftovers|unknown for a finished run, from its report.md's
# "## Blocked" section — every unmet item lands there (the pump's cascade
# and budget stops all route through block()). Read-only and fail-open:
# a missing section is `unknown`, never a guess.
done_state() { # <report.md>
  awk '
    /^##[[:space:]]+Blocked[[:space:]]*$/ { found = 1; insec = 1; next }
    insec && /^##[[:space:]]/ { insec = 0 }
    insec { body = body $0 }
    END {
      if (!found) { print "unknown"; exit }
      # Strip list markers, punctuation, and whitespace; an empty section or
      # a lone "None" (however bulleted) means nothing is blocked.
      gsub(/[-*.[:space:]]/, "", body)
      if (body == "" || tolower(body) == "none") print "clean"
      else print "leftovers"
    }' "$1" 2>/dev/null || echo "unknown"
}

cmd_discover() {
  resolve_repo
  local orca="$repo_root/.orca"
  local runid args value

  # --- feature runs: .orca/*/spec.md at depth 1, no sibling report.md ---
  # A sibling report.md means the run finished; DONE: lines feed
  # orca:retry's and orca:followup's run picks, in directory order
  # (timestamped names, so oldest first — the last line is the newest run),
  # each tagged with the report's blocked-section state.
  local spec dir run_ln
  for spec in "$orca"/*/spec.md; do
    [[ -f "$spec" ]] || continue
    dir="$(dirname "$spec")"
    if [[ -f "$dir/report.md" ]]; then
      printf 'DONE:\t%s\t%s\n' "$dir" "$(done_state "$dir/report.md")"
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

# git against the resolved repo regardless of CWD — status may be invoked
# from any worktree or from the repo root, which in the bare layout is not
# a working directory at all.
g() { git --git-dir="$common_dir" "$@"; }

# Newest .orca run dir whose basename ends in -<verb>-<slug>; `orphan` when
# none survives. Timestamped names make directory order chronological, so
# the last glob match is the newest (a rerun after a full cleanup joins its
# own dir, older same-slug dirs render on their .orca facts alone). The
# feat fallback without the verb marker covers pre-plugin run dirs, and
# skips anything carrying either verb's marker so a bare suffix never
# cross-joins another slug's run.
run_join() { # <slug> <feat|bug>
  local d match=""
  for d in "$repo_root/.orca/"*"-$2-$1"; do
    [[ -d "$d" ]] && match="$d"
  done
  if [[ -z "$match" && "$2" == feat ]]; then
    for d in "$repo_root/.orca/"*"-$1"; do
      [[ -d "$d" && "$(basename "$d")" != *"-feat-"* \
        && "$(basename "$d")" != *"-bug-"* ]] && match="$d"
    done
  fi
  printf '%s' "${match:-orphan}"
}

# merged|unmerged|unknown — an empty target means there is nothing to test
# against (detached/unset trunk, or an item branch whose targets are gone).
merged_state() { # <branch> <target>
  [[ -n "$2" ]] || { echo unknown; return; }
  if g merge-base --is-ancestor "$1" "$2" 2>/dev/null; then
    echo merged
  else
    echo unmerged
  fi
}

cmd_status() {
  resolve_repo
  local trunk
  trunk="$(g symbolic-ref --short HEAD 2>/dev/null || true)"
  [[ -n "$trunk" ]] && printf 'TRUNK:\t%s\n' "$trunk"

  # --- feature/* branches: integration vs item by -W<N> shape ---
  local ref slug base target state ahead
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    if [[ "$ref" =~ ^feature/(.+)-W[0-9]+$ ]]; then
      slug="${BASH_REMATCH[1]}"
      base="feature/$slug"
      if g show-ref --verify --quiet "refs/heads/$base"; then
        target="$base"
      else
        # Integration branch landed and deleted — the trunk inherits the
        # test; empty when the trunk is unknown too.
        target="$trunk"
      fi
      printf 'ITEMBR:\t%s\t%s\t%s\n' \
        "$ref" "$(merged_state "$ref" "$target")" "$(run_join "$slug" feat)"
    else
      slug="${ref#feature/}"
      state="$(merged_state "$ref" "$trunk")"
      if [[ "$state" == unknown ]]; then
        ahead="unknown"
      else
        ahead="$(g rev-list --count "$trunk..$ref" 2>/dev/null || echo unknown)"
      fi
      printf 'BRANCH:\t%s\t%s\tahead:%s\t%s\n' \
        "$ref" "$state" "$ahead" "$(run_join "$slug" feat)"
    fi
  done < <(g for-each-ref --format='%(refname:short)' refs/heads/feature/)

  # --- orca-* worktrees, joined by the slug their directory name carries ---
  local line wt_path="" wt_branch="detached" name verb
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)          wt_path="${line#worktree }"; wt_branch="detached" ;;
      "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
      "")
        name="$(basename "${wt_path:-/}")"
        if [[ -n "$wt_path" && "$name" == orca-* ]]; then
          if   [[ "$name" =~ ^orca-bug-(.+)-H[0-9]+$ ]]; then slug="${BASH_REMATCH[1]}"; verb=bug
          elif [[ "$name" =~ ^orca-bug-(.+)$ ]];         then slug="${BASH_REMATCH[1]}"; verb=bug
          elif [[ "$name" =~ ^orca-fix-(.+)$ ]];         then slug="${BASH_REMATCH[1]}"; verb=bug
          elif [[ "$name" =~ ^orca-(.+)-W[0-9]+$ ]];     then slug="${BASH_REMATCH[1]}"; verb=feat
          else                                                slug="${name#orca-}";      verb=feat
          fi
          printf 'WORKTREE:\t%s\t%s\t%s\n' \
            "$wt_path" "$wt_branch" "$(run_join "$slug" "$verb")"
        fi
        wt_path=""
        ;;
    esac
  done < <(g worktree list --porcelain; printf '\n')

  exit 0
}

case "${1:-}" in
  discover) cmd_discover ;;
  status)   cmd_status ;;
  *)        fail BAD_ARGS "usage: triage.sh discover|status" ;;
esac
