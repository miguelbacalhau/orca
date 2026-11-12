# shellcheck shell=bash disable=SC2154
#
# orca objective — an objective's state files, its owner claim, the
# listing with derived states, and the bounded digest. An objective is a
# directory of line-oriented files; everything a caller needs to know
# about one is read from them here, so no skill parses them itself.
#
# Usage:
#   orca.sh objective new <repo> <slug> <base-ref> [--idea <file>|-]
#   orca.sh objective open <dir> [--steal]
#   orca.sh objective current <repo>
#   orca.sh objective idle <dir>
#   orca.sh objective list <repo> [--all]
#   orca.sh objective digest <dir>
#   orca.sh objective plan-accept <dir> [--check]
#   orca.sh objective phase-add <dir> <block-file>
#   orca.sh objective phase-start <dir> <P>
#   orca.sh objective phase-done <dir> <P> <sha>
#   orca.sh objective phase-block <dir> <P> <D>
#   orca.sh objective verify-done <dir> pass|fail [<why>]
#   orca.sh objective archive <dir> [--abandon] [--note <text>]
#   orca.sh objective unarchive <dir>
#
# <repo> is any path inside the repository; <dir> is an objective
# directory, <repo-root>/.orca/objectives/<YYYYMMDD-HHMMSS>-<slug>,
# holding objective.md (anything else is BAD_DIR).
#
# ---- the files ------------------------------------------------------------
#
#   objective.md   `# <title>`, then the header lines `**Base:**`,
#                  `**Base commit:**`, `**Branch:**`, `**Worktree:**`
#                  (values in backticks), then `## Idea`, `## Outcome`,
#                  `## Non-goals`, `## Constraints`. The outcome's first
#                  line is the one the digest shows.
#   decisions.md   entries `## D<n> — <question>` with a `**State:**`
#                  line (open | decided | deferred) and `**Source:**`,
#                  `**Options:**`, `**Decision:**`, `**Why:**`
#   phases.md      entries `## P<n> — <title>` with a `**State:**` line
#                  (pending | active | done | blocked) and `**Source:**`,
#                  `**Decisions:**`, `**Goal:**`, `**Acceptance:**`,
#                  `**Commit:**`, `**Blocked on:**`
#   report.md      `# Report: <title>`, `**Deliverable:**`, `**Deliverable
#                  state:**`, `**Final verification:**` (once verify-done
#                  ran), then `## Phases` (one `### ` entry per done
#                  phase), `## Blocked`, `## Follow-ups` (`- F<n> · ...`
#                  lines), `## Landing` — written by phase-done,
#                  phase-block, and verify-done only
#   followups      the follow-up ledger behind report.md's ids, one line
#                  per id ever given: F<n><TAB>P<n><TAB><kind><TAB>
#                  <title><TAB><file><TAB><detail>
#   plan/proposed.md   a planner proposal not yet accepted
#   phases/P<n>/   brief.md, base, worktree, and the round engine's files
#                  (reviews/, responses/, declines.md, overrides, action,
#                  trees, snapshot)
#   phases/P<n>/action the round engine's last frame for that phase
#   owner          the claim: session=, host=, pid=, pidstart=, taken=
#   archived       present once archived: state=landed|abandoned (plus
#                  date=, tip=, note=)
#
# Only headings and `**Key:**` lines are read, never prose. Only an
# entry's first line of each key counts; the value is its first word
# (Source: the whole line). A decision whose state is neither decided
# nor deferred counts as open; a phase whose state is not active, done,
# or blocked counts as pending. A follow-up is taken — no longer open —
# once a decision's `**Source:**` cites its F<n>.
#
# ---- subcommands ----------------------------------------------------------
#
# new — the files and the branch, no worktree: refuses outside the bare layout
#   (NOT_BARE) and on an existing feature/<slug> (BRANCH_EXISTS), an
#   existing objective with the slug (OBJECTIVE_EXISTS), or an existing
#   <repo-root>/orca-<slug> (WORKTREE_EXISTS); the slug is lowercase
#   kebab-case (BAD_SLUG) and the base must name a commit (BAD_REF),
#   recorded as both the ref and its commit. --idea names a file (`-`:
#   stdin) whose text, trailing newlines dropped, is written verbatim
#   under objective.md's `## Idea`; an unreadable one is BAD_ARGS,
#   before anything is written. Writes objective.md,
#   decisions.md (`# Decisions`), and phases.md (`# Phases`), then
#   creates feature/<slug> at the base commit — the one collision point:
#   a branch that appeared since the checks is BRANCH_EXISTS, and the
#   fresh directory is removed. Frame: rc, dir, worktree, branch, base
#   (the base commit).
#
# open — claims the objective for this session, then arrives in its
#   worktree through `worktree-item --no-provision` (created off the base
#   commit the first time, then reused or branch_resumed). Nothing is
#   provisioned here: secrets and `.orca/setup` are the caller's
#   `orca.sh provision <worktree> <arrival>` afterwards (orca:provision),
#   so the verb stays fast and quiet. The claim, by the owner's verdict
#   (lib.sh lease_verdict over the owner file):
#     no owner                      claimed
#     this session, live            kept (nothing written)
#     this session, not live        claimed (the pid is refreshed)
#     another session, live|unknown OWNED_ELSEWHERE, nothing done
#     another session, stale        OWNER_STALE without --steal;
#                                   stolen with it
#   No CLAUDE_CODE_SESSION_ID is NO_SESSION_ID and an archived objective
#   ARCHIVED (restore it first), both before anything is written. The
#   archived check and the claim's read and write run under the claim
#   lock (refs/orca/claim/<dir name>, below), so of two sessions opening at once
#   exactly one claims and the other reads its claim, and an open that
#   waited behind an archive is ARCHIVED; a lock held past the wait is
#   CLAIM_BUSY. A
#   claim releases every other objective this session owned, so a
#   session owns one objective at a time. Output: the objective's
#   OBJECTIVE: line (as `list`), then one frame:
#     rc, dir, claim (claimed | kept | stolen), worktree, branch,
#     base (the base commit), arrival (created | reused |
#     branch_resumed — provision's <arrival>), head
#   A branch of the objective's name that does not descend from its base
#   commit is BRANCH_FOREIGN, and a saved worktree path that exists but
#   is not a worktree root of this
#   repository on the objective's branch (another branch, a detached
#   HEAD, another repository, a plain directory) is WORKTREE_MISMATCH,
#   checked before arrival, as in phase-start. worktree-item's typed
#   failure (WORKTREE_FAILED, ...) passes through; the claim stays, and a
#   re-run continues where it stopped.
#
# current — read-only. Frame: rc, dir (the objective whose owner names
#   this session's CLAUDE_CODE_SESSION_ID, archived ones skipped; the
#   most recently claimed should several) or `none`. NO_SESSION_ID
#   without a session id.
#
# idle — read-only: the gate for work on the objective's branch outside
#   the phase loop (/orca:review's address flow). This session owns the
#   objective (NOT_OWNER otherwise — no owner, a stale one, or another
#   session's, the detail naming the verdict), no phase is active
#   (PHASE_ACTIVE), and no phase keeps a base a commit made now would
#   fall inside: none blocked (PHASE_BLOCKED), none restarted and
#   pending (RESTART_PENDING); NO_SESSION_ID and ARCHIVED as open.
#   Frame: rc, dir, state.
#
# list — read-only. One line per objective directory, oldest first,
#   archived ones only with --all:
#     OBJECTIVE:<TAB><dir><TAB><slug><TAB><state><TAB>open:<n><TAB>pending:<n><TAB>blocked:<n><TAB>followups:<n><TAB>owner:<verdict>
#   open = open decisions, pending/blocked = phases, followups = open
#   follow-ups, owner none | mine | live | stale | unknown. The state is
#   derived, never stored — the first rule that holds:
#     archived    the archived file, state=landed (or no state)
#     abandoned   the archived file, state=abandoned
#     active      a phase is active
#     planning    plan/proposed.md exists and no decision is open
#     blocked     a phase is blocked
#     discussing  a decision is open, or there are no phases
#     ready       a phase is pending
#     landed      every phase done, and the branch has moved past the
#                 base commit and is merged into the trunk (the branch
#                 the repository's HEAD names)
#     verify      every phase done, and no final verification on record
#                 covers the last one (verify-done)
#     idle        every phase done and verified
#
# digest — read-only, at most 40 lines whatever the objective's size,
#   plain text: title and outcome line, state, worktree (clean | dirty |
#   absent | unknown, untracked files counted) and branch, decision counts with the open ones listed by id
#   and question (at most 8, the rest counted), phases done of total
#   with one line per phase (id, state, commit or blocked-on, title —
#   the active phase always, every other phase not done next, then the
#   latest done ones, at most 13 in file order, the rest counted by
#   state), the active phase's last action, the final verification on
#   record (or none), open follow-ups by count, and the last report
#   entry's heading. Titles are
#   truncated to 60 bytes; nothing is quoted from a body.
#
# ---- phase subcommands ----------------------------------------------------
#
# A phase block is a phases.md entry: its `## P<n> — <title>` heading
# through its last non-blank line before the next `## ` heading. Every
# subcommand below refuses an archived objective (ARCHIVED) and changes
# nothing on any failure.
#
# plan-accept — validates plan/proposed.md (a whole phases.md: an
#   optional preamble, then phase blocks) and, without --check, installs
#   it as phases.md and removes the proposal. The rules:
#     a missing proposal                               NO_PLAN
#     a decision is open                               DECISION_OPEN
#     a phase is active                                PHASE_ACTIVE
#     a `## ` heading that is not `## P<n> — <title>`,
#       a repeated id, or a new id (one phases.md does
#       not hold) that does not continue the sequence
#       — the highest existing id + 1, then + 1, in
#       file order                                     PLAN_BAD_ID
#     a done block, or a blocked one whose `**Blocked
#       on:**` decision is not decided, dropped or not
#       byte for byte the same (trailing blank lines
#       aside)                                         PLAN_REWRITES_DONE
#     any other phase not pending, with a `**Blocked
#       on:**` line, without a Goal, or without an
#       acceptance line (`- ` under `**Acceptance:**`) PLAN_BAD_PHASE
#     a referenced decision missing or not decided     PLAN_UNDECIDED
#     a pending phase with a recorded phases/P<n>/base
#       (a restarted one) after a pending phase without
#       one — the restarted phase must run first        PLAN_BAD_ORDER
#     a pending or unblocked phase dropped after it was
#       attempted (phases/P<n>/ holds a base or round
#       state) while its work may remain — the worktree
#       dirty, or the branch moved past that base       PLAN_DROPS_WORK
#   The next id is one past the highest of phases.md's and the
#   phases/P<n>/ directories', so an id that ever held state is never
#   given again.
#   Pending phases, and blocked ones whose decision is now decided, may
#   be rewritten (same id, pending, no Blocked on line), reordered, or
#   dropped. On install, every unblocked phase the proposal keeps starts
#   over: its earlier attempt's round state (reviews/, responses/,
#   declines.md, overrides, action, notes.md, brief.md) moves to the first
#   free phases/P<n>/superseded/<k>/, base staying, so `rounds next`
#   answers `implement 0` against the replanned brief. Then report.md's
#   `## Blocked` (when there is a report) is rewritten from the new
#   phases.md — the phases still blocked, or `None`. Frame: rc, accepted
#   (no with --check, else yes), kept (done and still-blocked phases
#   carried over), unblocked (blocked phases whose decision is now
#   decided), restarted (the unblocked phases the proposal keeps, which
#   start over — comma-separated, or `-`), phases (the rest),
#   and for i = 1..phases, in file order: phase.<i>.id,
#   phase.<i>.title.b64, phase.<i>.acceptance.
#
# phase-add — appends the one phase block in <block-file> to phases.md
#   under the next id (whatever id its heading carries; the frame names
#   the one given): refused while a phase is active (PHASE_ACTIVE) or a
#   decision open (DECISION_OPEN); the file must hold exactly one phase
#   block and nothing before it (PLAN_BAD_PHASE), a `## P<n> — <title>`
#   heading (PLAN_BAD_ID), `**Source:** loop` (/orca:loop) or `verify` (a
#   final verification's fix phase), pending, a Goal and an acceptance
#   line (PLAN_BAD_PHASE), every referenced decision decided
#   (PLAN_UNDECIDED); refused too while a phase is blocked (PHASE_BLOCKED)
#   or a restarted phase — pending with a recorded base — waits to run
#   (RESTART_PENDING).
#   A missing block file is NO_FILE. Frame: rc, phase, acceptance.
#
# phase-start — pending|active -> active. Refused for a done or blocked
#   phase (PHASE_STATE), an unknown one (NO_PHASE), while another phase
#   is active (PHASE_ACTIVE), and a pending one while any phase is
#   blocked (PHASE_BLOCKED: the pass stops until the decision is made and
#   the plan redone) or a decision is open (DECISION_OPEN), and a pending
#   one with no recorded base while another pending phase has one
#   (RESTART_PENDING: a restarted phase keeps its earlier base, so it
#   runs before anything else commits). Arrives in the worktree through
#   `worktree-item --no-provision` (as open: provisioning is the caller's,
#   after this verb, and never fatal), writes
#   phases/P<n>/base — the worktree's HEAD — only when it holds no
#   commit yet, so a re-start resumes against the same base, renders
#   phases/P<n>/brief.md (the block without its State, Source, Commit,
#   and Blocked on lines, then every referenced decision's entry) and
#   phases/P<n>/worktree (the work tree the round engine guards), and
#   only then marks the phase active. Frame: rc, dir (the phase
#   directory), phase, started (yes when it was pending, no when already
#   active), base, base_kept (yes|no), brief, worktree, branch, arrival,
#   head.
#
# phase-done — active -> done with `**Commit:** <sha>` (any name of a
#   commit, recorded in full; else BAD_REF; not active is PHASE_STATE).
#   Reads the phase's facts from `rounds facts` — the round engine's own
#   classification — before writing anything: no responses/round-0.json
#   is BAD_ROUNDS, a malformed file BAD_JSON, a gap BAD_ROUNDS.
#   Then report.md (created when absent) gets, by replacing or adding:
#     ### P<n> — <title> — <sha, 7>
#     - Decisions: D1, D3 | none
#     - Review: <reviewer>, <N> rounds, Critical/High fixed <n>
#     - Fixed after the last review: <titles>        (omitted when none)
#     - Declined: <title — reason; ...>              (omitted when none)
#     - Follow-ups: F4, F5                           (omitted when none)
#     - Checks: pass | fail[ — <commands>]
#   under `## Phases`; `## Blocked` rewritten from phases.md (`None`, or
#   `P<n> — waiting on D<n>: <question>` per blocked phase); the
#   phase's follow-ups under `## Follow-ups`; `## Landing` when absent.
#   The reviewer is the pinned `reviewer=` in .orca/config, else
#   preflight's detection (codex at the minimum version, else claude);
#   N is the reviews' count; Critical/High fixed counts a response's
#   `fixed` on a gating finding of the review it answers; fixed after
#   the last review are the `fixed` titles of a response answering the
#   last review; Declined lists declines.md's settled rulings; Checks
#   are the latest response's.
#   Follow-ups, in this order: the last review's `another work item`
#   findings (`out of scope · <title> — <file>`), Medium/Low findings
#   the implementer's latest word on is `declined` and no ruling settled
#   (`left unfixed (Medium|Low) · <title> — <reason>`), and the latest
#   response's followups[] (`gap · <title> — <why>`). Each line reads
#   `- F<n> · P<n> · <kind> · <title>[ — <detail>]`. Ids come from the
#   followups ledger: one already given to the same title and file is
#   reused (not added twice), a new one is the highest id in the
#   ledger or report.md + 1, so an id is never given twice.
#   `**Deliverable state:**` only ever goes down: a phase committed
#   with red checks in its latest response, with gating findings left
#   in its last review, or with no review at all turns `verified` into
#   `unverified — P<n> (<sha, 7>) committed <why>`; an `unverified`
#   line is never touched. Frame: rc, phase, commit, headline.b64 (the
#   entry's heading text), followups_added (new ids), deliverable_state
#   (verified | unverified), report.
#
# phase-block — active -> blocked with `**Blocked on:** <D>` (the
#   decision must exist: NO_DECISION; not active is PHASE_STATE), then
#   report.md's `## Blocked` rewritten as phase-done does (report.md
#   created when absent). Every later pending phase waits behind it.
#   Frame: rc, phase, blocked_on, waiting (pending phases after it).
#
# verify-done — records the final verification of the branch tip, run
#   once every phase is done (not so: PHASE_STATE; no phase at all:
#   NO_PHASE): report.md's `**Final verification:**` line set to
#   `pass after <P> (<sha, 7>)` or `fail after <P> (<sha, 7>) — <why>`,
#   <P> the last phase, <sha> the branch tip (GIT_ERROR when it cannot
#   be read). A fail needs <why> (BAD_ARGS) and turns a `verified`
#   deliverable state into `unverified — final verification failed after
#   <P> (<sha, 7>): <why>`. The line ends the derived `verify` state
#   until a phase is added after <P>. Frame: rc, result, phase, tip,
#   deliverable_state, report.
#
# ---- archive subcommands --------------------------------------------------
#
# archive — retires the objective, landed or not; the directory stays.
#   Runs under the claim lock, taken before any check (CLAIM_BUSY while
#   another holds it), like open's claim and unarchive. Refused (nothing done) while another session's
#   claim reads live or unknown (OWNED_ELSEWHERE; this session's own or
#   a stale one passes),
#   and when the worktree is not this repository's, has another branch
#   checked out, holds this shell's current directory, or the branch is
#   checked out anywhere else (WORKTREE_IN_USE). It is landed when the
#   worktree is clean (or absent) and the branch moved past its base and
#   is merged into the trunk — the derived `landed` test; anything else
#   needs --abandon (NOT_LANDED without it). Then, in order: when the
#   worktree is dirty and no unfinished phase has a recorded base (whose
#   review would cover the work), report.md's `**Deliverable state:**`
#   goes down to `unverified — uncommitted work set aside by archive
#   outside any phase, never checked or reviewed` (report.md created when
#   absent; an unverified line is kept); the
#   worktree's uncommitted work becomes one `wip: <slug> — set aside,
#   partial work` commit on the branch, the branch tip is kept at
#   refs/orca/archive/<slug> (a hidden ref, so `git gc` keeps it), the
#   decision is written to `archiving` before anything is removed:
#     state=landed|abandoned  date=<iso>  tip=<sha|->  note=<text, one line>
#   then the worktree is removed (never --force: git re-checks it), the
#   branch deleted, the owner file removed, and `archiving` becomes
#   `archived`. An interruption anywhere after `archiving` is written
#   leaves it in place: open and every phase subcommand refuse it
#   (ARCHIVED), list counts it archived, and re-running archive finishes
#   from it without judging the gate again — a dirty worktree salvaged
#   once more, a branch that moved since kept at its new tip — while
#   unarchive restores from it like from `archived`. An archived
#   objective is a no-op. Frame: rc, dir, state, tip, ref (the kept ref,
#   or `-` with no branch), salvaged (committed | clean | no-worktree |
#   resumed), worktree (removed | absent), branch
#   (removed | absent), already (no; yes for the no-op, with dir, state,
#   tip only).
#
# unarchive — under the claim lock (CLAIM_BUSY), recreates the branch at refs/orca/archive/<slug> (else the
#   recorded tip, when that commit survives; NO_ARCHIVE when neither
#   does), removes `archived`, then drops the ref. A branch of that name
#   at another commit is BRANCH_EXISTS; at the same commit it is kept.
#   The worktree is not re-added — the next `open` arrives through
#   worktree-item (branch_resumed), and its caller provisions it. Nothing
#   archived is a no-op. Frame:
#   rc, dir, restored (yes | no), branch (restored | exists | none — no
#   tip was ever kept), tip.
#
# any subcommand:
#   FAIL:<TAB><reason><TAB><detail>    exit 1
#     reasons: BAD_ARGS BAD_DIR BAD_SLUG BAD_REF NOT_GIT OLD_GIT NOT_BARE
#              BRANCH_EXISTS OBJECTIVE_EXISTS WORKTREE_EXISTS
#              NO_SESSION_ID ARCHIVED OWNED_ELSEWHERE OWNER_STALE CLAIM_BUSY
#              NO_PLAN NO_FILE NO_PHASE NO_DECISION DECISION_OPEN
#              PHASE_ACTIVE PHASE_STATE PHASE_BLOCKED PLAN_BAD_ID
#              PLAN_BAD_PHASE PLAN_REWRITES_DONE PLAN_UNDECIDED
#              PLAN_DROPS_WORK PLAN_BAD_ORDER RESTART_PENDING NOT_OWNER
#              BAD_ROUNDS BAD_JSON
#              NOT_LANDED WORKTREE_IN_USE WORKTREE_MISMATCH BRANCH_FOREIGN
#              NO_ARCHIVE
#              WRITE_ERROR GIT_ERROR, and worktree-item's own
#
# Sourced by orca.sh with the verb arguments in place; lib.sh is already
# loaded.

objective_usage="usage: orca.sh objective new <repo> <slug> <base-ref> [--idea <file>|-] | open <dir> [--steal] | current <repo> | idle <dir> | list <repo> [--all] | digest <dir> | plan-accept <dir> [--check] | phase-add <dir> <block-file> | phase-start <dir> <P> | phase-done <dir> <P> <sha> | phase-block <dir> <P> <D> | verify-done <dir> pass|fail [<why>] | archive <dir> [--abandon] [--note <text>] | unarchive <dir>"
obj_tab='	'

# ---- repository and directory resolution ----------------------------------

obj_resolve_repo() { # <path> — sets common_dir, repo_root, is_bare
  [ -d "$1" ] || fail BAD_ARGS "not a directory: $1"
  cd "$1" 2>/dev/null || fail BAD_ARGS "cannot enter $1"
  resolve_repo
  # Canonical, so a directory built from it compares equal to a
  # canonicalized <dir> argument.
  repo_root="$(canonicalize "$repo_root")"
}

obj_require_dir() { # <dir> — sets obj_dir (canonical) and resolves its repository
  local canon parent
  is_run_dir "$1" || fail BAD_DIR "'$1' is not an absolute, existing directory inside a .orca/"
  canon="$(canonicalize "$1")"
  parent="$(dirname "$canon")"
  [ "${parent##*/}" = objectives ] && [ "$(basename "$(dirname "$parent")")" = .orca ] \
    || fail BAD_DIR "'$1' is not a directory directly under a .orca/objectives/"
  obj_is_objective_name "${canon##*/}" \
    || fail BAD_DIR "'$1' is not named <YYYYMMDD-HHMMSS>-<slug>"
  [ -f "$canon/objective.md" ] || fail BAD_DIR "'$1' has no objective.md"
  obj_dir="$canon"
  obj_resolve_repo "$(dirname "$(dirname "$parent")")"
}

obj_slug_of() { # <dir> — the slug: the directory name past its timestamp
  local name="${1##*/}"
  printf '%s' "${name#[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-}"
}

obj_is_objective_name() { # <name> — <YYYYMMDD-HHMMSS>-<slug>
  [[ $1 =~ ^[0-9]{8}-[0-9]{6}-[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# obj_dirs — every objective directory of the resolved repository, one
# per line, oldest first (timestamped names sort chronologically).
obj_dirs() {
  local d
  for d in "$repo_root/.orca/objectives"/*; do
    [ -d "$d" ] && [ -f "$d/objective.md" ] && obj_is_objective_name "${d##*/}" && printf '%s\n' "$d"
  done
}

obj_session() { # sets obj_sid from the environment, or fails NO_SESSION_ID
  obj_sid="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$obj_sid" ] || fail NO_SESSION_ID "CLAUDE_CODE_SESSION_ID is not set — objectives are owned by a Claude Code session; run this from one"
}

# ---- file readers ---------------------------------------------------------

# obj_header <file> <key> — the first `**<key>:**` line's value, outer
# backticks stripped; empty when absent.
obj_header() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk -v key="**$2:** " '
    index($0, key) == 1 {
      v = substr($0, length(key) + 1)
      sub(/^ +/, "", v); sub(/ +$/, "", v)
      if (v ~ /^`.*`$/) v = substr(v, 2, length(v) - 2)
      print v
      exit
    }' "$1"
}

# obj_entries <file> <D|P> — one TSV row per entry:
#   id<TAB>state<TAB>commit<TAB>blocked-on<TAB>source<TAB>title
# empty fields as `-` (a tab-split read would collapse them), tabs and
# CRs in values as spaces.
obj_entries() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk -v kind="$2" '
    function flush() {
      if (id != "") print id "\t" val("State") "\t" val("Commit") "\t" val("Blocked on") "\t" val("Source") "\t" title
      id = ""; split("", seen)
    }
    function val(k) { return (k in seen && seen[k] != "") ? seen[k] : "-" }
    function first(s) { sub(/^ +/, "", s); sub(/[ ,;].*$/, "", s); return s }
    { gsub(/[\t\r]/, " ") }
    $0 ~ ("^## " kind "[1-9][0-9]* — ") {
      flush()
      rest = substr($0, 4)
      id = rest; sub(/ .*$/, "", id)
      title = rest; sub(/^[^ ]+ — /, "", title); sub(/ +$/, "", title)
      if (title == "") title = "-"
      next
    }
    /^## / { flush(); next }
    id != "" && match($0, /^\*\*[A-Za-z ]+:\*\* ?/) {
      k = substr($0, 3); sub(/:\*\*.*$/, "", k)
      if (k in seen) next
      v = substr($0, RLENGTH + 1); sub(/ +$/, "", v)
      seen[k] = (k == "Source") ? v : first(v)
    }
    END { flush() }' "$1"
}

# obj_followups <dir> — the F ids listed under report.md's ## Follow-ups,
# one per line.
obj_followups() {
  [ -f "$1/report.md" ] || return 0
  LC_ALL=C awk '
    /^## / { inside = ($0 ~ /^## Follow-ups *$/); next }
    inside && match($0, /^- F[1-9][0-9]*( |$)/) { id = substr($0, 3, RLENGTH - 2); sub(/ $/, "", id); print id }
  ' "$1/report.md"
}

# obj_last_entry <dir> — the last `### ` heading under report.md's
# ## Phases, without its marker; empty when none.
obj_last_entry() {
  [ -f "$1/report.md" ] || return 0
  LC_ALL=C awk '
    /^## / { inside = ($0 ~ /^## Phases *$/); next }
    inside && /^### / { last = substr($0, 5) }
    END { gsub(/[\t\r]/, " ", last); print last }
  ' "$1/report.md"
}

# ---- derived facts --------------------------------------------------------

# obj_load <dir> — reads the objective's files once and sets:
#   obj_decisions obj_phases   obj_entries rows
#   obj_open obj_decided obj_deferred         decision counts
#   obj_total obj_done obj_active obj_blocked obj_pending   phase counts
#   obj_active_id              the first active phase, or empty
#   obj_last_id                the last phase in file order, or empty
#   obj_verification           report.md's `**Final verification:**` value
#   obj_followups_open         open follow-ups
#   obj_branch obj_base_commit obj_worktree   from objective.md's header
#   obj_state                  the derived state
obj_load() {
  local dir="$1" id state source cited="" fid
  obj_decisions="$(obj_entries "$dir/decisions.md" D)"
  obj_phases="$(obj_entries "$dir/phases.md" P)"
  obj_open=0 obj_decided=0 obj_deferred=0
  obj_total=0 obj_done=0 obj_active=0 obj_blocked=0 obj_pending=0 obj_active_id="" obj_last_id=""
  while IFS="$obj_tab" read -r id state _ _ source _; do
    [ -n "$id" ] || continue
    case "$state" in
      decided) obj_decided=$((obj_decided + 1)) ;;
      deferred) obj_deferred=$((obj_deferred + 1)) ;;
      *) obj_open=$((obj_open + 1)) ;;
    esac
    cited="$cited $(printf '%s' "$source" | grep -oE 'F[1-9][0-9]*' | tr '\n' ' ')"
  done <<EOF
$obj_decisions
EOF
  while IFS="$obj_tab" read -r id state _; do
    [ -n "$id" ] || continue
    obj_total=$((obj_total + 1))
    obj_last_id="$id"
    case "$state" in
      done) obj_done=$((obj_done + 1)) ;;
      active)
        obj_active=$((obj_active + 1))
        [ -n "$obj_active_id" ] || obj_active_id="$id" ;;
      blocked) obj_blocked=$((obj_blocked + 1)) ;;
      *) obj_pending=$((obj_pending + 1)) ;;
    esac
  done <<EOF
$obj_phases
EOF
  obj_followups_open=0
  while IFS= read -r fid; do
    [ -n "$fid" ] || continue
    in_list "$fid" "$cited" || obj_followups_open=$((obj_followups_open + 1))
  done <<EOF
$(obj_followups "$dir" | LC_ALL=C sort -u)
EOF
  obj_branch="$(obj_header "$dir/objective.md" Branch)"
  obj_base_commit="$(obj_header "$dir/objective.md" "Base commit")"
  obj_worktree="$(obj_header "$dir/objective.md" Worktree)"
  obj_verification="$(obj_header "$dir/report.md" "Final verification")"
  obj_derive_state "$dir"
}

# obj_verified — the final verification on record covers the last phase:
# report.md's `**Final verification:** <pass|fail> after <P> (<sha>)`
# names obj_last_id. A phase added since makes it stale.
obj_verified() {
  [[ $obj_verification =~ ^(pass|fail)\ after\ (P[1-9][0-9]*)( |$) ]] || return 1
  [ "${BASH_REMATCH[2]}" = "$obj_last_id" ]
}

# obj_marker <dir> — the archive marker: `archived` once an archive
# finished, else `archiving` while one is under way or was interrupted
# (written before anything is removed); empty when neither exists.
obj_marker() {
  if [ -e "$1/archived" ]; then
    printf '%s/archived' "$1"
  elif [ -e "$1/archiving" ]; then
    printf '%s/archiving' "$1"
  fi
}

obj_archived_state() { # <dir> — archived | abandoned, from the archive marker
  if [ "$(lease_owner_field "$(obj_marker "$1")" state)" = abandoned ]; then
    printf 'abandoned'
  else
    printf 'archived'
  fi
}

# obj_landed — the branch moved past its base commit and is merged into
# the trunk.
obj_landed() {
  local trunk tip
  [ -n "$obj_branch" ] || return 1
  trunk="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null)" || return 1
  [ -n "$trunk" ] && [ "$trunk" != "$obj_branch" ] || return 1
  tip="$(git --git-dir="$common_dir" rev-parse -q --verify "refs/heads/$obj_branch^{commit}" 2>/dev/null)" || return 1
  [ "$tip" != "$obj_base_commit" ] || return 1
  git --git-dir="$common_dir" merge-base --is-ancestor "$tip" "refs/heads/$trunk" 2>/dev/null
}

obj_derive_state() { # <dir> — sets obj_state; the first rule that holds
  local dir="$1"
  if [ -n "$(obj_marker "$dir")" ]; then
    obj_state="$(obj_archived_state "$dir")"
  elif [ "$obj_active" -gt 0 ]; then
    obj_state=active
  elif [ -f "$dir/plan/proposed.md" ] && [ "$obj_open" -eq 0 ]; then
    obj_state=planning
  elif [ "$obj_blocked" -gt 0 ]; then
    obj_state=blocked
  elif [ "$obj_open" -gt 0 ] || [ "$obj_total" -eq 0 ]; then
    obj_state=discussing
  elif [ "$obj_pending" -gt 0 ]; then
    obj_state=ready
  elif obj_landed; then
    obj_state=landed
  elif ! obj_verified; then
    obj_state=verify
  else
    obj_state=idle
  fi
}

# obj_owner_verdict <dir> — none | mine | live | stale | unknown
obj_owner_verdict() {
  local owner="$1/owner" session
  if [ ! -e "$owner" ]; then
    printf 'none'
    return
  fi
  session="$(lease_owner_field "$owner" session)"
  if [ -n "$session" ] && [ "$session" = "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf 'mine'
    return
  fi
  lease_verdict "$owner" | cut -f1
}

obj_line() { # <dir> — the OBJECTIVE: line; obj_load must have run for <dir>
  printf 'OBJECTIVE:\t%s\t%s\t%s\topen:%s\tpending:%s\tblocked:%s\tfollowups:%s\towner:%s\n' \
    "$1" "$(obj_slug_of "$1")" "$obj_state" "$obj_open" "$obj_pending" "$obj_blocked" \
    "$obj_followups_open" "$(obj_owner_verdict "$1")"
}

# ---- writers --------------------------------------------------------------

# obj_write <path> — stdin to <path> atomically (temp file + rename);
# a target that is a symlink or not a regular file is WRITE_ERROR. Fed
# by a pipeline it runs in a subshell, whose `fail` ends only that
# subshell: every `... | obj_write` is followed by `|| exit 1`, so the
# verb stops there (the FAIL line is already printed).
obj_write() {
  local target="$1" tmp
  if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
    fail WRITE_ERROR "$target is a symlink or not a regular file — nothing written"
  fi
  tmp="$(mktemp "$(dirname "$target")/.obj.XXXXXX" 2>/dev/null)" \
    || fail WRITE_ERROR "could not create a temp file beside $target"
  if ! cat >"$tmp" 2>/dev/null || ! mv -f "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    fail WRITE_ERROR "could not write $target"
  fi
}

obj_write_owner() { # <dir>
  local pid
  pid="$(lease_session_pid)"
  {
    printf 'session=%s\n' "$obj_sid"
    printf 'host=%s\n' "$(hostname)"
    printf 'pid=%s\n' "$pid"
    printf 'pidstart=%s\n' "$(ps -o lstart= -p "$pid" 2>/dev/null)"
    printf 'taken=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } | obj_write "$1/owner" || exit 1
}

# obj_release_others <dir> — drop this session's claim on every other
# objective of the repository.
obj_release_others() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] && [ "$d" != "$1" ] || continue
    [ -f "$d/owner" ] && [ "$(lease_owner_field "$d/owner" session)" = "$obj_sid" ] \
      && rm -f "$d/owner"
  done <<EOF
$(obj_dirs)
EOF
}

# ---- the claim lock -------------------------------------------------------
# Every check-then-write of `owner` (open's claim, archive's gate and
# removal, unarchive) runs under the claim lock, so two sessions opening
# one objective at once cannot both read "no owner" and both claim it.
# The lock is a ref, refs/orca/claim/<YYYYMMDD-HHMMSS>-<slug>, pointing
# at a blob that names its holder — `<host><TAB><pid><TAB><lstart>`,
# this orca.sh process. Every change to it is a compare-and-swap by
# `git update-ref <ref> <new> <old>`, which git applies only while the
# ref still holds <old>:
#   take     <old> empty — only while no lock exists
#   recover  <old> the stale holder's blob — a holder on this host whose
#            process is gone (or whose pid was reused); of several
#            contenders that judged it stale, exactly one swaps, and a
#            lock taken since is never replaced
#   release  `update-ref -d <ref> <mine>` — only while it is still ours
# A live or unreadable holder is waited on, up to ORCA_OBJ_LOCK_TRIES
# checks 0.2 s apart (default 50), then CLAIM_BUSY. The holder releases
# it on exit, whatever the exit.

obj_lock_target() {
  printf '%s\t%s\t%s' "$(hostname)" "$$" "$(ps -o lstart= -p "$$" 2>/dev/null)"
}

obj_lock_stale() { # <target> — exit 0 iff it names a gone process on this host
  local host pid start rest
  host="${1%%"$obj_tab"*}"; rest="${1#*"$obj_tab"}"
  pid="${rest%%"$obj_tab"*}"; start="${rest#*"$obj_tab"}"
  [ "$host" = "$(hostname)" ] && [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 0
  [ "$(ps -o lstart= -p "$pid" 2>/dev/null)" != "$start" ]
}

obj_lock_ref() { printf 'refs/orca/claim/%s' "${obj_dir##*/}"; }

obj_lock() {
  local ref mine blob held text="" tries=0 max="${ORCA_OBJ_LOCK_TRIES:-50}"
  [[ $max =~ ^[1-9][0-9]{0,3}$ ]] || max=50
  ref="$(obj_lock_ref)"
  mine="$(obj_lock_target)"
  blob="$(printf '%s' "$mine" | git --git-dir="$common_dir" hash-object -w --stdin 2>/dev/null)" || blob=""
  is_marker "$blob" || fail GIT_ERROR "could not write the claim lock's holder blob — nothing done"
  while ! git --git-dir="$common_dir" update-ref "$ref" "$blob" "" 2>/dev/null; do
    held="$(git --git-dir="$common_dir" rev-parse -q --verify "$ref" 2>/dev/null)" || held=""
    if [ -n "$held" ]; then
      text="$(git --git-dir="$common_dir" cat-file blob "$held" 2>/dev/null)" || text=""
      if [ -n "$text" ] && obj_lock_stale "$text"; then
        # The swap succeeds only while the ref still holds the stale blob.
        git --git-dir="$common_dir" update-ref "$ref" "$blob" "$held" 2>/dev/null && break
      fi
    fi
    tries=$((tries + 1))
    [ "$tries" -lt "$max" ] \
      || fail CLAIM_BUSY "another claim or archive of $obj_dir is in progress (held by $(printf '%s' "${text:-unknown}" | tr '\t' ' ')) — retry once it is done; nothing done"
    sleep 0.2
  done
  obj_lock_held="$ref" obj_lock_blob="$blob"
  trap obj_unlock EXIT
}

obj_unlock() {
  [ -n "${obj_lock_held:-}" ] || return 0
  git --git-dir="$common_dir" update-ref -d "$obj_lock_held" "$obj_lock_blob" 2>/dev/null
  obj_lock_held=""
}

# obj_claim <dir> <steal 0|1> — sets obj_claim to claimed | kept | stolen.
# Runs under the claim lock (obj_open).
obj_claim() {
  local dir="$1" steal="$2" owner="$1/owner" session verdict
  if [ ! -e "$owner" ]; then
    obj_claim=claimed
  else
    session="$(lease_owner_field "$owner" session)"
    verdict="$(lease_verdict "$owner")"
    if [ -n "$session" ] && [ "$session" = "$obj_sid" ]; then
      if [ "${verdict%%"$obj_tab"*}" = live ]; then
        obj_claim=kept
        obj_release_others "$dir"
        return
      fi
      obj_claim=claimed
    else
      case "${verdict%%"$obj_tab"*}" in
        stale)
          [ "$steal" -eq 1 ] || fail OWNER_STALE "$dir is claimed by session ${session:-unknown}, whose process is gone ($(printf '%s' "$verdict" | tr '\t' ' ')) — rerun with --steal to take it over"
          obj_claim=stolen ;;
        *)
          fail OWNED_ELSEWHERE "$dir is owned by session ${session:-unknown} ($(printf '%s' "$verdict" | tr '\t' ' ')) — one session drives an objective at a time; nothing done" ;;
      esac
    fi
  fi
  obj_write_owner "$dir"
  obj_release_others "$dir"
}

# ---- subcommands ----------------------------------------------------------

obj_new() { # <repo> <slug> <base-ref> [--idea <file>|-]
  local slug="$2" base="$3" base_commit stamp dir wt branch d idea=""
  if [ $# -eq 5 ]; then
    [ "$4" = --idea ] || fail BAD_ARGS "$objective_usage"
    if [ "$5" = - ]; then
      idea="$(cat)" || fail BAD_ARGS "could not read the idea from stdin"
    else
      [ -f "$5" ] && [ -r "$5" ] || fail BAD_ARGS "idea file '$5' is not a readable file"
      idea="$(cat -- "$5")" || fail BAD_ARGS "could not read idea file '$5'"
    fi
  fi
  [[ $slug =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#slug}" -le 60 ] \
    || fail BAD_SLUG "'$slug' is not a lowercase kebab-case slug of at most 60 characters"
  obj_resolve_repo "$1"
  [ "$is_bare" = true ] \
    || fail NOT_BARE "conventional checkout at $repo_root — objectives need the bare-with-worktrees layout; run /orca:init to convert"
  base_commit="$(git --git-dir="$common_dir" rev-parse -q --verify "$base^{commit}" 2>/dev/null)" \
    || fail BAD_REF "'$base' does not name a commit in this repository"
  branch="feature/$slug"
  wt="$repo_root/orca-$slug"
  while IFS= read -r d; do
    [ -n "$d" ] && [ "$(obj_slug_of "$d")" = "$slug" ] \
      && fail OBJECTIVE_EXISTS "an objective with slug '$slug' already exists: $d"
  done <<EOF
$(obj_dirs)
EOF
  git --git-dir="$common_dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1 \
    && fail BRANCH_EXISTS "$branch already exists — branches are shared with runs and never reused; pick another slug"
  { [ -e "$wt" ] || [ -L "$wt" ]; } \
    && fail WORKTREE_EXISTS "$wt already exists — pick another slug"
  if [ -L "$repo_root/.orca" ] || [ -L "$repo_root/.orca/objectives" ]; then
    fail WRITE_ERROR "$repo_root/.orca or its objectives/ is a symlink — nothing written"
  fi
  mkdir -p "$repo_root/.orca/objectives" 2>/dev/null \
    || fail WRITE_ERROR "could not create $repo_root/.orca/objectives"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  dir="$repo_root/.orca/objectives/$stamp-$slug"
  mkdir "$dir" 2>/dev/null || fail WRITE_ERROR "could not create $dir"
  [ -z "$idea" ] || idea="$idea"$'\n\n'
  # shellcheck disable=SC2016  # the backticks are markdown, not expansions
  printf '# %s\n\n**Base:** `%s`\n**Base commit:** `%s`\n**Branch:** `%s`\n**Worktree:** `%s`\n\n## Idea\n\n%s## Outcome\n\n## Non-goals\n\n## Constraints\n' \
    "$slug" "$base" "$base_commit" "$branch" "$wt" "$idea" | obj_write "$dir/objective.md" || exit 1
  printf '# Decisions\n' | obj_write "$dir/decisions.md" || exit 1
  printf '# Phases\n' | obj_write "$dir/phases.md" || exit 1
  # The branch is born here, at the base, owned by this objective: git
  # creates a ref only while none exists, so a branch made since the
  # check above loses nothing but this objective's fresh directory.
  if ! git --git-dir="$common_dir" branch "$branch" "$base_commit" >/dev/null 2>&1; then
    rm -rf "$dir"
    fail BRANCH_EXISTS "$branch appeared while the objective was being created — pick another slug; nothing kept"
  fi
  emit_frame rc=0 "dir=$dir" "worktree=$wt" "branch=$branch" "base=$base_commit"
}

obj_require_live() { # obj_dir must not be archived, or mid-archive
  [ -e "$obj_dir/archived" ] \
    && fail ARCHIVED "$obj_dir is $(obj_archived_state "$obj_dir") — restore it first (/orca:archive --undo)"
  [ -e "$obj_dir/archiving" ] \
    && fail ARCHIVED "an archive of $obj_dir did not finish — re-run /orca:archive to finish it, or /orca:archive --undo to restore it"
  return 0
}

obj_require_header() { # obj_load must have run
  if [ -z "$obj_branch" ] || [ -z "$obj_worktree" ] || ! is_marker "$obj_base_commit"; then
    fail BAD_DIR "$obj_dir/objective.md lacks its Branch, Worktree, or Base commit header line"
  fi
}

# obj_arrive — worktree arrival through worktree-item --no-provision
# (created off the base commit, reused, or branch_resumed); its failure
# exits. Sets obj_arrival_keys, the frame keys open and phase-start print
# after their own.
# obj_check_worktree — the objective's branch, when it exists, must
# descend from the base commit (BRANCH_FOREIGN otherwise: a branch of
# that name that is not this objective's), and the saved worktree, when
# its path exists, must be a worktree root of this repository with the
# objective's branch checked out (WORKTREE_MISMATCH) — before arrival
# touches either.
obj_check_worktree() {
  local common head tip
  tip="$(git --git-dir="$common_dir" rev-parse -q --verify "refs/heads/$obj_branch^{commit}" 2>/dev/null)" || tip=""
  if [ -n "$tip" ] && ! git --git-dir="$common_dir" merge-base --is-ancestor "$obj_base_commit" "$tip" 2>/dev/null; then
    fail BRANCH_FOREIGN "$obj_branch at ${tip:0:7} does not descend from the objective's base ${obj_base_commit:0:7} — another branch took its name; nothing done"
  fi
  [ -e "$obj_worktree" ] || [ -L "$obj_worktree" ] || return 0
  is_worktree_root "$obj_worktree" \
    || fail WORKTREE_MISMATCH "$obj_worktree exists but is not a git worktree root — move it aside; nothing done"
  common="$(git -C "$obj_worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [ -n "$common" ] && [ "$(canonicalize "$common")" = "$(canonicalize "$common_dir")" ] \
    || fail WORKTREE_MISMATCH "$obj_worktree is a worktree of another repository — nothing done"
  head="$(git -C "$obj_worktree" symbolic-ref -q --short HEAD 2>/dev/null)"
  [ "$head" = "$obj_branch" ] \
    || fail WORKTREE_MISMATCH "$obj_worktree has ${head:-a detached HEAD} checked out, not $obj_branch — check out $obj_branch there first; nothing done"
}

obj_arrive() {
  local out line in_frame=0 key value arrival="" head=""
  obj_check_worktree
  if ! out="$(bash "$orca_scripts_dir/orca.sh" worktree-item "$repo_root" "$obj_worktree" "$obj_branch" "$obj_base_commit" --no-provision 2>&1)"; then
    printf '%s\n' "$out"
    exit 1
  fi
  while IFS= read -r line; do
    case "$line" in
      @@ORCA@@) in_frame=1; continue ;;
      @@ORCA_END@@) in_frame=0; continue ;;
    esac
    [ "$in_frame" -eq 1 ] || continue
    key="${line%%=*}" value="${line#*=}"
    case "$key" in
      arrival) arrival="$value" ;;
      head) head="$value" ;;
    esac
  done <<EOF
$out
EOF
  obj_arrival_keys=("arrival=$arrival" "head=$head")
}

obj_open() { # <dir> [--steal]
  local steal=0
  [ $# -eq 1 ] || { [ $# -eq 2 ] && [ "$2" = --steal ]; } || fail BAD_ARGS "$objective_usage"
  [ $# -eq 2 ] && steal=1
  obj_require_dir "$1"
  obj_session
  # Under the lock before any check: an open that waited behind an
  # archive sees its `archived` file, and reads the files it left.
  obj_lock
  obj_require_live
  obj_load "$obj_dir"
  obj_require_header
  obj_claim "$obj_dir" "$steal"
  obj_unlock
  obj_arrive
  obj_line "$obj_dir"
  emit_frame rc=0 "dir=$obj_dir" "claim=$obj_claim" "worktree=$obj_worktree" "branch=$obj_branch" \
    "base=$obj_base_commit" "${obj_arrival_keys[@]}"
}

obj_current() { # <repo>
  local d match=""
  obj_session
  obj_resolve_repo "$1"
  while IFS= read -r d; do
    [ -n "$d" ] && [ -f "$d/owner" ] && [ -z "$(obj_marker "$d")" ] || continue
    [ "$(lease_owner_field "$d/owner" session)" = "$obj_sid" ] || continue
    if [ -z "$match" ] || [ "$d/owner" -nt "$match/owner" ]; then match="$d"; fi
  done <<EOF
$(obj_dirs)
EOF
  emit_frame rc=0 "dir=${match:-none}"
}

# obj_idle <dir> — read-only gate for work on the objective's branch
# outside the phase loop (/orca:review's address flow): this session owns
# it and no phase is active.
obj_idle() {
  local session verdict restarted
  obj_require_dir "$1"
  obj_session
  obj_require_live
  obj_load "$obj_dir"
  session="$(lease_owner_field "$obj_dir/owner" session 2>/dev/null)"
  if [ ! -f "$obj_dir/owner" ] || [ "$session" != "$obj_sid" ]; then
    verdict="$(obj_owner_verdict "$obj_dir")"
    fail NOT_OWNER "this session does not own $obj_dir (owner: $verdict${session:+, session $session}) — /orca:open it in this session first; nothing done"
  fi
  obj_require_no_active
  # A blocked or restarted phase keeps its base: a commit made now would
  # sit inside the range its review and resets cover.
  obj_require_no_blocked
  restarted="$(obj_restarted)"
  [ -z "$restarted" ] \
    || fail RESTART_PENDING "$restarted restarts from its earlier base — run it first (/orca:open); nothing done"
  emit_frame rc=0 "dir=$obj_dir" "state=$obj_state"
}

obj_list() { # <repo> [--all]
  local all=0 d
  [ $# -eq 1 ] || { [ $# -eq 2 ] && [ "$2" = --all ]; } || fail BAD_ARGS "$objective_usage"
  [ $# -eq 2 ] && all=1
  obj_resolve_repo "$1"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$all" -eq 1 ] || [ -z "$(obj_marker "$d")" ] || continue
    obj_load "$d"
    obj_line "$d"
  done <<EOF
$(obj_dirs)
EOF
}

# obj_trunc_awk — the awk function every digest line truncates through:
# at most <n> bytes, never splitting a UTF-8 sequence, `…` when cut.
obj_trunc_awk='
function trunc(s, n,    c) {
  if (length(s) <= n) return s
  s = substr(s, 1, n - 1)
  while (length(s) > 0) {
    c = substr(s, length(s), 1)
    if (c >= "\200" && c < "\300") { s = substr(s, 1, length(s) - 1); continue }
    if (c >= "\300") s = substr(s, 1, length(s) - 1)
    break
  }
  sub(/ +$/, "", s)
  return s "…"
}'

obj_trunc() { # <text> <n>
  printf '%s\n' "$1" | LC_ALL=C awk -v n="$2" "$obj_trunc_awk"'{ print trunc($0, n) }'
}

# obj_outcome <dir> — the first line under objective.md's ## Outcome.
obj_outcome() {
  LC_ALL=C awk '
    /^## / { inside = ($0 ~ /^## Outcome *$/); next }
    inside && /[^ \t]/ { gsub(/[\t\r]/, " "); sub(/^ +/, ""); print; exit }
  ' "$1/objective.md"
}

# obj_tree_state <worktree> — clean | dirty | absent | unknown. Untracked
# files count whatever status.showUntrackedFiles says; a status git
# cannot produce is unknown, never clean.
obj_tree_state() {
  local porcelain
  if ! is_worktree_root "$1"; then
    printf 'absent'
  elif ! porcelain="$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null)"; then
    printf 'unknown'
  elif [ -n "$porcelain" ]; then
    printf 'dirty'
  else
    printf 'clean'
  fi
}

# obj_action_line <dir> <P> — the phase's last round-engine action.
obj_action_line() {
  local file="$1/phases/$2/action" action round gating minor oos
  if [ ! -f "$file" ]; then
    printf 'Action: %s · none yet\n' "$2"
    return
  fi
  action="$(lease_owner_field "$file" action)"
  round="$(lease_owner_field "$file" round)"
  gating="$(lease_owner_field "$file" gating)"
  minor="$(lease_owner_field "$file" minor)"
  oos="$(lease_owner_field "$file" out_of_scope)"
  if [[ $action =~ ^[a-z-]+$ && $round =~ ^[0-9]+$ && $gating =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ && $oos =~ ^[0-9]+$ ]]; then
    printf 'Action: %s · %s round %s · gating %s, minor %s, out of scope %s\n' \
      "$2" "$action" "$round" "$gating" "$minor" "$oos"
  else
    printf 'Action: %s · unreadable action file\n' "$2"
  fi
}

obj_digest() { # <dir>
  local title outcome last
  obj_require_dir "$1"
  obj_load "$obj_dir"
  title="$(LC_ALL=C awk '/^# / { print substr($0, 3); exit }' "$obj_dir/objective.md")"
  outcome="$(obj_outcome "$obj_dir")"
  last="$(obj_last_entry "$obj_dir")"

  printf '# %s\n' "$(obj_trunc "${title:-$(obj_slug_of "$obj_dir")}" 72)"
  printf 'Outcome: %s\n' "$(obj_trunc "${outcome:-not written yet}" 100)"
  printf 'State: %s\n' "$obj_state"
  printf 'Worktree: %s (%s)\n' "${obj_worktree:--}" "$(obj_tree_state "$obj_worktree")"
  printf 'Branch: %s\n' "${obj_branch:--}"
  printf 'Decisions: %s decided, %s open, %s deferred\n' "$obj_decided" "$obj_open" "$obj_deferred"
  printf '%s\n' "$obj_decisions" | LC_ALL=C awk -F'\t' -v max=8 "$obj_trunc_awk"'
    $1 != "" && $2 != "decided" && $2 != "deferred" {
      n++
      if (n <= max) printf "  %s  open  %s\n", $1, trunc($6, 60)
    }
    END { if (n > max) printf "  … %d more open\n", n - max }'
  printf 'Phases: %s of %s done\n' "$obj_done" "$obj_total"
  printf '%s\n' "$obj_phases" | LC_ALL=C awk -F'\t' -v max=13 "$obj_trunc_awk"'
    function norm(s) { return (s == "done" || s == "active" || s == "blocked") ? s : "pending" }
    $1 != "" { n++; id[n] = $1; st[n] = norm($2); commit[n] = $3; on[n] = $4; title[n] = $6 }
    END {
      shown = 0
      # The active phase first: the loop resumes from what the digest lists.
      for (i = 1; i <= n; i++) if (st[i] == "active" && shown < max) { show[i] = 1; shown++ }
      for (i = 1; i <= n; i++) if (st[i] != "done" && !show[i] && shown < max) { show[i] = 1; shown++ }
      for (i = n; i >= 1; i--) if (st[i] == "done" && shown < max) { show[i] = 1; shown++ }
      for (i = 1; i <= n; i++) {
        if (!show[i]) { hidden[st[i]]++; hid++; continue }
        if (st[i] == "done") detail = "done " (commit[i] == "-" ? "-" : substr(commit[i], 1, 7))
        else if (st[i] == "blocked") detail = "blocked on " on[i]
        else detail = st[i]
        printf "  %s  %s  %s\n", id[i], trunc(detail, 24), trunc(title[i], 60)
      }
      if (hid) {
        line = ""
        split("done active blocked pending", order, " ")
        for (k = 1; k <= 4; k++) if (hidden[order[k]]) line = line (line == "" ? "" : ", ") hidden[order[k]] " " order[k]
        printf "  … %d more: %s\n", hid, line
      }
    }'
  [ -n "$obj_active_id" ] && obj_action_line "$obj_dir" "$obj_active_id"
  printf 'Final verification: %s\n' "$(obj_trunc "${obj_verification:-none}" 100)"
  printf 'Follow-ups: %s open\n' "$obj_followups_open"
  printf 'Last report entry: %s\n' "$(obj_trunc "${last:-none}" 80)"
}

# ---- phase blocks ---------------------------------------------------------

obj_nl='
'

# obj_block <file> <id> — the entry `## <id> — ...` verbatim: its heading
# through its last non-blank line; empty when absent.
obj_block() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk -v id="$2" '
    /^## / { if (inside) exit; inside = (index($0, "## " id " — ") == 1) }
    inside { buf[++n] = $0; if ($0 ~ /[^ \t\r]/) last = n }
    END { for (i = 1; i <= last; i++) print buf[i] }' "$1"
}

# obj_headings <file> <D|P> — one line per `## ` heading: the entry's id,
# or `!<TAB><the line>` for a heading that is not `## <kind><n> — <title>`.
obj_headings() {
  LC_ALL=C awk -v kind="$2" '
    /^## / {
      if ($0 ~ ("^## " kind "[1-9][0-9]* — [^ \t\r]")) { id = substr($0, 4); sub(/ .*$/, "", id); print id }
      else { gsub(/[\t\r]/, " "); print "!\t" $0 }
    }' "$1"
}

# obj_phase_facts <file> — one TSV row per phase entry, `-` for empty:
#   id<TAB>state<TAB>source<TAB>decisions (space-separated D ids)
#   <TAB>goal (1 when a non-empty Goal line)<TAB>acceptance lines<TAB>title
#   <TAB>blocked (1 when a `**Blocked on:**` line)
obj_phase_facts() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk '
    function dash(s) { return s == "" ? "-" : s }
    function flush() {
      if (id != "") print id "\t" dash(state) "\t" dash(source) "\t" dash(decs) "\t" goal "\t" acc "\t" dash(title) "\t" blocked
      id = ""
    }
    { gsub(/[\t\r]/, " ") }
    /^## / {
      flush()
      if ($0 ~ /^## P[1-9][0-9]* — /) {
        rest = substr($0, 4)
        id = rest; sub(/ .*$/, "", id)
        title = rest; sub(/^[^ ]+ — /, "", title); sub(/ +$/, "", title)
        state = source = decs = ""
        goal = acc = inacc = blocked = 0
        split("", seen)
      }
      next
    }
    id == "" { next }
    match($0, /^\*\*[A-Za-z ]+:\*\* ?/) {
      k = substr($0, 3); sub(/:\*\*.*$/, "", k)
      v = substr($0, RLENGTH + 1); sub(/^ +/, "", v); sub(/ +$/, "", v)
      inacc = (k == "Acceptance")
      if (k in seen) next
      seen[k] = 1
      if (k == "State") { state = v; sub(/[ ,;].*$/, "", state) }
      else if (k == "Source") source = v
      else if (k == "Goal") goal = (v != "")
      else if (k == "Blocked on") blocked = 1
      else if (k == "Decisions")
        while (match(v, /D[1-9][0-9]*/)) {
          decs = decs (decs == "" ? "" : " ") substr(v, RSTART, RLENGTH)
          v = substr(v, RSTART + RLENGTH)
        }
      next
    }
    inacc && /^- *[^ ]/ { acc++ }
    END { flush() }' "$1"
}

obj_phase_field() { # <P> <column> — one column of the phase's obj_phase_facts row
  obj_phase_facts "$obj_dir/phases.md" | LC_ALL=C awk -F'\t' -v id="$1" -v col="$2" '$1 == id { print $col; exit }'
}

obj_decision_state() { # <D> — the decision's state from obj_decisions; empty when absent
  printf '%s\n' "$obj_decisions" | LC_ALL=C awk -F'\t' -v id="$1" '$1 == id { print $2; exit }'
}

obj_decision_question() { # <D>
  printf '%s\n' "$obj_decisions" | LC_ALL=C awk -F'\t' -v id="$1" '$1 == id { print $6; exit }'
}

# obj_max_phase — the highest phase number taken, 0 when none: the
# highest of phases.md's ids and the phases/P<n> directories, so an id
# that ever held state is never given again.
obj_max_phase() {
  local d dirs=""
  for d in "$obj_dir"/phases/P*; do
    [ -d "$d" ] && dirs="$dirs${d##*/}$obj_nl"
  done
  { printf '%s\n' "$obj_phases" | cut -f1; printf '%s' "$dirs"; } \
    | LC_ALL=C awk '/^P[1-9][0-9]{0,5}$/ { n = substr($1, 2) + 0; if (n > max) max = n } END { print max + 0 }'
}

# obj_restarted [<except>] — the first pending phase (other than
# <except>) with a recorded phases/P<n>/base: one restarted after a block
# that keeps its earlier base, so nothing may commit before it runs.
obj_restarted() {
  local id state
  while IFS="$obj_tab" read -r id state _; do
    [ -n "$id" ] && [ "$id" != "${1:-}" ] || continue
    case "$state" in active | 'done' | blocked) continue ;; esac
    [ -f "$obj_dir/phases/$id/base" ] && { printf '%s' "$id"; return; }
  done <<EOF
$obj_phases
EOF
}

obj_require_no_blocked() { # obj_load must have run — a blocked phase stops the whole pass
  local ids
  [ "$obj_blocked" -eq 0 ] && return 0
  ids="$(printf '%s\n' "$obj_phases" | LC_ALL=C awk -F'\t' '$2 == "blocked" { printf "%s%s on %s", (n++ ? ", " : ""), $1, $4 }')"
  fail PHASE_BLOCKED "$ids — no phase runs while one is blocked; decide what it waits on, then replan"
}

# obj_require_phase <P> — sets obj_phase_state (pending | active | done |
# blocked) and obj_phase_title; obj_load must have run.
obj_require_phase() {
  local row
  [[ $1 =~ ^P[1-9][0-9]*$ ]] || fail BAD_ARGS "'$1' is not a phase id (P<n>)"
  row="$(printf '%s\n' "$obj_phases" | LC_ALL=C awk -F'\t' -v id="$1" '$1 == id { print; exit }')"
  [ -n "$row" ] || fail NO_PHASE "$1 is not in $obj_dir/phases.md"
  obj_phase_state="$(printf '%s' "$row" | cut -f2)"
  obj_phase_title="$(printf '%s' "$row" | cut -f6)"
  case "$obj_phase_state" in
    active | done | blocked) ;;
    *) obj_phase_state=pending ;;
  esac
}

obj_require_no_open() { # obj_load must have run
  local ids
  [ "$obj_open" -eq 0 ] && return 0
  ids="$(printf '%s\n' "$obj_decisions" | LC_ALL=C awk -F'\t' '$1 != "" && $2 != "decided" && $2 != "deferred" { printf "%s%s", (n++ ? ", " : ""), $1 }')"
  fail DECISION_OPEN "$ids open in decisions.md — settle it first"
}

obj_require_no_active() { # obj_load must have run
  [ "$obj_active" -eq 0 ] || fail PHASE_ACTIVE "$obj_active_id is active — finish or block it first"
}

obj_check_decided() { # <phase> <space-separated D ids>
  local d state
  for d in $2; do
    state="$(obj_decision_state "$d")"
    case "$state" in
      decided) continue ;;
      '') state="not in decisions.md" ;;
      deferred) ;;
      *) state=open ;;
    esac
    fail PLAN_UNDECIDED "$1 realizes $d, which is $state — a phase realizes decided decisions only"
  done
}

# obj_check_new_phase <facts-row> [<sources>] — a phase about to be
# installed: pending with no Blocked on line, a Goal, an acceptance line,
# decided decisions, and (when given) one of those space-separated
# Sources.
obj_check_new_phase() {
  local id state source decs goal acc blocked
  IFS="$obj_tab" read -r id state source decs goal acc _ blocked <<EOF
$1
EOF
  [ "$state" = pending ] || fail PLAN_BAD_PHASE "$id is '$state' — a new or rewritten phase is pending"
  [ "$blocked" != 1 ] || fail PLAN_BAD_PHASE "$id has a **Blocked on:** line — a new or rewritten phase is pending, blocked on nothing"
  [ -z "${2:-}" ] || in_list "$source" "$2" \
    || fail PLAN_BAD_PHASE "$id has Source '$source' — a phase added this way is **Source:** ${2// / or }"
  [ "$goal" = 1 ] || fail PLAN_BAD_PHASE "$id has no **Goal:** line"
  [ "$acc" -ge 1 ] || fail PLAN_BAD_PHASE "$id has no acceptance line (\`- \` under **Acceptance:**)"
  [ "$decs" = - ] || obj_check_decided "$id" "$decs"
}

# obj_set_phase <P> <state> [<key> <value>] — rewrites phases.md with the
# phase's first State line set (added after the heading when absent)
# and, when given, its first <key> line set (added after its last
# non-blank line when absent).
obj_set_phase() {
  local content
  content="$(LC_ALL=C awk -v id="$1" -v state="$2" -v key="${3:-}" -v value="${4:-}" '
    function flush(    i, last, done_state, done_key) {
      if (!n) return
      last = 1
      for (i = 1; i <= n; i++) if (buf[i] ~ /[^ \t\r]/) last = i
      for (i = 2; i <= n; i++) {
        if (!done_state && index(buf[i], "**State:**") == 1) { buf[i] = "**State:** " state; done_state = 1 }
        else if (key != "" && !done_key && index(buf[i], "**" key ":**") == 1) { buf[i] = "**" key ":** " value; done_key = 1 }
      }
      print buf[1]
      if (!done_state) print "**State:** " state
      for (i = 2; i <= last; i++) print buf[i]
      if (key != "" && !done_key) print "**" key ":** " value
      for (i = last + 1; i <= n; i++) print buf[i]
      n = 0
    }
    /^## / { flush(); inside = (index($0, "## " id " — ") == 1) }
    inside { buf[++n] = $0; next }
    { print }
    END { flush() }' "$obj_dir/phases.md")" || fail WRITE_ERROR "could not read $obj_dir/phases.md"
  printf '%s\n' "$content" | obj_write "$obj_dir/phases.md" || exit 1
}

# obj_render_brief <P> — the phase's brief.md on stdout: its block
# without the State, Source, Commit, and Blocked on lines, then every
# referenced decision's entry.
obj_render_brief() {
  local d decs block
  obj_block "$obj_dir/phases.md" "$1" | LC_ALL=C awk '
    NR == 1 { sub(/^## /, "# "); print; next }
    /^\*\*(State|Source|Commit|Blocked on):\*\*/ { next }
    { print }'
  # shellcheck disable=SC2016  # the backticks are markdown, not expansions
  printf '\n**Objective:** `%s`\n\n## Decisions\n' "$obj_dir/objective.md"
  decs="$(obj_phase_field "$1" 4)"
  if [ "$decs" = - ] || [ -z "$decs" ]; then
    printf '\nNone.\n'
    return
  fi
  for d in $decs; do
    block="$(obj_block "$obj_dir/decisions.md" "$d")"
    [ -n "$block" ] || continue
    printf '\n%s\n' "$(printf '%s\n' "$block" | sed '1s/^## /### /')"
  done
}

# ---- follow-up ids --------------------------------------------------------

# obj_assign_awk — follow-up ids for the candidates on stdin (cand
# lines), against the ledger (ENVIRON OBJ_LEDGER, may be absent) and the
# ids report.md already lists (-v present, space-separated). A title and
# file the ledger knows keeps its id; a new one gets the highest id
# either holds + 1. Prints `L<TAB><ledger row>` per new id, `R<TAB><report
# line>` per raised id report.md does not list yet, then `ids<TAB><F4,
# F5>` and `added<TAB><n>`.
# shellcheck disable=SC2016  # awk fields, not expansions
obj_assign_awk='
BEGIN {
  FS = "\t"
  n = split(present, p, " ")
  for (i = 1; i <= n; i++) { inreport[p[i]] = 1; v = substr(p[i], 2) + 0; if (v > max) max = v }
  ledger = ENVIRON["OBJ_LEDGER"]
  while ((getline line < ledger) > 0) {
    split(line, f, "\t")
    if (f[1] !~ /^F[1-9][0-9]*$/) continue
    v = substr(f[1], 2) + 0; if (v > max) max = v
    k = f[4] "\t" f[5]
    if (!(k in known)) { known[k] = f[1]; row[f[1]] = line }
  }
  close(ledger)
}
$1 == "cand" {
  k = $3 "\t" $4
  if (k in known) id = known[k]
  else {
    id = "F" (++max)
    known[k] = id
    row[id] = id "\t" phase "\t" $2 "\t" $3 "\t" $4 "\t" $5
    print "L\t" row[id]
    added++
  }
  if (id in raised) next
  raised[id] = 1
  ids = ids (ids == "" ? "" : ", ") id
  if (id in inreport) next
  inreport[id] = 1
  split(row[id], f, "\t")
  print "R\t- " id " · " f[2] " · " f[3] " · " f[4] (f[6] != "" ? " — " f[6] : "")
}
END { print "ids\t" ids; print "added\t" added + 0 }'

# ---- the report -----------------------------------------------------------

# obj_report_awk — report.md (stdin) rewritten: the `**Deliverable
# state:**` line replaced by OBJ_STATE when set, and the `**Final
# verification:**` line by OBJ_VERIFY (added after the deliverable state
# when absent); under `## Phases` the
# `### <OBJ_ID> — ` entry replaced by OBJ_ENTRY, or OBJ_ENTRY appended;
# `## Blocked` replaced by OBJ_BLOCKED; OBJ_FOLLOWUPS appended under
# `## Follow-ups` (`None` dropped, or kept when it stays empty); missing
# sections added before `## Landing` (OBJ_LANDING when that is missing
# too). Other sections stay as they are. Values come through ENVIRON,
# never -v, so no escape in a title is interpreted.
# shellcheck disable=SC2016  # awk fields, not expansions
obj_report_awk='
function lines(s, arr) { return s == "" ? 0 : split(s, arr, "\n") }
function emit(s) { out[++on] = s }
function heading(h) {
  while (on > 0 && out[on] ~ /^[ \t\r]*$/) on--
  if (on > 0) emit("")
  emit(h)
  emit("")
}
function body(k, arr,    first, last, j, n) {
  first = 1; last = cnt[k]
  while (first <= last && L[k, first] ~ /^[ \t\r]*$/) first++
  while (last >= first && L[k, last] ~ /^[ \t\r]*$/) last--
  n = 0
  for (j = first; j <= last; j++) arr[++n] = L[k, j]
  return n
}
function put(arr, n,    j) { for (j = 1; j <= n; j++) emit(arr[j]) }
function raw(k,    b, n) { heading(head[k]); n = body(k, b); put(b, n) }
function phases(k,    b, n, j, start, stop) {
  heading(k ? head[k] : "## Phases")
  n = k ? body(k, b) : 0
  start = 0
  if (entry_n) for (j = 1; j <= n; j++) if (index(b[j], "### " id " — ") == 1) { start = j; break }
  if (!start) {
    put(b, n)
    if (entry_n && n) emit("")
    put(E, entry_n)
    return
  }
  for (stop = start + 1; stop <= n && b[stop] !~ /^### /; stop++) ;
  for (j = 1; j < start; j++) emit(b[j])
  put(E, entry_n)
  if (stop <= n) emit("")
  for (j = stop; j <= n; j++) emit(b[j])
}
function blocked(k) { heading(k ? head[k] : "## Blocked"); put(B, blocked_n) }
function followups(k,    b, n, j, m) {
  heading(k ? head[k] : "## Follow-ups")
  n = k ? body(k, b) : 0
  m = 0
  for (j = 1; j <= n; j++) if (b[j] !~ /^None[ \t\r]*$/) { emit(b[j]); m++ }
  put(F, fu_n)
  if (!m && !fu_n) emit("None")
}
# preamble(key, value) — the preamble line starting with key set to
# value, else value inserted after the line starting with `after`, else
# after the last non-blank preamble line.
function preamble(key, value, after,    i, at_line, last) {
  for (i = 1; i <= pn; i++) if (index(pre[i], key) == 1) { pre[i] = value; return }
  at_line = 0; last = 0
  for (i = 1; i <= pn; i++) {
    if (pre[i] ~ /[^ \t\r]/) last = i
    if (after != "" && index(pre[i], after) == 1) at_line = i
  }
  if (!at_line) at_line = last
  for (i = pn; i > at_line; i--) pre[i + 1] = pre[i]
  pre[at_line + 1] = value; pn++
}
function missing() {
  if (did_missing++) return
  if (!("## Phases" in at)) phases(0)
  if (!("## Blocked" in at)) blocked(0)
  if (!("## Follow-ups" in at)) followups(0)
}
BEGIN {
  entry_n = lines(ENVIRON["OBJ_ENTRY"], E)
  blocked_n = lines(ENVIRON["OBJ_BLOCKED"], B)
  fu_n = lines(ENVIRON["OBJ_FOLLOWUPS"], F)
  id = ENVIRON["OBJ_ID"]
  state = ENVIRON["OBJ_STATE"]
  verify = ENVIRON["OBJ_VERIFY"]
}
/^## / {
  s++; head[s] = $0; cnt[s] = 0
  name[s] = $0; sub(/[ \t\r]+$/, "", name[s])
  if (!(name[s] in at)) at[name[s]] = s
  next
}
{ if (s == 0) pre[++pn] = $0; else L[s, ++cnt[s]] = $0 }
END {
  if (state != "") preamble("**Deliverable state:**", state, "")
  if (verify != "") preamble("**Final verification:**", verify, "**Deliverable state:**")
  for (i = 1; i <= pn; i++) emit(pre[i])
  for (k = 1; k <= s; k++) {
    if (at[name[k]] != k) { raw(k); continue }
    if (name[k] == "## Landing") missing()
    if (name[k] == "## Phases") phases(k)
    else if (name[k] == "## Blocked") blocked(k)
    else if (name[k] == "## Follow-ups") followups(k)
    else raw(k)
  }
  if (!("## Landing" in at)) { missing(); heading("## Landing"); emit(ENVIRON["OBJ_LANDING"]) }
  while (on > 0 && out[on] ~ /^[ \t\r]*$/) on--
  for (i = 1; i <= on; i++) print out[i]
}'

# obj_blocked_body [<P> <D>] — `## Blocked`'s lines from phases.md, with
# <P> counted as blocked on <D> when given: `P<n> — waiting on D<n>:
# <question>` per blocked phase, or `None`.
obj_blocked_body() {
  local id state on question lines=""
  while IFS="$obj_tab" read -r id state _ on _; do
    [ -n "$id" ] || continue
    if [ "$id" = "${1:-}" ]; then state=blocked on="$2"; fi
    [ "$state" = blocked ] || continue
    question="$(obj_decision_question "$on")"
    lines="$lines$id — waiting on $on${question:+: $question}$obj_nl"
  done <<EOF
$obj_phases
EOF
  if [ -z "$lines" ]; then printf 'None'; else printf '%s' "${lines%"$obj_nl"}"; fi
}

# obj_write_report <entry-id> <entry> <blocked> <follow-up lines> <state-line>
# [<verification-line>] — report.md through obj_report_awk, created from
# its header when absent.
obj_write_report() {
  local report="$obj_dir/report.md" title source content
  if [ -f "$report" ]; then
    source="$(cat "$report")" || fail WRITE_ERROR "could not read $report"
  else
    title="$(LC_ALL=C awk '/^# / { print substr($0, 3); exit }' "$obj_dir/objective.md")"
    # shellcheck disable=SC2016  # the backticks are markdown, not expansions
    source="$(printf '# Report: %s\n\n**Deliverable:** `%s`\n**Deliverable state:** verified\n' \
      "${title:-$(obj_slug_of "$obj_dir")}" "$obj_branch")"
  fi
  content="$(printf '%s\n' "$source" | OBJ_ID="$1" OBJ_ENTRY="$2" OBJ_BLOCKED="$3" OBJ_FOLLOWUPS="$4" \
    OBJ_STATE="$5" OBJ_VERIFY="${6:-}" OBJ_LANDING="git merge --no-ff $obj_branch" LC_ALL=C awk "$obj_report_awk")" \
    || fail WRITE_ERROR "could not render $report"
  printf '%s\n' "$content" | obj_write "$report" || exit 1
}

# obj_reviewer — the reviewer the session ran: the pinned `reviewer=` in
# .orca/config, else preflight's detection.
obj_reviewer() {
  local pinned=""
  [ -f "$repo_root/.orca/config" ] \
    && pinned="$(grep '^reviewer=' "$repo_root/.orca/config" 2>/dev/null | sed 's/^reviewer=//' | sort -u)"
  case "$pinned" in
    codex | claude) printf '%s' "$pinned"; return ;;
  esac
  codex_binary_check
  if [ "$codex_binary_ok" -eq 1 ]; then printf 'codex'; else printf 'claude'; fi
}

# ---- phase subcommands ----------------------------------------------------

obj_plan_accept() { # <dir> [--check]
  local check=0 proposal heading id state on facts existing ids="$obj_nl" kept_ids="$obj_nl" next kept=0 unblocked=0 i=0 acc title
  local listed=() reset=()
  [ $# -eq 1 ] || { [ $# -eq 2 ] && [ "$2" = --check ]; } || fail BAD_ARGS "$objective_usage"
  [ $# -eq 2 ] && check=1
  obj_require_dir "$1"
  obj_require_live
  obj_load "$obj_dir"
  proposal="$obj_dir/plan/proposed.md"
  [ -f "$proposal" ] && [ ! -L "$proposal" ] || fail NO_PLAN "$proposal is missing or not a regular file — the planner writes it"
  obj_require_no_open
  obj_require_no_active

  existing="$obj_nl$(printf '%s\n' "$obj_phases" | cut -f1)$obj_nl"
  next=$(($(obj_max_phase) + 1))
  while IFS= read -r heading; do
    [ -n "$heading" ] || continue
    case "$heading" in
      "!$obj_tab"*) fail PLAN_BAD_ID "not a phase heading in plan/proposed.md: ${heading#!"$obj_tab"}" ;;
    esac
    case "$ids" in
      *"$obj_nl$heading$obj_nl"*) fail PLAN_BAD_ID "$heading appears twice in plan/proposed.md" ;;
    esac
    ids="$ids$heading$obj_nl"
    case "$existing" in
      *"$obj_nl$heading$obj_nl"*) ;;
      *)
        [ "$heading" = "P$next" ] \
          || fail PLAN_BAD_ID "new phase $heading does not continue the sequence — the next id is P$next"
        next=$((next + 1)) ;;
    esac
  done <<EOF
$(obj_headings "$proposal" P)
EOF

  while IFS="$obj_tab" read -r id state _ on _; do
    case "$state" in done | blocked) ;; *) continue ;; esac
    # A phase blocked on a decision that is now decided goes back through
    # planning: rewritten (or dropped) like a pending one.
    if [ "$state" = blocked ] && [ "$(obj_decision_state "$on")" = decided ]; then
      unblocked=$((unblocked + 1))
      case "$ids" in *"$obj_nl$id$obj_nl"*) reset+=("$id") ;; esac
      continue
    fi
    case "$ids" in
      *"$obj_nl$id$obj_nl"*) ;;
      *) fail PLAN_REWRITES_DONE "$id ($state) is missing from plan/proposed.md — done phases, and blocked ones whose decision is not decided, are copied verbatim" ;;
    esac
    [ "$(obj_block "$obj_dir/phases.md" "$id")" = "$(obj_block "$proposal" "$id")" ] \
      || fail PLAN_REWRITES_DONE "$id ($state) differs from phases.md — done phases, and blocked ones whose decision is not decided, are copied byte for byte"
    kept_ids="$kept_ids$id$obj_nl"
    kept=$((kept + 1))
  done <<EOF
$obj_phases
EOF

  # A restarted phase — pending with a base recorded by its earlier
  # attempt — keeps that base, so it runs before any phase that has none:
  # a phase committed in between would sit inside its base, where its
  # review and its commit check's resets would take it in.
  local fresh=""
  while IFS= read -r heading; do
    case "$kept_ids" in *"$obj_nl$heading$obj_nl"*) continue ;; esac
    if [ -f "$obj_dir/phases/$heading/base" ]; then
      [ -z "$fresh" ] \
        || fail PLAN_BAD_ORDER "$heading was attempted from a recorded base and must run before $fresh, which plan/proposed.md puts first — order it ahead of every phase that has not started"
    elif [ -z "$fresh" ]; then
      fresh="$heading"
    fi
  done <<EOF
$(obj_headings "$proposal" P)
EOF

  # A phase the proposal drops must have left nothing on the branch.
  while IFS="$obj_tab" read -r id state _; do
    [ -n "$id" ] || continue
    case "$kept_ids" in *"$obj_nl$id$obj_nl"*) continue ;; esac
    case "$ids" in *"$obj_nl$id$obj_nl"*) continue ;; esac
    obj_check_drop "$id"
  done <<EOF
$obj_phases
EOF

  while IFS= read -r facts; do
    [ -n "$facts" ] || continue
    id="${facts%%"$obj_tab"*}"
    case "$kept_ids" in *"$obj_nl$id$obj_nl"*) continue ;; esac
    obj_check_new_phase "$facts"
    i=$((i + 1))
    acc="$(printf '%s' "$facts" | cut -f6)"
    title="$(printf '%s' "$facts" | cut -f7)"
    listed+=("phase.$i.id=$id" "phase.$i.title.b64=$(b64_encode_str "$title")" "phase.$i.acceptance=$acc")
  done <<EOF
$(obj_phase_facts "$proposal")
EOF

  if [ "$check" -eq 0 ]; then
    for id in ${reset[@]+"${reset[@]}"}; do obj_supersede_rounds "$id"; done
    obj_write "$obj_dir/phases.md" <"$proposal"
    rm -f "$proposal" 2>/dev/null || fail WRITE_ERROR "installed phases.md but could not remove $proposal"
    obj_refresh_blocked
  fi
  emit_frame rc=0 "accepted=$([ "$check" -eq 1 ] && printf no || printf yes)" "kept=$kept" "unblocked=$unblocked" \
    "restarted=$(obj_join ${reset[@]+"${reset[@]}"})" "phases=$i" ${listed[@]+"${listed[@]}"}
}

# obj_check_drop <P> — a phase dropped from the plan after it was
# attempted (it has a phases/P<n>/ base or round state) may have left
# its unreviewed changes on the branch. The drop passes only when
# nothing since its base remains: the worktree clean (or absent) and the
# branch still at that base. Else PLAN_DROPS_WORK.
obj_check_drop() {
  local pdir="$obj_dir/phases/$1" base entry attempted=0 tip why=""
  [ -d "$pdir" ] || return 0
  for entry in base $obj_round_state superseded; do
    [ -e "$pdir/$entry" ] && attempted=1
  done
  [ "$attempted" -eq 1 ] || return 0
  base="$(head -1 "$pdir/base" 2>/dev/null)"
  if is_worktree_root "$obj_worktree"; then
    [ "$(obj_tree_state "$obj_worktree")" = clean ] || why="$obj_worktree has uncommitted changes (or no readable status)"
    tip="$(git -C "$obj_worktree" rev-parse -q --verify HEAD 2>/dev/null)"
  else
    tip="$(git --git-dir="$common_dir" rev-parse -q --verify "refs/heads/$obj_branch^{commit}" 2>/dev/null)"
  fi
  if [ -z "$why" ]; then
    if ! is_marker "$base"; then
      why="its base is not recorded"
    elif [ -n "$tip" ] && [ "$tip" != "$base" ]; then
      why="$obj_branch moved past its base ${base:0:7}"
    fi
  fi
  [ -z "$why" ] && return 0
  fail PLAN_DROPS_WORK "$1 was attempted and plan/proposed.md drops it, but its work may still be on the branch: $why — keep it, rewritten as a pending phase that finishes or undoes that work, or revert it first"
}

obj_join() { # <id...> — comma-separated, `-` when none
  local IFS=,
  [ $# -gt 0 ] && printf '%s' "$*" || printf -- '-'
}

# The round state of a phase's earlier attempt: everything the round
# engine, the implementer, and the brief left in phases/P<n>/, but base.
obj_round_state="reviews responses declines.md overrides action notes.md brief.md snapshot trees"

# obj_supersede_rounds <P> — a blocked phase replanned under its id starts
# over: its earlier attempt's round state moves to the first free
# phases/P<n>/superseded/<k>/, so `rounds next` answers `implement 0`
# against the new brief. base stays — the restarted phase is judged from
# the same commit.
obj_supersede_rounds() {
  local pdir="$obj_dir/phases/$1" entry k=1 found=0
  [ -d "$pdir" ] || return 0
  [ ! -L "$obj_dir/phases" ] && [ ! -L "$pdir" ] \
    || fail WRITE_ERROR "$pdir or its parent is a symlink — nothing installed"
  for entry in $obj_round_state; do
    { [ -e "$pdir/$entry" ] || [ -L "$pdir/$entry" ]; } && found=1
  done
  [ "$found" -eq 1 ] || return 0
  while [ -e "$pdir/superseded/$k" ]; do k=$((k + 1)); done
  mkdir -p "$pdir/superseded/$k" 2>/dev/null || fail WRITE_ERROR "could not create $pdir/superseded/$k"
  for entry in $obj_round_state; do
    if [ -e "$pdir/$entry" ] || [ -L "$pdir/$entry" ]; then
      mv "$pdir/$entry" "$pdir/superseded/$k/$entry" 2>/dev/null \
        || fail WRITE_ERROR "could not move $pdir/$entry aside — re-run to finish"
    fi
  done
}

# obj_refresh_blocked — report.md's `## Blocked` rewritten from the
# installed phases.md, when there is a report.
obj_refresh_blocked() {
  [ -f "$obj_dir/report.md" ] || return 0
  obj_phases="$(obj_entries "$obj_dir/phases.md" P)"
  obj_write_report "" "" "$(obj_blocked_body)" "" ""
}

obj_phase_add() { # <dir> <block-file>
  local file="$2" headings id want facts block current restarted
  obj_require_dir "$1"
  obj_require_live
  obj_load "$obj_dir"
  obj_require_no_active
  obj_require_no_open
  obj_require_no_blocked
  restarted="$(obj_restarted)"
  [ -z "$restarted" ] \
    || fail RESTART_PENDING "$restarted restarts from its earlier base and must run before any new phase — run it first (/orca:open); nothing added"
  [ -f "$file" ] || fail NO_FILE "$file is missing or not a regular file"
  headings="$(obj_headings "$file" P)"
  case "$headings" in
    '' | *"$obj_nl"*) fail PLAN_BAD_PHASE "$file must hold exactly one phase block — one \`## P<n> — <title>\` heading" ;;
    "!$obj_tab"*) fail PLAN_BAD_ID "not a phase heading in $file: ${headings#!"$obj_tab"}" ;;
  esac
  LC_ALL=C awk '/^## / { exit } /[^ \t\r]/ { bad = 1; exit } END { exit bad }' "$file" \
    || fail PLAN_BAD_PHASE "$file has text before its phase heading"
  id="$headings"
  want="P$(($(obj_max_phase) + 1))"
  facts="$(obj_phase_facts "$file")"
  obj_check_new_phase "$facts" "loop verify"
  block="$(obj_block "$file" "$id")"
  block="## $want — ${block#"## $id — "}"
  current="$(cat "$obj_dir/phases.md" 2>/dev/null)"
  printf '%s\n\n%s\n' "${current:-# Phases}" "$block" | obj_write "$obj_dir/phases.md" || exit 1
  emit_frame rc=0 "phase=$want" "acceptance=$(printf '%s' "$facts" | cut -f6)"
}

obj_phase_start() { # <dir> <P>
  local p="$2" pdir started=no base base_kept=yes brief restarted
  obj_require_dir "$1"
  obj_require_live
  obj_load "$obj_dir"
  obj_require_header
  obj_require_phase "$p"
  case "$obj_phase_state" in
    pending) started=yes ;;
    active) ;;
    *) fail PHASE_STATE "$p is $obj_phase_state — only a pending or active phase starts" ;;
  esac
  [ "$obj_active" -eq 0 ] || [ "$obj_active_id" = "$p" ] \
    || fail PHASE_ACTIVE "$obj_active_id is active — one phase runs at a time"
  # A new phase starts only when the pass may run; an active one resumes.
  if [ "$started" = yes ]; then
    obj_require_no_blocked
    obj_require_no_open
    if [ ! -f "$obj_dir/phases/$p/base" ]; then
      restarted="$(obj_restarted "$p")"
      [ -z "$restarted" ] \
        || fail RESTART_PENDING "$restarted restarts from its earlier base and runs before $p — start $restarted first; nothing done"
    fi
  fi
  pdir="$obj_dir/phases/$p"
  if [ -L "$obj_dir/phases" ] || [ -L "$pdir" ]; then
    fail WRITE_ERROR "$pdir or its parent is a symlink — nothing written"
  fi

  obj_arrive
  mkdir -p "$pdir" 2>/dev/null || fail WRITE_ERROR "could not create $pdir"
  base="$(head -1 "$pdir/base" 2>/dev/null)"
  if ! is_marker "$base" || ! git --git-dir="$common_dir" cat-file -e "$base^{commit}" 2>/dev/null; then
    base="$(git -C "$obj_worktree" rev-parse -q --verify HEAD 2>/dev/null)" \
      || fail GIT_ERROR "could not read HEAD in $obj_worktree"
    printf '%s\n' "$base" | obj_write "$pdir/base" || exit 1
    base_kept=no
  fi
  brief="$(obj_render_brief "$p")"
  printf '%s\n' "$brief" | obj_write "$pdir/brief.md" || exit 1
  # The round engine guards this work tree's tree (rounds.sh, the tree guard).
  printf '%s\n' "$obj_worktree" | obj_write "$pdir/worktree" || exit 1
  [ "$started" = yes ] && obj_set_phase "$p" active
  emit_frame rc=0 "dir=$pdir" "phase=$p" "started=$started" "base=$base" "base_kept=$base_kept" \
    "brief=$pdir/brief.md" "worktree=$obj_worktree" "branch=$obj_branch" "${obj_arrival_keys[@]}"
}

obj_phase_done() { # <dir> <P> <sha>
  local p="$2" sha short facts line key value decisions entry heading checks
  local rounds=0 chfixed=0 fixed_after="" declined="" pass="" commands="" verdict="" cands=""
  local assigned ledger_rows="" report_lines="" ids="" added=0 current state_line="" why final=verified
  obj_require_dir "$1"
  obj_require_live
  obj_load "$obj_dir"
  obj_require_phase "$p"
  [ "$obj_phase_state" = active ] || fail PHASE_STATE "$p is $obj_phase_state — only an active phase is done"
  sha="$(git --git-dir="$common_dir" rev-parse -q --verify "$3^{commit}" 2>/dev/null)" \
    || fail BAD_REF "'$3' does not name a commit in this repository"
  short="${sha:0:7}"

  # The round engine judges the phase's findings — one classification for
  # its gates and this report.
  [ -d "$obj_dir/phases/$p" ] || fail BAD_ROUNDS "$obj_dir/phases/$p/responses/round-0.json is missing — the phase never ran"
  facts="$(bash "$orca_scripts_dir/orca.sh" rounds facts "$obj_dir/phases/$p")" \
    || { printf '%s\n' "$facts" | grep '^FAIL:'; exit 1; }
  while IFS= read -r line; do
    key="${line%%"$obj_tab"*}" value="${line#*"$obj_tab"}"
    case "$key" in
      rounds) rounds="$value" ;;
      chfixed) chfixed="$value" ;;
      fixed_after) fixed_after="$value" ;;
      declined) declined="$value" ;;
      pass) pass="$value" ;;
      commands) commands="$value" ;;
      verdict) verdict="$value" ;;
      cand) cands="$cands$line$obj_nl" ;;
    esac
  done <<EOF
$facts
EOF

  assigned="$(printf '%s' "$cands" | OBJ_LEDGER="$obj_dir/followups" LC_ALL=C awk \
    -v phase="$p" -v present="$(obj_followups "$obj_dir" | tr '\n' ' ')" "$obj_assign_awk")"
  while IFS= read -r line; do
    key="${line%%"$obj_tab"*}" value="${line#*"$obj_tab"}"
    case "$key" in
      L) ledger_rows="$ledger_rows$value$obj_nl" ;;
      R) report_lines="$report_lines$value$obj_nl" ;;
      ids) ids="$value" ;;
      added) added="$value" ;;
    esac
  done <<EOF
$assigned
EOF

  decisions="$(obj_phase_field "$p" 4)"
  if [ "$decisions" = - ] || [ -z "$decisions" ]; then decisions=none; else decisions="$(commas "$decisions")"; fi
  if [ "$pass" = false ]; then checks=fail; else checks=pass; fi
  heading="$p — $obj_phase_title — $short"
  entry="### $heading$obj_nl- Decisions: $decisions"
  entry="$entry$obj_nl- Review: $(obj_reviewer), $rounds round$([ "$rounds" = 1 ] || printf s), Critical/High fixed $chfixed"
  [ -z "$fixed_after" ] || entry="$entry$obj_nl- Fixed after the last review: $fixed_after"
  [ -z "$declined" ] || entry="$entry$obj_nl- Declined: $declined"
  [ -z "$ids" ] || entry="$entry$obj_nl- Follow-ups: $ids"
  entry="$entry$obj_nl- Checks: $checks${commands:+ — $commands}"

  current="$(obj_header "$obj_dir/report.md" "Deliverable state")"
  case "$current" in
    unverified*) final=unverified ;;
    *)
      case "$verdict" in
        checks) why="with checks failing" ;;
        unfixed) why="with Critical/High findings unresolved" ;;
        unreviewed) why="unreviewed" ;;
        *) why="" ;;
      esac
      if [ -n "$why" ]; then
        state_line="**Deliverable state:** unverified — $p ($short) committed $why"
        final=unverified
      fi ;;
  esac

  if [ -n "$ledger_rows" ]; then
    printf '%s\n%s' "$(cat "$obj_dir/followups" 2>/dev/null)" "$ledger_rows" \
      | sed '/^$/d' | obj_write "$obj_dir/followups" || exit 1
  fi
  obj_write_report "$p" "$entry" "$(obj_blocked_body)" "${report_lines%"$obj_nl"}" "$state_line"
  obj_set_phase "$p" 'done' Commit "$sha"
  emit_frame rc=0 "phase=$p" "commit=$sha" "headline.b64=$(b64_encode_str "$heading")" \
    "followups_added=$added" "deliverable_state=$final" "report=$obj_dir/report.md"
}

obj_phase_block() { # <dir> <P> <D>
  local p="$2" d="$3" waiting
  [[ $d =~ ^D[1-9][0-9]*$ ]] || fail BAD_ARGS "'$d' is not a decision id (D<n>)"
  obj_require_dir "$1"
  obj_require_live
  obj_load "$obj_dir"
  obj_require_phase "$p"
  [ "$obj_phase_state" = active ] || fail PHASE_STATE "$p is $obj_phase_state — only an active phase blocks"
  [ -n "$(obj_decision_state "$d")" ] || fail NO_DECISION "$d is not in decisions.md — write the open decision first"
  obj_write_report "$p" "" "$(obj_blocked_body "$p" "$d")" "" ""
  obj_set_phase "$p" blocked "Blocked on" "$d"
  waiting="$(printf '%s\n' "$obj_phases" | LC_ALL=C awk -F'\t' -v id="$p" '
    $1 == id { after = 1; next }
    after && $2 != "active" && $2 != "done" && $2 != "blocked" && $1 != "" { n++ }
    END { print n + 0 }')"
  emit_frame rc=0 "phase=$p" "blocked_on=$d" "waiting=$waiting"
}

obj_verify_done() { # <dir> pass|fail [<why>]
  local result="$2" why="${3:-}" tip short line current state_line="" final=verified
  case "$result" in
    pass) [ -z "$why" ] || fail BAD_ARGS "a pass takes no reason — $objective_usage" ;;
    fail) [ -n "$why" ] || fail BAD_ARGS "a fail names what failed — $objective_usage" ;;
    *) fail BAD_ARGS "'$result' is not pass or fail — $objective_usage" ;;
  esac
  obj_require_dir "$1"
  obj_require_live
  obj_load "$obj_dir"
  obj_require_header
  [ "$obj_total" -gt 0 ] || fail NO_PHASE "no phase in phases.md — nothing to verify"
  [ "$obj_done" -eq "$obj_total" ] \
    || fail PHASE_STATE "$obj_done of $obj_total phases done — the final verification runs once every phase is done"
  tip="$(git --git-dir="$common_dir" rev-parse -q --verify "refs/heads/$obj_branch^{commit}" 2>/dev/null)" \
    || fail GIT_ERROR "could not read the tip of $obj_branch"
  short="${tip:0:7}"
  why="$(printf '%s' "$why" | LC_ALL=C tr '\001-\037' ' ')"
  line="**Final verification:** $result after $obj_last_id ($short)${why:+ — $why}"
  current="$(obj_header "$obj_dir/report.md" "Deliverable state")"
  case "$current" in
    unverified*) final=unverified ;;
    *)
      if [ "$result" = fail ]; then
        state_line="**Deliverable state:** unverified — final verification failed after $obj_last_id ($short): $why"
        final=unverified
      fi ;;
  esac
  obj_write_report "" "" "$(obj_blocked_body)" "" "$state_line" "$line"
  emit_frame rc=0 "result=$result" "phase=$obj_last_id" "tip=$tip" \
    "deliverable_state=$final" "report=$obj_dir/report.md"
}

# ---- archive and unarchive ------------------------------------------------

obj_archive_ref() { # the hidden ref an archived objective's tip is kept under
  printf 'refs/orca/archive/%s' "$(obj_slug_of "$obj_dir")"
}

# obj_require_unowned — another session's live or unknown claim refuses;
# this session's own, a stale one, or none passes.
obj_require_unowned() {
  local session verdict
  [ -e "$obj_dir/owner" ] || return 0
  session="$(lease_owner_field "$obj_dir/owner" session)"
  [ -n "$session" ] && [ "$session" = "${CLAUDE_CODE_SESSION_ID:-}" ] && return 0
  verdict="$(lease_verdict "$obj_dir/owner")"
  [ "${verdict%%"$obj_tab"*}" = stale ] && return 0
  fail OWNED_ELSEWHERE "$obj_dir is owned by session ${session:-unknown} ($(printf '%s' "$verdict" | tr '\t' ' ')) — archive it from that session, or once it has ended; nothing done"
}

# obj_branch_holders — the worktrees with the objective's branch checked
# out, one path per line.
obj_branch_holders() {
  git --git-dir="$common_dir" worktree list --porcelain 2>/dev/null | LC_ALL=C awk -v b="refs/heads/$obj_branch" '
    /^worktree / { path = substr($0, 10) }
    $0 == "branch " b { print path }'
}

# obj_check_footprint <tree> <caller-cwd> — refuses (WORKTREE_IN_USE,
# nothing done) a worktree that is not this repository's, is on another
# branch, holds the caller's current directory, or a branch checked out
# elsewhere.
obj_check_footprint() {
  local tree="$1" here="$2" common head real holder
  if [ "$tree" != absent ]; then
    common="$(git -C "$obj_worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    [ -n "$common" ] && [ "$(canonicalize "$common")" = "$(canonicalize "$common_dir")" ] \
      || fail WORKTREE_IN_USE "$obj_worktree is not a worktree of this repository — nothing done"
    head="$(git -C "$obj_worktree" symbolic-ref -q --short HEAD 2>/dev/null)"
    [ "$head" = "$obj_branch" ] \
      || fail WORKTREE_IN_USE "$obj_worktree has ${head:-a detached HEAD} checked out, not $obj_branch — nothing done"
    real="$(canonicalize "$obj_worktree")"
    case "$here/" in
      "$real/"*) fail WORKTREE_IN_USE "this shell stands inside $obj_worktree — cd out of it first; nothing done" ;;
    esac
  fi
  while IFS= read -r holder; do
    [ -n "$holder" ] || continue
    [ "$tree" != absent ] && [ "$(canonicalize "$holder")" = "$(canonicalize "$obj_worktree")" ] && continue
    fail WORKTREE_IN_USE "$obj_branch is checked out at $holder — nothing done"
  done <<EOF
$(obj_branch_holders)
EOF
}

# obj_salvage — the worktree's uncommitted work as one wip: commit on the
# branch. Sets obj_salvaged to committed | clean.
obj_salvage() {
  local msg
  msg="wip: $(obj_slug_of "$obj_dir") — set aside, partial work"
  is_banned "$msg" && msg="wip: set aside, partial work"
  git -C "$obj_worktree" add -A >/dev/null 2>&1 \
    || fail GIT_ERROR "git add -A failed in $obj_worktree — nothing removed"
  if git -C "$obj_worktree" diff --cached --quiet 2>/dev/null; then
    obj_salvaged=clean
    return
  fi
  git -C "$obj_worktree" commit -q -m "$msg" >/dev/null 2>&1 \
    || fail GIT_ERROR "the wip commit failed in $obj_worktree — nothing removed"
  obj_salvaged=committed
}

# obj_unverify_salvage — uncommitted work about to be salvaged into a
# wip: commit is checked and reviewed only by a phase whose base predates
# it: an unfinished phase with a recorded phases/P<n>/base. With none,
# no review will ever see it, so the deliverable state goes down first
# (report.md created when absent), before the commit, so a re-run after
# a failure part way still finds it down.
obj_unverify_salvage() {
  local id state current
  while IFS="$obj_tab" read -r id state _; do
    [ -n "$id" ] && [ "$state" != 'done' ] || continue
    [ -f "$obj_dir/phases/$id/base" ] && return 0
  done <<EOF
$obj_phases
EOF
  current="$(obj_header "$obj_dir/report.md" "Deliverable state" 2>/dev/null)"
  case "$current" in unverified*) return 0 ;; esac
  obj_write_report "" "" "$(obj_blocked_body)" "" \
    "**Deliverable state:** unverified — uncommitted work set aside by archive outside any phase, never checked or reviewed"
}

obj_archive() { # <dir> [--abandon] [--note <text>]
  local abandon=0 note="" tree ref tip state why out here current
  local worktree_out=absent branch_out=absent ref_out=-
  # Before obj_require_dir, which enters the repository root.
  here="$(pwd -P)"
  obj_require_dir "$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --abandon) abandon=1; shift ;;
      --note)
        [ $# -ge 2 ] || fail BAD_ARGS "$objective_usage"
        note="$(printf '%s' "$2" | tr '\t\r\n' '   ')"
        shift 2 ;;
      *) fail BAD_ARGS "$objective_usage" ;;
    esac
  done
  # Held to the end, and taken before any check: no claim lands between
  # the gate and the owner's removal, and an archive that waited behind
  # another sees its `archived` file.
  obj_lock
  if [ -e "$obj_dir/archived" ]; then
    emit_frame rc=0 "dir=$obj_dir" "state=$(obj_archived_state "$obj_dir")" \
      "tip=$(lease_owner_field "$obj_dir/archived" tip)" already=yes
    return
  fi
  obj_load "$obj_dir"
  obj_require_header
  obj_require_unowned
  tree="$(obj_tree_state "$obj_worktree")"
  obj_check_footprint "$tree" "$here"
  ref="$(obj_archive_ref)"

  # An archive interrupted after its decision: `archiving` holds the
  # state, tip, and note it settled on, and the tip is safe at the ref;
  # finish the removals from there, never judging the gate again.
  if [ -e "$obj_dir/archiving" ]; then
    state="$(lease_owner_field "$obj_dir/archiving" state)"
    tip="$(lease_owner_field "$obj_dir/archiving" tip)"
    note="$(lease_owner_field "$obj_dir/archiving" note)"
    [ "$tip" = - ] && tip=""
    obj_salvaged=resumed
    if [ "$tree" = dirty ]; then
      obj_unverify_salvage
      obj_salvage
    fi
    # A branch still there may have moved since (a salvage just now, a
    # hand commit): its tip is what the ref keeps and the marker records.
    current="$(git --git-dir="$common_dir" rev-parse -q --verify "refs/heads/$obj_branch^{commit}" 2>/dev/null)" || current=""
    if [ -n "$current" ] && [ "$current" != "$tip" ]; then
      tip="$current"
      git --git-dir="$common_dir" update-ref "$ref" "$tip" 2>/dev/null \
        || fail GIT_ERROR "could not keep $tip at $ref — re-run to finish"
      printf 'state=%s\ndate=%s\ntip=%s\nnote=%s\n' "$state" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$tip" "$note" \
        | obj_write "$obj_dir/archiving" || exit 1
    fi
    [ -z "$tip" ] || ref_out="$ref"
    obj_finish_archive
    return
  fi

  if [ "$tree" != dirty ] && [ "$tree" != unknown ] && obj_landed; then
    state=landed
  elif [ "$abandon" -eq 1 ]; then
    state=abandoned
  else
    if [ "$tree" = dirty ]; then
      why="$obj_worktree has uncommitted changes"
    elif [ "$tree" = unknown ]; then
      why="git status failed in $obj_worktree"
    else
      why="$obj_branch has not landed in the trunk"
    fi
    fail NOT_LANDED "$why — pass --abandon to set it aside (uncommitted work salvaged, the tip kept, restorable)"
  fi

  obj_salvaged=no-worktree
  [ "$tree" = dirty ] && obj_unverify_salvage
  [ "$tree" = absent ] || obj_salvage
  tip="$(git --git-dir="$common_dir" rev-parse -q --verify "refs/heads/$obj_branch^{commit}" 2>/dev/null)" \
    || tip="$(git --git-dir="$common_dir" rev-parse -q --verify "$ref^{commit}" 2>/dev/null)" \
    || tip=""
  if [ -n "$tip" ]; then
    git --git-dir="$common_dir" update-ref "$ref" "$tip" 2>/dev/null \
      || fail GIT_ERROR "could not keep $tip at $ref — nothing removed"
    ref_out="$ref"
  fi
  # The decision is recorded before anything is removed: a re-run after
  # an interruption finishes from it, and open refuses meanwhile.
  printf 'state=%s\ndate=%s\ntip=%s\nnote=%s\n' "$state" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${tip:--}" "$note" \
    | obj_write "$obj_dir/archiving" || exit 1
  obj_finish_archive
}

# obj_finish_archive — the removals and the final marker, from `archiving`
# (obj_archive's locals in scope): the worktree, the branch, the owner,
# then `archiving` becomes `archived`. Each step re-checks what is there,
# so a re-run picks up wherever an interruption left it.
obj_finish_archive() {
  local out
  if is_worktree_root "$obj_worktree"; then
    out="$(git --git-dir="$common_dir" worktree remove "$obj_worktree" 2>&1)" \
      || fail GIT_ERROR "could not remove $obj_worktree: $(printf '%s' "$out" | tr '\n' ' ' | tail -c 300) — re-run to finish"
    worktree_out=removed
  fi
  git --git-dir="$common_dir" worktree prune 2>/dev/null
  if git --git-dir="$common_dir" rev-parse -q --verify "refs/heads/$obj_branch" >/dev/null 2>&1; then
    out="$(git --git-dir="$common_dir" branch -D "$obj_branch" 2>&1)" \
      || fail GIT_ERROR "could not delete $obj_branch: $(printf '%s' "$out" | tr '\n' ' ' | tail -c 300) — re-run to finish"
    branch_out=removed
  fi
  rm -f "$obj_dir/owner" 2>/dev/null || fail WRITE_ERROR "could not clear $obj_dir/owner"
  obj_write "$obj_dir/archived" <"$obj_dir/archiving" || exit 1
  rm -f "$obj_dir/archiving" 2>/dev/null || fail WRITE_ERROR "could not remove $obj_dir/archiving"
  emit_frame rc=0 "dir=$obj_dir" "state=$state" "tip=${tip:--}" "ref=$ref_out" "salvaged=$obj_salvaged" \
    "worktree=$worktree_out" "branch=$branch_out" already=no
}

obj_unarchive() { # <dir>
  local ref tip recorded current branch_out=none marker
  obj_require_dir "$1"
  # Under the lock, like archive: never interleaved with one.
  obj_lock
  marker="$(obj_marker "$obj_dir")"
  if [ -z "$marker" ]; then
    emit_frame rc=0 "dir=$obj_dir" restored=no
    return
  fi
  obj_load "$obj_dir"
  [ -n "$obj_branch" ] || fail BAD_DIR "$obj_dir/objective.md lacks its Branch header line"
  ref="$(obj_archive_ref)"
  recorded="$(lease_owner_field "$marker" tip)"
  tip="$(git --git-dir="$common_dir" rev-parse -q --verify "$ref^{commit}" 2>/dev/null)" || tip=""
  if [ -z "$tip" ] && is_marker "$recorded"; then
    tip="$(git --git-dir="$common_dir" rev-parse -q --verify "$recorded^{commit}" 2>/dev/null)" \
      || fail NO_ARCHIVE "neither $ref nor the recorded tip $recorded is in this repository — nothing restored"
  fi
  if [ -n "$tip" ]; then
    current="$(git --git-dir="$common_dir" rev-parse -q --verify "refs/heads/$obj_branch^{commit}" 2>/dev/null)" || current=""
    if [ -z "$current" ]; then
      git --git-dir="$common_dir" branch "$obj_branch" "$tip" >/dev/null 2>&1 \
        || fail GIT_ERROR "could not recreate $obj_branch at $tip — nothing restored"
      branch_out=restored
    elif [ "$current" = "$tip" ]; then
      branch_out=exists
    else
      fail BRANCH_EXISTS "$obj_branch exists at $current, not the archived tip $tip — nothing restored"
    fi
  fi
  rm -f "$obj_dir/archived" "$obj_dir/archiving" 2>/dev/null || fail WRITE_ERROR "could not remove $marker"
  [ -z "$tip" ] || git --git-dir="$common_dir" update-ref -d "$ref" 2>/dev/null || true
  emit_frame rc=0 "dir=$obj_dir" restored=yes "branch=$branch_out" "tip=${tip:--}"
}

objective_cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$objective_cmd" in
  new)
    [ $# -eq 3 ] || [ $# -eq 5 ] || fail BAD_ARGS "$objective_usage"
    obj_new "$@" ;;
  open)
    [ $# -ge 1 ] || fail BAD_ARGS "$objective_usage"
    obj_open "$@" ;;
  current)
    [ $# -eq 1 ] || fail BAD_ARGS "$objective_usage"
    obj_current "$@" ;;
  idle)
    [ $# -eq 1 ] || fail BAD_ARGS "$objective_usage"
    obj_idle "$@" ;;
  list)
    [ $# -ge 1 ] || fail BAD_ARGS "$objective_usage"
    obj_list "$@" ;;
  digest)
    [ $# -eq 1 ] || fail BAD_ARGS "$objective_usage"
    obj_digest "$@" ;;
  plan-accept)
    [ $# -ge 1 ] || fail BAD_ARGS "$objective_usage"
    obj_plan_accept "$@" ;;
  phase-add)
    [ $# -eq 2 ] || fail BAD_ARGS "$objective_usage"
    obj_phase_add "$@" ;;
  phase-start)
    [ $# -eq 2 ] || fail BAD_ARGS "$objective_usage"
    obj_phase_start "$@" ;;
  phase-done)
    [ $# -eq 3 ] || fail BAD_ARGS "$objective_usage"
    obj_phase_done "$@" ;;
  phase-block)
    [ $# -eq 3 ] || fail BAD_ARGS "$objective_usage"
    obj_phase_block "$@" ;;
  verify-done)
    [ $# -eq 2 ] || [ $# -eq 3 ] || fail BAD_ARGS "$objective_usage"
    obj_verify_done "$@" ;;
  archive)
    [ $# -ge 1 ] || fail BAD_ARGS "$objective_usage"
    obj_archive "$@" ;;
  unarchive)
    [ $# -eq 1 ] || fail BAD_ARGS "$objective_usage"
    obj_unarchive "$@" ;;
  *) fail BAD_ARGS "$objective_usage" ;;
esac
