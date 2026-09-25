# shellcheck shell=bash
#
# orca triage — the discovery spine of orca:feature's Step 0, orca:status's dashboard, and the home of the per-run lease.
# The read-only boundary runs PER SUBCOMMAND: `discover`, `status`,
# `snapshot`, and `archive --scan` never write anything; `claim` and
# `release` are the lease's writer pair — the ONLY writers of
# <run-dir>/.lock anywhere in orca (both workflow scripts call them
# through orca.sh) — and `archive`/`unarchive` are the archived marker's
# writer pair, the ONLY writers of <run-dir>/archived. No bare-layout
# requirement: triage runs before the preflight.
#
# Usage:
#   orca.sh triage discover [--reports]
#   orca.sh triage status
#   orca.sh triage snapshot [--reports] [--run <fragment>]
#   orca.sh triage archive --scan
#   orca.sh triage archive <run-dir>
#   orca.sh triage unarchive <run-dir>
#   orca.sh triage claim [--steal] [--runid <id>] <run-dir> <note>
#   orca.sh triage release <run-dir>
#
# discover output contract — one machine-readable line per fact,
# TAB-separated:
#
#   RUN:<TAB><run-dir><TAB>interrupted|unlaunched
#       Feature runs: .orca/*/spec.md at depth 1 (feat-briefs/ has none)
#       with no sibling report.md. interrupted -> the workflow launched; followed by:
#         RUNID:<TAB><id|absent>         the LAST **Workflow run:** line
#                                        (absent when its value is empty —
#                                        a hand-mangled record)
#         ARGS:<TAB><json|absent>        from that run's own record only —
#                                        the lines following the last run
#                                        line; a record cut short (session
#                                        died between the two appends)
#                                        reports absent, never an older
#                                        launch's values under a newer runId
#         REVIEWER:<TAB><value|absent>   legacy fallback, pre-args records;
#         AGENTS:<TAB><json|absent>      same adjacency rule
#       unlaunched -> spec.md carries no runId line, OR the directory holds
#       brief.md with no spec.md yet (the session died between consuming
#       the brief and writing the spec — the brief would otherwise be lost
#       to all discovery, feat-briefs/ no longer holding it). Not
#       journal-resumable; the run skill decides the recovery.
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
#       is routing sugar. Followed by BLOCKED:/FOLLOWUP: enrichment (below).
#   LEASE:<TAB>live|stale|none|unknown<TAB>pid:<n|-><TAB>since:<iso|->
#       Follows every RUN: and DONE: line — the lease reader's verdict on
#       that run directory's .lock:
#         none    — no .lock.
#         live    — host matches, the pid is running, and its start time
#                   matches verbatim: AN OPEN SESSION ON THIS HOST OWNS
#                   THIS RUN. The pid is the session's claude process, not
#                   the workflow — a TaskStop'd or /clear'ed session reads
#                   live too, so skills must phrase live as "owned by an
#                   open session", never "executing right now".
#         stale   — host matches but the pid is gone or its start time
#                   differs: the holder provably crashed; safe to steal
#                   (claim --steal) without asking. A stale lease on a
#                   DONE: run is stranded garbage from a session that died
#                   between writing report.md and releasing — without this
#                   line it would be invisible forever.
#         unknown — another host (or an unreadable owner file); the only
#                   case where the liveness caveat survives.
#   BLOCKED:<TAB><run-dir><TAB><b64>
#   FOLLOWUP:<TAB><run-dir><TAB><b64>
#       DONE: runs, --reports only — the report's "## Blocked" /
#       "## Follow-ups" section bodies, base64 (one line each; decode
#       before rendering). Emitted only when the section exists, so
#       consumers never see a guessed empty body. Off by default,
#       deliberately: the bodies grow with run HISTORY, not with
#       actionable state, and every entry-point skill calls this verb —
#       orca:status, the one consumer that renders the bodies, opts in
#       with --reports; every other caller routes on the DONE: tag alone.
#   ARCHIVED:<TAB><run-dir>
#       Finished runs retired by `triage archive` (an `archived` marker
#       file beside report.md): one bare line — no LEASE:, no BLOCKED:/
#       FOLLOWUP: enrichment, no ACTION: routing, no MATCH-candidacy
#       loss (the dirs still list as CANDIDATE:/MATCH: under --run).
#       orca:followup still picks archived runs (their reports keep the
#       deferred follow-ups); every other caller ignores the line. The
#       marker is honored only beside a report.md, so a stray marker can
#       never hide a resumable run.
#   BRIEF:<TAB><path>
#       Queued briefs: .orca/feat-briefs/*.md, top level only (drafts/
#       does not count).
#
#   Exit 0 always — empty output means nothing is waiting. The only typed
#   failures: FAIL:<TAB>NOT_GIT<TAB><detail> and FAIL:<TAB>OLD_GIT<TAB><detail> (git < 2.31), exit 1.
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
#       feature run dir (*-feat-<slug>).
#
#   Read-only, exit 0 always — empty output (beyond TRUNK:) means git holds
#   no orca footprint. Shares discover's typed failures, FAIL: NOT_GIT / OLD_GIT.
#
# snapshot — discover and status folded into ONE read-only call (both fact
# domains plus the slug join are needed to compute the actions, and it
# saves the dashboard a round trip), followed by:
#
#   MATCH:<TAB><run-dir>              --run only: run dirs (RUN:/DONE:)
#                                     whose basename contains the fragment
#   MISS:<TAB><fragment>              --run only, no match — followed by
#     CANDIDATE:<TAB><run-dir>        one line per existing run dir
#   ACTION:<TAB><rank><TAB><slug><TAB><owner-skill|-><TAB><target><TAB><b64 evidence>
#       The routing conclusion, ranked mechanically: interrupted →
#       queued → recovery → housekeeping. Slugs: resume-run, requeue-brief,
#       run-brief, finish-unmet, review-deliverable, followup,
#       prune-branch, prune-worktree, inspect-orphan. The owner tag is the
#       skill that acts on the line (feature, retry, followup,
#       review; `-` = user housekeeping) so each caller filters its own.
#       These are ordered CANDIDATES, not commands — the skills present,
#       never force. A run whose lease reads live gets NO resume action:
#       an open session owns it. Evidence is one base64 line.
#
# claim/release output contract:
#
#   CLAIMED:<TAB><run-dir><TAB>pid:<n>      the lease is taken; the owner
#                                           file records the walked session
#                                           pid (see below), host, verbatim
#                                           pid start time, note, timestamp
#   RELEASED:<TAB><run-dir>                 .lock and any .lock.stale.*
#                                           remnants removed; idempotent
#   Typed failures, exit 1: LEASE_HELD (the lock exists — the detail names
#   the owner and the reader's verdict), NOT_STALE (--steal against a lease
#   not provably stale), STEAL_RACED (another contender won the rename),
#   NO_RUN_DIR, BAD_ARGS.
#
# archive output contract — the retirement gate is provable, never
# guessed: report.md present, Blocked section "None", lease not live,
# every feature/* branch joining this run dir (integration and item
# alike, through the same anchored run_join the status join uses) merged
# into the trunk — absent branches pass (landed and pruned) — and every
# joined orca-* worktree removable without loss: a detached one's HEAD
# merged too (else NOT_LANDED), none dirty, locked, holding this shell's
# cwd, and no run branch checked out outside the run or being the trunk
# (else WORKTREE_IN_USE). The write form then removes that footprint —
# worktrees first, then branches, never --force — and writes the marker
# recording each removal and branch tip. TAB-separated:
#
#   ARCHIVABLE:<TAB><run-dir><TAB><evidence>     --scan: every gate passes
#       (evidence is one plain line — script-composed, no free prose),
#       followed by the footprint the write form will remove:
#     PRUNE:<TAB><run-dir><TAB>worktree|branch<TAB><path|name>
#   KEPT:<TAB><run-dir><TAB><reason><TAB><detail> --scan: a gate failed;
#       reason NOT_CLEAN|LEASE_LIVE|NO_TRUNK|NOT_LANDED|WORKTREE_IN_USE.
#       Finished runs only — unfinished runs are RUN:, never candidates.
#   PRUNED:<TAB>worktree<TAB><path>              write form, per removal,
#   PRUNED:<TAB>branch<TAB><name><TAB><sha>      in removal order
#   ARCHIVED:<TAB><run-dir>       --scan: already archived; write form:
#                                 the marker is written (idempotent — an
#                                 archived run is never re-pruned)
#   RESTORED:<TAB>branch<TAB><name><TAB><sha>    unarchive: recreated at
#                                                its recorded tip
#   NOT_RESTORED:<TAB>branch<TAB><name><TAB><why> unarchive: exists again,
#                                                or its commit is gone
#   UNARCHIVED:<TAB><run-dir>     marker removed; idempotent
#   Typed failures, exit 1: NO_RUN_DIR, NO_REPORT, NOT_CLEAN, LEASE_LIVE,
#   NO_TRUNK, NOT_LANDED, WORKTREE_IN_USE, PRUNE_FAILED (git refused a
#   removal after the gate passed — no marker written; re-run to finish),
#   BAD_ARGS.
#
# The ARGS payloads are the point: a resume must replay the launch args
# byte-identical (any drift changes agent prompts and re-runs completed
# stages instead of replaying them from the journal), and extracting the
# one-line JSON here keeps it out of model transcription.
#
# Sourced by orca.sh (orca.sh triage ...); the lib is loaded but this
# verb keeps its own internal helpers, renamed triage_* where they
# would collide with lib.sh's fail()/resolve_repo() (its NOT_GIT
# detail and resolved variables differ from the lib's).

triage_fail() { # <reason> <detail> — typed failure, exit 1
  printf 'FAIL:\t%s\t%s\n' "$1" "$2"
  exit 1
}

# The --reports opt-in, set by the discover/snapshot flag loops and read
# by emit_done_extras. Default off: the BLOCKED:/FOLLOWUP: bodies are the
# only part of the output that grows with run HISTORY rather than with
# actionable state, and only orca:status renders them.
want_reports=0

triage_resolve_repo() {
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  # An empty result can mean old git, not no-git: --path-format needs
  # git >= 2.31, and misreporting that as NOT_GIT sends users chasing the
  # wrong problem.
  if [[ -z "$common_dir" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
    triage_fail OLD_GIT "git $(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -1) lacks --path-format (orca needs git >= 2.31) — upgrade git"
  fi
  if [[ -z "$common_dir" ]]; then
    triage_fail NOT_GIT "not inside a git repository — nothing to triage"
  fi
  repo_root="$(dirname "$common_dir")"
}

# ---- the lease: claim/release writer pair and the LEASE: reader --------
# Atomic mkdir <run-dir>/.lock is the lock; the owner file inside is
# machine-readable identity (runid=, host=, pid=, pidstart=, note=,
# taken=). This verb is the lease's single home: the workflows and the
# run skills all take and release it through orca.sh, so the pid-capture
# rule below lives in exactly one place and nothing else may write an
# owner file.

# The session's process, found by WALKING, never by a pinned depth: start
# at $$ and step up past every ancestor whose comm is a shell
# (sh/bash/zsh/dash — login '-' prefix and path prefix stripped),
# recording the first non-shell ancestor. The common chain is
# claude -> tool shell -> orca.sh, but shells exec-optimize their last
# command in some configurations and the intermediate layer collapses; a
# pinned grandparent rule would then record the terminal app — a lease
# that reads live essentially forever, the worst failure direction.
lease_session_pid() {
  local pid=$$ parent comm
  while :; do
    parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    case "$parent" in '' | 0 | 1) break ;; esac
    comm="$(ps -o comm= -p "$parent" 2>/dev/null | tr -d '[:space:]')"
    comm="${comm##*/}"
    comm="${comm#-}"
    case "$comm" in
      sh | bash | zsh | dash) pid="$parent" ;;
      *)
        printf '%s' "$parent"
        return
        ;;
    esac
  done
  # Every ancestor to the process-tree root was a shell (or ps failed):
  # record the topmost shell examined rather than pid 1/0.
  printf '%s' "$pid"
}

emit_lease() { # <run-dir>
  printf 'LEASE:\t%s\n' "$(lease_read "$1")"
}

cmd_claim() {
  local steal=0 runid="" rundir note lock verdict pid
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --steal)
        steal=1
        shift
        ;;
      --runid)
        runid="${2:-}"
        shift 2
        ;;
      *) triage_fail BAD_ARGS "unknown flag '$1' — usage: triage.sh claim [--steal] [--runid <id>] <run-dir> <note>" ;;
    esac
  done
  rundir="${1:-}"
  note="${2:-}"
  if [[ -z "$rundir" || -z "$note" ]]; then
    triage_fail BAD_ARGS "usage: triage.sh claim [--steal] [--runid <id>] <run-dir> <note>"
  fi
  [[ -d "$rundir" ]] || triage_fail NO_RUN_DIR "not a directory: $rundir"
  lock="$rundir/.lock"
  if [[ "$steal" -eq 1 && -e "$lock" ]]; then
    verdict="$(lease_read "$rundir" | cut -f1)"
    [[ "$verdict" == stale ]] || triage_fail NOT_STALE "refusing to steal $lock: the lease reads '$verdict', not stale"
    # The steal is an atomic RENAME, then a normal claim. rm-then-mkdir has
    # a TOCTOU hole (a second contender can remove the winner's FRESH
    # lock); mv has exactly one winner — the loser's mv fails on the
    # vanished source. The remnant is removed by the next release.
    mv "$lock" "$lock.stale.$$" 2>/dev/null \
      || triage_fail STEAL_RACED "another contender stole $lock first"
  fi
  if ! mkdir "$lock" 2>/dev/null; then
    triage_fail LEASE_HELD "run directory is leased to another writer — $lock exists (lease: $(lease_read "$rundir" | tr '\t' ' '); owner: $(tr '\n' ' ' <"$lock/owner" 2>/dev/null || printf 'unknown')). stale -> 'triage claim --steal' recovers it without asking; live -> an open session owns this run."
  fi
  pid="$(lease_session_pid)"
  {
    printf 'runid=%s\n' "$runid"
    printf 'host=%s\n' "$(hostname)"
    printf 'pid=%s\n' "$pid"
    printf 'pidstart=%s\n' "$(ps -o lstart= -p "$pid" 2>/dev/null)"
    printf 'note=%s\n' "$note"
    printf 'taken=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } >"$lock/owner"
  printf 'CLAIMED:\t%s\tpid:%s\n' "$rundir" "$pid"
  exit 0
}

cmd_release() {
  local rundir="${1:-}"
  [[ -n "$rundir" ]] || triage_fail BAD_ARGS "usage: triage.sh release <run-dir>"
  rm -rf "$rundir/.lock" "$rundir"/.lock.stale.* 2>/dev/null
  printf 'RELEASED:\t%s\n' "$rundir"
  exit 0
}

# ---- report sections ---------------------------------------------------

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

# The body of a report's "## <title>" section on stdout; exit 1 when the
# section is absent. Read-only and grep-shaped, like everything else here.
report_section() { # <report.md> <section-title>
  awk -v title="$2" '
    $0 ~ ("^##[[:space:]]+" title "[[:space:]]*$") { found = 1; insec = 1; next }
    insec && /^##[[:space:]]/ { insec = 0 }
    insec { print }
    END { exit found ? 0 : 1 }
  ' "$1" 2>/dev/null
}

# some|none|unknown — whether the section lists anything beyond "None".
# Fail-open: a missing section is `unknown`, never a guess.
# The verdict is the FIRST SENTENCE of the first non-empty line, not the
# whole section mashed together. The report template writes the word as a
# bullet — `- <item, reason, decision. "None" if nothing is blocked.>` —
# and report authors routinely follow it with a reassuring clause ("None.
# Every work item merged."). Judging the whole body made that clause the
# thing that read as unfinished work: two of one real project's finished
# runs sat in status's "leftovers" group, pointing at /orca:retry, for
# nothing. Cutting at the first period reads them right while a section
# opening "None of the W3 work landed" still reads `some` — which a
# startswith-"none" test would have gotten wrong.
#
# The `listed` guard keeps the failure direction safe. A first sentence of
# "None" followed by actual list items is self-contradictory and the
# template does not produce it, but if it ever appears, `some` is the
# harmless read (the user is pestered) where `none` is the harmful one
# (real unfinished work retired or routed away).
section_state() { # <report.md> <section-title>
  awk -v title="$2" '
    $0 ~ ("^##[[:space:]]+" title "[[:space:]]*$") { found = 1; insec = 1; next }
    insec && /^##[[:space:]]/ { insec = 0 }
    insec {
      if ($0 ~ /^[[:space:]]*$/) next
      if (first == "") { first = $0; next }
      if ($0 ~ /^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]/) listed = 1
    }
    END {
      if (!found) { print "unknown"; exit }
      # An empty section lists nothing.
      if (first == "") { print "none"; exit }
      sub(/^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]+/, "", first)  # list marker
      sub(/^[[:space:]]*\**[[:space:]]*/, "", first)               # bold opener
      sub(/\..*$/, "", first)                                      # first sentence
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", first)
      if (tolower(first) == "none" && !listed) print "none"
      else print "some"
    }' "$1" 2>/dev/null || echo "unknown"
}

# clean|leftovers|unknown for a finished run, from its report.md's
# "## Blocked" section — every unmet item lands there (the pump's cascade
# and budget stops all route through block()).
done_state() { # <report.md>
  case "$(section_state "$1" Blocked)" in
    some) echo leftovers ;;
    none) echo clean ;;
    *) echo unknown ;;
  esac
}

# The DONE: adjacency block: lease verdict, plus — under --reports only —
# the report's Blocked and Follow-ups bodies, base64 so a reason is never
# paraphrased in transit. The bodies are the snapshot's whole size
# problem: they scale with how many runs a repository has ever finished,
# while every caller but orca:status routes on the DONE: tag alone.
emit_done_extras() { # <run-dir>
  emit_lease "$1"
  [[ "$want_reports" == 1 ]] || return 0
  local body
  if body="$(report_section "$1/report.md" Blocked)"; then
    printf 'BLOCKED:\t%s\t%s\n' "$1" "$(b64_encode_str "$body")"
  fi
  if body="$(report_section "$1/report.md" Follow-ups)"; then
    printf 'FOLLOWUP:\t%s\t%s\n' "$1" "$(b64_encode_str "$body")"
  fi
}

# An archived run is a finished run the user retired: landed, clean, and
# harvested. The marker counts only beside a report.md — a stray file can
# never hide a resumable run from its resume offer.
is_archived() { # <run-dir>
  [[ -f "$1/archived" && -f "$1/report.md" ]]
}

collect_discover() {
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
      # An archived run reduces to one bare line: retired by the user,
      # nothing routes off it. orca:followup reads ARCHIVED: as a pick
      # candidate — deferred follow-ups outlive the retirement.
      if is_archived "$dir"; then
        printf 'ARCHIVED:\t%s\n' "$dir"
        continue
      fi
      printf 'DONE:\t%s\t%s\n' "$dir" "$(done_state "$dir/report.md")"
      emit_done_extras "$dir"
      continue
    fi
    run_ln="$(last_run_line "$spec")"
    if [[ -z "$run_ln" ]]; then
      printf 'RUN:\t%s\tunlaunched\n' "$dir"
      emit_lease "$dir"
      continue
    fi
    runid="$(record_value "$spec" "Workflow run" "$run_ln")"
    printf 'RUN:\t%s\tinterrupted\n' "$dir"
    printf 'RUNID:\t%s\n' "${runid:-absent}"
    args="$(record_value "$spec" "Workflow args" "$run_ln")"
    printf 'ARGS:\t%s\n' "${args:-absent}"
    value="$(record_value "$spec" "Workflow reviewer" "$run_ln")"
    printf 'REVIEWER:\t%s\n' "${value:-absent}"
    value="$(record_value "$spec" "Workflow agents" "$run_ln")"
    printf 'AGENTS:\t%s\n' "${value:-absent}"
    emit_lease "$dir"
  done

  # --- runs that died between brief consumption and the spec write ---
  # brief.md present, spec.md not yet: without this, the consumed brief is
  # invisible to every discovery surface. feat-briefs/ is
  # excluded — a queued brief named brief.md is not a run directory.
  local briefmd bdir
  for briefmd in "$orca"/*/brief.md; do
    [[ -f "$briefmd" ]] || continue
    bdir="$(dirname "$briefmd")"
    case "$(basename "$bdir")" in feat-briefs) continue ;; esac
    [[ -f "$bdir/spec.md" ]] && continue
    printf 'RUN:\t%s\tunlaunched\n' "$bdir"
    emit_lease "$bdir"
  done

  # --- queued briefs: top level only ---
  local brief
  for brief in "$orca"/feat-briefs/*.md; do
    [[ -f "$brief" ]] || continue
    printf 'BRIEF:\t%s\n' "$brief"
  done

}

cmd_discover() {
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --reports)
        want_reports=1
        shift
        ;;
      *) triage_fail BAD_ARGS "unknown flag '$1' — usage: triage.sh discover [--reports]" ;;
    esac
  done
  triage_resolve_repo
  collect_discover
  exit 0
}

# git against the resolved repo regardless of CWD — status may be invoked
# from any worktree or from the repo root, which in the bare layout is not
# a working directory at all.
g() { git --git-dir="$common_dir" "$@"; }

# Newest .orca run dir whose basename ends in -feat-<slug>; `orphan` when
# none survives. Timestamped names make directory order chronological, so
# the last glob match is the newest (a rerun after a full cleanup joins its
# own dir, older same-slug dirs render on their .orca facts alone). The
# fallback without the verb marker covers pre-plugin run dirs, and skips
# anything carrying the marker so a bare suffix never cross-joins another
# slug's run.
run_join() { # <slug>
  local d name prefix match=""
  # Anchored: the glob alone would let slug "alpha" claim slug "x-alpha"'s
  # run dir (*-feat-alpha matches ...-feat-x-alpha). The prefix before
  # -feat-<slug> must be the timestamp — digits and dashes only —
  # checked literally, never through a regex the slug could corrupt.
  for d in "$repo_root/.orca/"*"-feat-$1"; do
    [[ -d "$d" ]] || continue
    name="${d##*/}"
    prefix="${name%-feat-"$1"}"
    [[ "$prefix" != "$name" && "$prefix" =~ ^[0-9]+(-[0-9]+)*$ ]] && match="$d"
  done
  if [[ -z "$match" ]]; then
    for d in "$repo_root/.orca/"*"-$1"; do
      name="${d##*/}"
      prefix="${name%-"$1"}"
      [[ -d "$d" && "$prefix" != "$name" && "$prefix" =~ ^[0-9]+(-[0-9]+)*$ \
        && "$name" != *"-feat-"* ]] && match="$d"
    done
  fi
  printf '%s' "${match:-orphan}"
}

# merged|unmerged|unknown — an empty target means there is nothing to test
# against (detached/unset trunk, or an item branch whose targets are gone).
# merge-base failing (exit > 1: unrelated histories, a missing object) is
# unknown too, never presented as an unmerged verdict.
merged_state() { # <branch> <target>
  [[ -n "$2" ]] || {
    echo unknown
    return
  }
  g merge-base --is-ancestor "$1" "$2" 2>/dev/null
  case "$?" in
    0) echo merged ;;
    1) echo unmerged ;;
    *) echo unknown ;;
  esac
}

collect_status() {
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
        "$ref" "$(merged_state "$ref" "$target")" "$(run_join "$slug")"
    else
      slug="${ref#feature/}"
      state="$(merged_state "$ref" "$trunk")"
      if [[ "$state" == unknown ]]; then
        ahead="unknown"
      else
        ahead="$(g rev-list --count "$trunk..$ref" 2>/dev/null || echo unknown)"
      fi
      printf 'BRANCH:\t%s\t%s\tahead:%s\t%s\n' \
        "$ref" "$state" "$ahead" "$(run_join "$slug")"
    fi
  done < <(g for-each-ref --format='%(refname:short)' refs/heads/feature/)

  # --- orca-* worktrees, joined by the slug their directory name carries ---
  local line wt_path="" wt_branch="detached" name
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt_path="${line#worktree }"
        wt_branch="detached"
        ;;
      "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
      "")
        name="$(basename "${wt_path:-/}")"
        if [[ -n "$wt_path" && "$name" == orca-* ]]; then
          if [[ "$name" =~ ^orca-(.+)-W[0-9]+$ ]]; then
            slug="${BASH_REMATCH[1]}"
          else
            slug="${name#orca-}"
          fi
          printf 'WORKTREE:\t%s\t%s\t%s\n' \
            "$wt_path" "$wt_branch" "$(run_join "$slug")"
        fi
        wt_path=""
        ;;
    esac
  done < <(
    g worktree list --porcelain
    printf '\n'
  )
}

cmd_status() {
  triage_resolve_repo
  collect_status
  exit 0
}

# ---- archive: retire a finished run and its git footprint --------------
#
# The size problem the marker solves is structural: finished runs are
# never removed, so every entry-point skill's triage pays for the whole
# history of the repository forever. Retirement is the user's decision,
# but the GATE is provable — a run is archivable only when it is
# finished, clean, unleased, its git footprint has landed, and nothing
# about that footprint is in use. The branch test reuses the status join
# verbatim (the same anchored run_join, the same merged_state against the
# same targets), so archive and status can never disagree about what
# "landed" means — and because that proof is exactly status's "safe to
# delete" proof, archiving also performs the deletions status would
# prescribe: the run's orca-* worktrees, then its feature/* branches.

# The worktree table, one record per `git worktree list` entry:
# <path>\t<branch|detached>\t<head-sha|->\t<locked 0|1>\t<main 0|1>.
# The first entry is always the main worktree (or the bare repository
# itself) — never a removal candidate, whatever its directory is called.
worktree_records() {
  local line path="" branch=detached head="-" locked=0 first=1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path="${line#worktree }"
        branch=detached
        head="-"
        locked=0
        ;;
      "HEAD "*) head="${line#HEAD }" ;;
      "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
      locked | "locked "*) locked=1 ;;
      "")
        if [[ -n "$path" ]]; then
          printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$branch" "$head" "$locked" "$first"
          first=0
        fi
        path=""
        ;;
    esac
  done < <(
    g worktree list --porcelain
    printf '\n'
  )
}

# What archiving <run-dir> removes, in removal order — worktrees first,
# since git refuses to delete a branch still checked out:
#   worktree\t<path>\t<branch|detached>\t<head-sha|->\t<locked 0|1>
#   branch\t<name>\t<sha>        item branches, then the integration branch
# Worktrees and branches are exactly the ones the status join attributes
# to the run; the main worktree never is.
archive_footprint() { # <run-dir> <status-output> <worktree-records>
  local dir="$1" stat="$2" wts="$3" p b rec sha
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    rec="$(printf '%s\n' "$wts" | awk -F'\t' -v p="$p" '$1 == p && $5 == 0 { print; exit }')"
    [[ -n "$rec" ]] && printf 'worktree\t%s\n' "$(printf '%s' "$rec" | cut -f1-4)"
  done < <(printf '%s\n' "$stat" | awk -F'\t' -v d="$dir" '$1 == "WORKTREE:" && $4 == d { print $2 }')
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    sha="$(g rev-parse --verify -q "refs/heads/$b^{commit}" 2>/dev/null)" || continue
    printf 'branch\t%s\t%s\n' "$b" "$sha"
  done < <(printf '%s\n' "$stat" | awk -F'\t' -v d="$dir" '
    ($1 == "ITEMBR:" && $4 == d) { print $2 }
    ($1 == "BRANCH:" && $5 == d) { last = last $2 "\n" }
    END { printf "%s", last }')
}

# "<verdict>\t<detail>" — PASS, or a typed reason with its evidence.
archive_gate() { # <run-dir> <status-output> <worktree-records> <footprint>
  local dir="$1" stat="$2" wts="$3" fp="$4" trunk unmerged
  [[ -f "$dir/report.md" ]] || {
    printf 'NO_REPORT\tno report.md — the run has not finished'
    return
  }
  case "$(done_state "$dir/report.md")" in
    clean) ;;
    leftovers)
      printf 'NOT_CLEAN\treport lists unmet items — /orca:retry finishes them'
      return
      ;;
    *)
      printf "NOT_CLEAN\treport's Blocked section is unreadable — nothing provable to archive on"
      return
      ;;
  esac
  if [[ "$(lease_read "$dir" | cut -f1)" == live ]]; then
    printf 'LEASE_LIVE\tan open session owns this run'
    return
  fi
  trunk="$(printf '%s' "$stat" | awk -F'\t' '$1 == "TRUNK:" { print $2; exit }')"
  if [[ -z "$trunk" ]]; then
    printf 'NO_TRUNK\tdetached or unset HEAD — merged-ness is unknowable, never guessed'
    return
  fi
  # Every branch the status join attributes to this run must be merged.
  # Absent branches emit no line and so pass: landed and pruned is the
  # end state this gate exists to recognize.
  unmerged="$(printf '%s' "$stat" | awk -F'\t' -v d="$dir" '
    ($1 == "BRANCH:" && $5 == d && $3 != "merged") { printf "%s(%s) ", $2, $3 }
    ($1 == "ITEMBR:" && $4 == d && $3 != "merged") { printf "%s(%s) ", $2, $3 }')"
  # A detached worktree's commits live on no branch — removing it would
  # orphan them unless its HEAD has landed too.
  local kind p wb head locked name here real state inuse="" nwt=0 nbr=0 doomed=""
  while IFS=$'\t' read -r kind p wb head locked; do
    [[ "$kind" == worktree ]] || continue
    nwt=$((nwt + 1))
    doomed="$doomed$p"$'\n'
    if [[ "$wb" == detached && "$head" != - && "$(merged_state "$head" "$trunk")" != merged ]]; then
      unmerged="$unmerged${p##*/}(detached, unmerged) "
    fi
  done <<EOF
$fp
EOF
  if [[ -n "$unmerged" ]]; then
    printf 'NOT_LANDED\tunlanded branches: %s' "${unmerged% }"
    return
  fi
  # In use: anything whose removal would destroy work or pull the floor
  # from under someone. Uncommitted or untracked files (the same test
  # `git worktree remove` applies without --force; ignored files such as
  # provisioned secrets and build output are regenerable and do not
  # count), a lock, this very shell standing inside the worktree, and a
  # run branch checked out anywhere that is not being removed with it.
  here="$(pwd -P)"
  while IFS=$'\t' read -r kind p wb head locked; do
    [[ "$kind" == worktree ]] || continue
    name="${p##*/}"
    if [[ "$locked" == 1 ]]; then
      inuse="$inuse$name(locked) "
      continue
    fi
    [[ -d "$p" ]] || continue # already gone on disk — only metadata left
    real="$(cd "$p" && pwd -P)" || real="$p"
    case "$here/" in
      "$real/"*)
        inuse="$inuse$name(current directory) "
        continue
        ;;
    esac
    if ! state="$(git -C "$p" status --porcelain 2>/dev/null)"; then
      inuse="$inuse$name(unreadable status) "
    elif [[ -n "$state" ]]; then
      inuse="$inuse$name(uncommitted changes) "
    fi
  done <<EOF
$fp
EOF
  local b sha holder
  while IFS=$'\t' read -r kind b sha; do
    [[ "$kind" == branch ]] || continue
    nbr=$((nbr + 1))
    if [[ "$b" == "$trunk" ]]; then
      inuse="$inuse$b(the trunk) "
      continue
    fi
    holder="$(printf '%s\n' "$wts" | awk -F'\t' -v b="$b" '$2 == b { print $1 }' | while IFS= read -r p; do
      printf '%s' "$doomed" | grep -qxF "$p" || {
        printf '%s' "$p"
        break
      }
    done)"
    [[ -n "$holder" ]] && inuse="$inuse$b(checked out at $holder) "
  done <<EOF
$fp
EOF
  if [[ -n "$inuse" ]]; then
    printf 'WORKTREE_IN_USE\t%s' "${inuse% }"
    return
  fi
  printf 'PASS\tclean, unleased, and every joined branch merged into %s' "$trunk"
  if [[ $((nwt + nbr)) -gt 0 ]]; then
    printf '; removes %s worktree(s) and %s branch(es)' "$nwt" "$nbr"
  else
    printf '; no git footprint left'
  fi
}

cmd_archive() {
  local scan=0 dir stat wts fp verdict detail
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --scan)
        scan=1
        shift
        ;;
      *) triage_fail BAD_ARGS "unknown flag '$1' — usage: triage.sh archive --scan | triage.sh archive <run-dir>" ;;
    esac
  done
  triage_resolve_repo
  stat="$(collect_status)"
  wts="$(worktree_records)"

  if [[ "$scan" -eq 1 ]]; then
    [[ -z "${1:-}" ]] || triage_fail BAD_ARGS "archive --scan takes no run directory"
    local spec kind a rest
    for spec in "$repo_root/.orca"/*/spec.md; do
      [[ -f "$spec" ]] || continue
      dir="$(dirname "$spec")"
      [[ -f "$dir/report.md" ]] || continue
      if is_archived "$dir"; then
        printf 'ARCHIVED:\t%s\n' "$dir"
        continue
      fi
      fp="$(archive_footprint "$dir" "$stat" "$wts")"
      IFS=$'\t' read -r verdict detail < <(archive_gate "$dir" "$stat" "$wts" "$fp")
      if [[ "$verdict" == PASS ]]; then
        printf 'ARCHIVABLE:\t%s\t%s\n' "$dir" "$detail"
        while IFS=$'\t' read -r kind a rest; do
          [[ -n "$kind" ]] && printf 'PRUNE:\t%s\t%s\t%s\n' "$dir" "$kind" "$a"
        done <<EOF
$fp
EOF
      else
        printf 'KEPT:\t%s\t%s\t%s\n' "$dir" "$verdict" "$detail"
      fi
    done
    exit 0
  fi

  dir="${1:-}"
  [[ -n "$dir" ]] || triage_fail BAD_ARGS "usage: triage.sh archive --scan | triage.sh archive <run-dir>"
  [[ -d "$dir" ]] || triage_fail NO_RUN_DIR "not a directory: $dir"
  if is_archived "$dir"; then
    # Idempotent: re-archiving an archived run is a no-op, not a failure.
    printf 'ARCHIVED:\t%s\n' "$dir"
    exit 0
  fi
  # The gate compares against the status join's PHYSICAL absolute paths,
  # so a relative or symlinked argument must be canonicalized first — a
  # bare `.orca/<run>` would otherwise match no branch line and archive a
  # run whose deliverable is still unlanded. The echoed path stays the
  # caller's own, like claim/release.
  local gate_dir
  gate_dir="$(cd "$dir" && pwd -P)" || triage_fail NO_RUN_DIR "cannot resolve: $dir"
  fp="$(archive_footprint "$gate_dir" "$stat" "$wts")"
  IFS=$'\t' read -r verdict detail < <(archive_gate "$gate_dir" "$stat" "$wts" "$fp")
  [[ "$verdict" == PASS ]] || triage_fail "$verdict" "refusing to archive $dir: $detail"

  # Remove in footprint order. No --force anywhere: the gate proved each
  # worktree clean and each branch merged, and git re-checks the former
  # itself — a refusal between the gate and here (a file written in the
  # meantime) stops the run unarchived, with everything removed so far
  # already printed. Re-running the archive finishes the job.
  local record="" kind a b out
  while IFS=$'\t' read -r kind a b _; do
    case "$kind" in
      worktree)
        out="$(g worktree remove "$a" 2>&1)" \
          || triage_fail PRUNE_FAILED "git worktree remove $a: $(printf '%s' "$out" | tr '\n' ' ')"
        printf 'PRUNED:\tworktree\t%s\n' "$a"
        record="${record}worktree=$a"$'\n'
        ;;
      branch)
        out="$(g branch -D "$a" 2>&1)" \
          || triage_fail PRUNE_FAILED "git branch -D $a: $(printf '%s' "$out" | tr '\n' ' ')"
        printf 'PRUNED:\tbranch\t%s\t%s\n' "$a" "$b"
        record="${record}branch=$a $b"$'\n'
        ;;
    esac
  done <<EOF
$fp
EOF
  # The marker: the timestamp, plus every removal with the branch tips —
  # all reachable from the trunk, so `unarchive` can recreate them exactly.
  printf 'archived=%s\n%s' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$record" >"$dir/archived"
  printf 'ARCHIVED:\t%s\n' "$dir"
  exit 0
}

# Ungated: removing the marker returns the run to the routing surface,
# and every branch it recorded is recreated at its recorded tip — unless
# a branch of that name exists again or the commit is gone, which is
# reported and left alone. Worktrees are not re-added: /orca:review and
# /orca:iterate re-add their own on demand.
cmd_unarchive() {
  local dir="${1:-}" line name sha
  [[ -n "$dir" ]] || triage_fail BAD_ARGS "usage: triage.sh unarchive <run-dir>"
  [[ -d "$dir" ]] || triage_fail NO_RUN_DIR "not a directory: $dir"
  if [[ -f "$dir/archived" ]] && grep -q '^branch=' "$dir/archived"; then
    triage_resolve_repo
    while IFS= read -r line; do
      case "$line" in branch=*) ;; *) continue ;; esac
      line="${line#branch=}"
      name="${line% *}"
      sha="${line##* }"
      if g show-ref --verify --quiet "refs/heads/$name"; then
        printf 'NOT_RESTORED:\tbranch\t%s\texists\n' "$name"
      elif ! g cat-file -e "$sha^{commit}" 2>/dev/null; then
        printf 'NOT_RESTORED:\tbranch\t%s\tcommit %s is gone\n' "$name" "$sha"
      elif g branch "$name" "$sha" >/dev/null 2>&1; then
        printf 'RESTORED:\tbranch\t%s\t%s\n' "$name" "$sha"
      else
        printf 'NOT_RESTORED:\tbranch\t%s\tgit branch failed\n' "$name"
      fi
    done <"$dir/archived"
  fi
  rm -f "$dir/archived" 2>/dev/null
  printf 'UNARCHIVED:\t%s\n' "$dir"
  exit 0
}

# ---- snapshot: the combined call, the fragment match, the action list ---

emit_run_match() { # <fragment> <discover-output>
  local frag="$1" disc="$2" tag dir rest matches="" candidates=""
  while IFS=$'\t' read -r tag dir rest; do
    # ARCHIVED: runs stay addressable by fragment — retirement removes a
    # run from the routing, not from the user's vocabulary.
    case "$tag" in RUN: | DONE: | ARCHIVED:) ;; *) continue ;; esac
    candidates="$candidates$dir"$'\n'
    case "$(basename "$dir")" in
      *"$frag"*) matches="$matches$dir"$'\n' ;;
    esac
  done <<EOF
$disc
EOF
  if [[ -n "$matches" ]]; then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] && printf 'MATCH:\t%s\n' "$dir"
    done <<EOF
$matches
EOF
  else
    printf 'MISS:\t%s\n' "$frag"
    while IFS= read -r dir; do
      [[ -n "$dir" ]] && printf 'CANDIDATE:\t%s\n' "$dir"
    done <<EOF
$candidates
EOF
  fi
}

# The matching BRANCH: record for a run dir: "ref\tstate\tahead" or nothing.
joined_branch() { # <run-dir> <branch-recs>
  printf '%s' "$2" | awk -F'\t' -v d="$1" '$4 == d { print $1 "\t" $2 "\t" $3; exit }'
}

# The routing conclusion, computed where both fact domains and the slug
# join already exist. Rank order is mechanical (interrupted → queued →
# recovery → housekeeping); DECIDING stays in the skills — these are
# ordered candidates the callers present, never force.
emit_actions() { # <discover-output> <status-output>
  local disc="$1" stat="$2"
  local t1="" t2="" t3="" t4="" # interrupted, queued, recovery, housekeeping
  local tag f2 f3 f4 f5
  local cur_kind="" cur_dir="" cur_state="" done_recs="" branch_recs="" wt_recs="" pruned=" "

  while IFS=$'\t' read -r tag f2 f3 f4 f5; do
    case "$tag" in
      RUN:)
        cur_kind=run
        cur_dir="$f2"
        cur_state="$f3"
        ;;
      DONE:)
        cur_kind="done"
        cur_dir="$f2"
        cur_state="$f3"
        ;;
      BRIEF:)
        cur_kind=""
        t2+="run-brief"$'\t'"feature"$'\t'"$f2"$'\t'"queued brief"$'\n'
        ;;
      LEASE:)
        case "$cur_kind" in
          run)
            if [[ "$cur_state" == interrupted ]]; then
              # live -> an open session owns the run: no resume candidate.
              [[ "$f2" != live ]] \
                && t1+="resume-run"$'\t'"feature"$'\t'"$cur_dir"$'\t'"interrupted run; lease $f2"$'\n'
            elif [[ -f "$cur_dir/brief.md" && ! -f "$cur_dir/spec.md" ]]; then
              t2+="run-brief"$'\t'"feature"$'\t'"$cur_dir"$'\t'"consumed brief, never launched — rerunnable in place"$'\n'
            else
              t3+="requeue-brief"$'\t'"-"$'\t'"$cur_dir"$'\t'"unlaunched, not resumable — re-queue $cur_dir/brief.md"$'\n'
            fi
            ;;
          done)
            done_recs+="$cur_dir"$'\t'"$cur_state"$'\t'"$f2"$'\n'
            ;;
        esac
        cur_kind=""
        ;;
    esac
  done <<EOF
$disc
EOF

  while IFS=$'\t' read -r tag f2 f3 f4 f5; do
    case "$tag" in
      BRANCH:)
        branch_recs+="$f2"$'\t'"$f3"$'\t'"$f4"$'\t'"$f5"$'\n'
        case "$f3" in
          merged)
            t4+="prune-branch"$'\t'"-"$'\t'"$f2"$'\t'"integration branch landed ($f4) — never pruned"$'\n'
            pruned="$pruned$f2 "
            ;;
          unmerged)
            [[ "$f5" == orphan ]] \
              && t4+="inspect-orphan"$'\t'"-"$'\t'"$f2"$'\t'"orphan branch carrying commits ($f4)"$'\n'
            ;;
          *)
            t4+="inspect-orphan"$'\t'"-"$'\t'"$f2"$'\t'"merged-ness unknown — no trunk to test against"$'\n'
            ;;
        esac
        ;;
      ITEMBR:)
        case "$f3" in
          merged)
            t4+="prune-branch"$'\t'"-"$'\t'"$f2"$'\t'"item branch merged — lossless prune"$'\n'
            pruned="$pruned$f2 "
            ;;
          unmerged)
            # Joined + unmerged corroborates a kept blocked item — retry's
            # territory, never housekeeping.
            [[ "$f4" == orphan ]] \
              && t4+="inspect-orphan"$'\t'"-"$'\t'"$f2"$'\t'"orphan item branch with unmerged commits"$'\n'
            ;;
          *)
            t4+="inspect-orphan"$'\t'"-"$'\t'"$f2"$'\t'"merged-ness unknown — no target to test against"$'\n'
            ;;
        esac
        ;;
      WORKTREE:)
        wt_recs+="$f2"$'\t'"$f3"$'\t'"$f4"$'\n'
        ;;
    esac
  done <<EOF
$stat
EOF

  local ddir dstate rec
  while IFS=$'\t' read -r ddir dstate _; do
    [[ -n "$ddir" ]] || continue
    case "$dstate" in
      leftovers)
        t3+="finish-unmet"$'\t'"retry"$'\t'"$ddir"$'\t'"report lists unmet items"$'\n'
        ;;
      unknown)
        t3+="finish-unmet"$'\t'"retry"$'\t'"$ddir"$'\t'"report's Blocked section unreadable — the audit decides"$'\n'
        ;;
      clean)
        rec="$(joined_branch "$ddir" "$branch_recs")"
        if [[ -n "$rec" && "$(printf '%s' "$rec" | cut -f2)" == unmerged ]]; then
          t3+="review-deliverable"$'\t'"review"$'\t'"$(printf '%s' "$rec" | cut -f1)"$'\t'"delivered, not landed — $(printf '%s' "$rec" | cut -f3)"$'\n'
        elif [[ "$(section_state "$ddir/report.md" Follow-ups)" == some ]]; then
          t3+="followup"$'\t'"followup"$'\t'"$ddir"$'\t'"landed; follow-ups recorded"$'\n'
        fi
        ;;
    esac
  done <<EOF
$done_recs
EOF

  local wpath wbranch wjoin
  while IFS=$'\t' read -r wpath wbranch wjoin; do
    [[ -n "$wpath" ]] || continue
    if in_list "$wbranch" "$pruned"; then
      t4+="prune-worktree"$'\t'"-"$'\t'"$wpath"$'\t'"worktree on pruned branch $wbranch"$'\n'
    elif [[ "$wjoin" == orphan ]]; then
      t4+="inspect-orphan"$'\t'"-"$'\t'"$wpath"$'\t'"orphan worktree (branch $wbranch)"$'\n'
    fi
  done <<EOF
$wt_recs
EOF

  local rank=0 aslug aowner atarget aevi
  while IFS=$'\t' read -r aslug aowner atarget aevi; do
    [[ -n "$aslug" ]] || continue
    rank=$((rank + 1))
    printf 'ACTION:\t%s\t%s\t%s\t%s\t%s\n' \
      "$rank" "$aslug" "$aowner" "$atarget" "$(b64_encode_str "$aevi")"
  done <<EOF
${t1}${t2}${t3}${t4}
EOF
}

cmd_snapshot() {
  local frag=""
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --run)
        frag="${2:-}"
        shift 2
        ;;
      --reports)
        want_reports=1
        shift
        ;;
      *) triage_fail BAD_ARGS "unknown flag '$1' — usage: triage.sh snapshot [--reports] [--run <fragment>]" ;;
    esac
  done
  triage_resolve_repo
  local disc stat
  disc="$(collect_discover)"
  stat="$(collect_status)"
  [[ -n "$disc" ]] && printf '%s\n' "$disc"
  [[ -n "$stat" ]] && printf '%s\n' "$stat"
  [[ -n "$frag" ]] && emit_run_match "$frag" "$disc"
  emit_actions "$disc" "$stat"
  exit 0
}

sub="${1:-}"
[[ $# -gt 0 ]] && shift
case "$sub" in
  discover) cmd_discover "$@" ;;
  status) cmd_status ;;
  snapshot) cmd_snapshot "$@" ;;
  archive) cmd_archive "$@" ;;
  unarchive) cmd_unarchive "$@" ;;
  claim) cmd_claim "$@" ;;
  release) cmd_release "$@" ;;
  *) triage_fail BAD_ARGS "usage: triage.sh discover [--reports] | status | snapshot [--reports] [--run <fragment>] | archive --scan | archive <run-dir> | unarchive <run-dir> | claim [--steal] [--runid <id>] <run-dir> <note> | release <run-dir>" ;;
esac
