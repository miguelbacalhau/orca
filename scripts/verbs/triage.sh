# shellcheck shell=bash
#
# orca triage — the discovery spine of orca:feature's and orca:debug's
# Step 0, orca:status's dashboard, and the home of the per-run lease.
# The read-only boundary runs PER SUBCOMMAND: `discover`, `status`, and
# `snapshot` never write anything; `claim` and `release` are the lease's
# writer pair — the ONLY writers of <run-dir>/.lock anywhere in orca
# (both workflow scripts call them through orca.sh). No bare-layout
# requirement: triage runs before the preflight.
#
# Usage:
#   orca.sh triage discover
#   orca.sh triage status
#   orca.sh triage snapshot [--run <fragment>]
#   orca.sh triage claim [--steal] [--runid <id>] <run-dir> <note>
#   orca.sh triage release <run-dir>
#
# discover output contract — one machine-readable line per fact,
# TAB-separated:
#
#   RUN:<TAB><run-dir><TAB>interrupted|unlaunched
#       Feature runs: .orca/*/spec.md at depth 1 (feat-briefs/ has none;
#       debug runs keep theirs nested at fix/spec.md) with no sibling
#       report.md. interrupted -> the workflow launched; followed by:
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
#       Follows every RUN:, DONE:, and CASE: line — the lease reader's
#       verdict on that run directory's .lock (for a CASE, the last
#       launch's run dir; `none` when the case never launched, `unknown`
#       when the recorded args name no run dir to inspect):
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
#       DONE: runs only — the report's "## Blocked" / "## Follow-ups"
#       section bodies, base64 (one line each; decode before rendering).
#       Emitted only when the section exists, so consumers never see a
#       guessed empty body.
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
#       feature run dir (*-feat-<slug>), orca-bug-<slug>[-H<N>] and
#       orca-fix-<slug> join their debug run dir (*-bug-<slug>).
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
#       run-brief, finish-unmet, review-deliverable, followup, debug-case,
#       prune-branch, prune-worktree, inspect-orphan. The owner tag is the
#       skill that acts on the line (feature, debug, retry, followup,
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

lease_owner_field() { # <owner-file> <key> — the value, verbatim (leading padding kept)
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# The LEASE: payload for a run dir: "<verdict>\tpid:<n|->\tsince:<iso|->".
lease_read() { # <run-dir>
  local lock="$1/.lock" owner host pid pidstart taken cur
  if [[ ! -e "$lock" ]]; then
    printf 'none'
    return
  fi
  owner="$lock/owner"
  host="$(lease_owner_field "$owner" host)"
  pid="$(lease_owner_field "$owner" pid)"
  pidstart="$(lease_owner_field "$owner" pidstart)"
  taken="$(lease_owner_field "$owner" taken)"
  if [[ -z "$host" || -z "$pid" ]] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    # A pre-verb prose owner file or a hand-mangled one — nothing testable.
    printf 'unknown\tpid:%s\tsince:%s' "${pid:--}" "${taken:--}"
    return
  fi
  if [[ "$host" != "$(hostname)" ]]; then
    printf 'unknown\tpid:%s\tsince:%s' "$pid" "${taken:--}"
    return
  fi
  # kill -0 on another user's pid fails EPERM and reads stale — accepted:
  # irrelevant on a single-user dev machine.
  if kill -0 "$pid" 2>/dev/null; then
    # pidstart is compared VERBATIM, leading padding included — reader and
    # writer run the identical `ps -o lstart=` and never parse the date.
    # The match defeats pid reuse inside the bash 3.2 + coreutils envelope.
    cur="$(ps -o lstart= -p "$pid" 2>/dev/null)"
    if [[ -n "$pidstart" && "$cur" == "$pidstart" ]]; then
      printf 'live\tpid:%s\tsince:%s' "$pid" "${taken:--}"
      return
    fi
  fi
  printf 'stale\tpid:%s\tsince:%s' "$pid" "${taken:--}"
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
section_state() { # <report.md> <section-title>
  awk -v title="$2" '
    $0 ~ ("^##[[:space:]]+" title "[[:space:]]*$") { found = 1; insec = 1; next }
    insec && /^##[[:space:]]/ { insec = 0 }
    insec { body = body $0 }
    END {
      if (!found) { print "unknown"; exit }
      # Strip list markers, punctuation, and whitespace; an empty section or
      # a lone "None" (however bulleted) means nothing is listed.
      gsub(/[-*.[:space:]]/, "", body)
      if (body == "" || tolower(body) == "none") print "none"
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

# The DONE: adjacency block: lease verdict plus the report's Blocked and
# Follow-ups bodies, base64 so a reason is never paraphrased in transit.
emit_done_extras() { # <run-dir>
  emit_lease "$1"
  local body
  if body="$(report_section "$1/report.md" Blocked)"; then
    printf 'BLOCKED:\t%s\t%s\n' "$1" "$(b64_encode_str "$body")"
  fi
  if body="$(report_section "$1/report.md" Follow-ups)"; then
    printf 'FOLLOWUP:\t%s\t%s\n' "$1" "$(b64_encode_str "$body")"
  fi
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
  # invisible to every discovery surface. feat-briefs/ and bug-cases/ are
  # excluded — a queued brief named brief.md is not a run directory.
  local briefmd bdir
  for briefmd in "$orca"/*/brief.md; do
    [[ -f "$briefmd" ]] || continue
    bdir="$(dirname "$briefmd")"
    case "$(basename "$bdir")" in feat-briefs | bug-cases) continue ;; esac
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

  # --- open cases: interrupted iff the last launch's run dir lacks report.md ---
  local casemd casedir rundir
  for casemd in "$orca"/bug-cases/*/case.md; do
    [[ -f "$casemd" ]] || continue
    casedir="$(dirname "$casemd")"
    run_ln="$(last_run_line "$casemd")"
    if [[ -z "$run_ln" ]]; then
      printf 'CASE:\t%s\tready\n' "$(basename "$casedir")"
      printf 'LEASE:\tnone\n'
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
      emit_lease "$rundir"
      continue
    fi
    printf 'CASE:\t%s\tinterrupted\n' "$(basename "$casedir")"
    printf 'RUNID:\t%s\n' "${runid:-absent}"
    printf 'ARGS:\t%s\n' "${args:-absent}"
    if [[ -n "$rundir" ]]; then
      emit_lease "$rundir"
    else
      # No run dir to inspect — the caveat survives, honestly.
      printf 'LEASE:\tunknown\tpid:-\tsince:-\n'
    fi
  done
}

cmd_discover() {
  triage_resolve_repo
  collect_discover
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
  local d name prefix match=""
  # Anchored: the glob alone would let slug "alpha" claim slug "x-alpha"'s
  # run dir (*-feat-alpha matches ...-feat-x-alpha). The prefix before
  # -<verb>-<slug> must be the timestamp — digits and dashes only —
  # checked literally, never through a regex the slug could corrupt.
  for d in "$repo_root/.orca/"*"-$2-$1"; do
    [[ -d "$d" ]] || continue
    name="${d##*/}"
    prefix="${name%-"$2"-"$1"}"
    [[ "$prefix" != "$name" && "$prefix" =~ ^[0-9]+(-[0-9]+)*$ ]] && match="$d"
  done
  if [[ -z "$match" && "$2" == feat ]]; then
    for d in "$repo_root/.orca/"*"-$1"; do
      name="${d##*/}"
      prefix="${name%-"$1"}"
      [[ -d "$d" && "$prefix" != "$name" && "$prefix" =~ ^[0-9]+(-[0-9]+)*$ \
        && "$name" != *"-feat-"* && "$name" != *"-bug-"* ]] && match="$d"
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
      "worktree "*)
        wt_path="${line#worktree }"
        wt_branch="detached"
        ;;
      "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
      "")
        name="$(basename "${wt_path:-/}")"
        if [[ -n "$wt_path" && "$name" == orca-* ]]; then
          if [[ "$name" =~ ^orca-bug-(.+)-H[0-9]+$ ]]; then
            slug="${BASH_REMATCH[1]}"
            verb=bug
          elif [[ "$name" =~ ^orca-bug-(.+)$ ]]; then
            slug="${BASH_REMATCH[1]}"
            verb=bug
          elif [[ "$name" =~ ^orca-fix-(.+)$ ]]; then
            slug="${BASH_REMATCH[1]}"
            verb=bug
          elif [[ "$name" =~ ^orca-(.+)-W[0-9]+$ ]]; then
            slug="${BASH_REMATCH[1]}"
            verb=feat
          else
            slug="${name#orca-}"
            verb=feat
          fi
          printf 'WORKTREE:\t%s\t%s\t%s\n' \
            "$wt_path" "$wt_branch" "$(run_join "$slug" "$verb")"
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

# ---- snapshot: the combined call, the fragment match, the action list ---

emit_run_match() { # <fragment> <discover-output>
  local frag="$1" disc="$2" tag dir rest matches="" candidates=""
  while IFS=$'\t' read -r tag dir rest; do
    case "$tag" in RUN: | DONE:) ;; *) continue ;; esac
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
      CASE:)
        cur_kind=case
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
          case)
            if [[ "$cur_state" == interrupted ]]; then
              [[ "$f2" != live ]] \
                && t1+="debug-case"$'\t'"debug"$'\t'"$cur_dir"$'\t'"interrupted debug run; lease $f2"$'\n'
            else
              t2+="debug-case"$'\t'"debug"$'\t'"$cur_dir"$'\t'"open case, ready to run"$'\n'
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
      *) triage_fail BAD_ARGS "unknown flag '$1' — usage: triage.sh snapshot [--run <fragment>]" ;;
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
  discover) cmd_discover ;;
  status) cmd_status ;;
  snapshot) cmd_snapshot "$@" ;;
  claim) cmd_claim "$@" ;;
  release) cmd_release "$@" ;;
  *) triage_fail BAD_ARGS "usage: triage.sh discover | status | snapshot [--run <fragment>] | claim [--steal] [--runid <id>] <run-dir> <note> | release <run-dir>" ;;
esac
