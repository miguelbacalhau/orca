# Objectives

An objective is a long-lived unit of work: discussed into decisions, planned into sequential phases, built phase by phase on one branch in one worktree, and re-opened for more whenever there is more to do. Every piece of its state is a file under `.orca/objectives/`, so any session can carry it forward. It is the second way to drive work with orca, beside [a run](anatomy.md).

```text
/orca:new <idea>     → files → worktree → provisioning ∥ research → discussion → decisions
                     → phase plan → plan review → confirm → phase loop → report
/orca:open [obj]     → digest → discussion · planning · phase loop, by state
/orca:loop [change]  → one small phase added to this session's objective, run now
/orca:archive        → retire it, landed or abandoned; --undo restores it
```

Objectives need the bare-repo-with-worktrees layout but not bypass mode: the session runs `orca.sh` through its own Bash tool, and the verb hook plays no part.

- [The files](#the-files)
- [Derived states](#derived-states)
- [Ownership](#ownership)
- [Creating one: `/orca:new`](#creating-one-orcanew)
- [Planning and plan review](#planning-and-plan-review)
- [The phase loop](#the-phase-loop)
- [Blocks and replanning](#blocks-and-replanning)
- [The report and follow-ups](#the-report-and-follow-ups)
- [Re-opening: `/orca:open`](#re-opening-orcaopen)
- [One more phase: `/orca:loop`](#one-more-phase-orcaloop)
- [Review and PR](#review-and-pr)
- [Archive and undo](#archive-and-undo)
- [The objective band](#the-objective-band)
- [Stage agents](#stage-agents)

## The files

```text
<repo-root>/.orca/objectives/<YYYYMMDD-HHMMSS>-<slug>/
├── objective.md           # title, header lines, idea, outcome, non-goals, constraints
├── decisions.md           # D-entries — written by the session (discussion and loop rulings)
├── phases.md              # P-entries — installed by plan-accept / phase-add, states set by the verbs
├── report.md              # rendered by phase-done and phase-block
├── followups              # the ledger behind the report's follow-up ids
├── owner                  # the session driving it
├── archiving              # an archive's decision, written before anything is removed
├── archived               # present once archived
├── plan/
│   ├── proposed.md        # the planner's proposal, until accepted
│   └── review-<n>.json    # plan-review findings, one per planning pass
└── phases/P<n>/
    ├── brief.md           # rendered by phase-start from the phase and its decisions
    ├── base               # HEAD when the phase first started
    ├── notes.md           # the implementer's working notes — the handoff on resume
    ├── reviews/round-<N>.json     # reviewer findings, N from 1
    ├── responses/round-<N>.json   # implementer dispositions, N from 0 (0 = the initial implement)
    ├── trees              # the tree each review and response was of, and recorded drifts
    ├── worktree           # the work tree the round engine guards
    ├── declines.md        # settled declines (user rulings)
    ├── overrides          # recorded checks overrides and stall continues
    ├── action             # the round engine's last answer
    ├── snapshot           # the tree the commit must hold, and the review round it was taken at
    └── superseded/<k>/    # an earlier attempt's round state, once a replan restarted the phase
```

The worktree is `<repo-root>/orca-<slug>` on branch `feature/<slug>` — the run layout, so a slug a run already holds is refused.

Every file is line-oriented: the verbs read only `## ` headings and `**Key:**` lines, never prose. Only an entry's first line of each key counts, and its value is the first word (`**Source:**` takes the whole line).

### `objective.md`

```markdown
# <title>

**Base:** `<branch the objective builds on>`
**Base commit:** `<sha>`
**Branch:** `feature/<slug>`
**Worktree:** `<repo-root>/orca-<slug>`

## Idea
## Outcome
## Non-goals
## Constraints
```

`objective new` writes the header lines, which belong to the verbs, and the idea under `## Idea` (`--idea`). The discussion writes the rest; the first line under `## Outcome` is the one-sentence outcome the digest shows.

### `decisions.md`

```markdown
## D3 — <the question, one line>
**State:** open | decided | deferred
**Source:** discussion | F4 | P2 (implementer question) | P2 round 3 (disputed finding) | P2 round 3 (stall) | P2 (infeasible)
**Options:** <A> · <B>
**Decision:** <the chosen option>      (decided only)
**Why:** <the reason>
```

Ids continue the sequence and are never reused. A state that is neither `decided` nor `deferred` counts as open. A `deferred` decision is left out of the current pass: no phase realizes it.

### `phases.md`

```markdown
## P2 — <title>
**State:** pending | active | done | blocked
**Source:** plan | loop
**Decisions:** D1, D3 | none
**Goal:** <one paragraph>
**Acceptance:**
- <checkable from the worktree>
**Commit:** <sha>          (done only)
**Blocked on:** D7         (blocked only)
```

A state that is not `active`, `done`, or `blocked` counts as pending. The file's order is the execution order. The next id is past the highest in `phases.md` and among the `phases/P<n>/` directories, so an id that ever held state is never given again.

### `owner` and `archived`

`owner` holds `session=`, `host=`, `pid=`, `pidstart=`, and `taken=` lines. `archived` holds `state=landed|abandoned`, `date=`, `tip=`, and `note=`.

## Derived states

An objective's state is never stored. `objective list` derives it from the files, taking the first rule that holds:

| State | When |
|---|---|
| `archived` | the `archived` file says `landed` |
| `abandoned` | the `archived` file says `abandoned` |
| `active` | a phase is `active` — in flight, or interrupted |
| `planning` | `plan/proposed.md` exists and no decision is open |
| `blocked` | a phase is `blocked` |
| `discussing` | a decision is open, or there are no phases |
| `ready` | a phase is `pending` |
| `landed` | every phase done, and the branch moved past its base commit and is merged into the trunk |
| `idle` | every phase done |

`objective list <repo> [--all]` prints one line per objective — `OBJECTIVE:`, the directory, slug, state, `open:<n>` decisions, `pending:<n>` and `blocked:<n>` phases, `followups:<n>` open, and `owner:<verdict>` — oldest first, archived and abandoned ones only with `--all`.

## Ownership

One session drives an objective at a time. `objective open` claims it by writing `owner` with this session's `CLAUDE_CODE_SESSION_ID`, its pid, and its host, judged by the same lease verdicts as a run:

| Owner | `open` |
|---|---|
| none | claimed |
| this session | kept (claimed afresh when its recorded pid is gone) |
| another session, live or unknown (another host) | `OWNED_ELSEWHERE` — nothing done |
| another session, provably dead | `OWNER_STALE`; taken over with `--steal` |

The check and the write run under a lock — the ref `refs/orca/claim/<dir name>`, naming the holding process and changed only by compare-and-swap — so of two sessions opening one objective at once exactly one claims it and the other gets `OWNED_ELSEWHERE`; a lock still held after a short wait is `CLAIM_BUSY`, and one whose process is gone is taken over by exactly one contender. `objective archive` and `objective unarchive` hold the same lock, taken before any check, so an open that waited behind an archive finds it archived. A claim releases any other objective this session owned. `objective current <repo>` names the objective this session owns, or `none`. A session without a session id cannot claim (`NO_SESSION_ID`). `/clear` starts a new session id, so `/orca:loop` refuses until `/orca:open` claims the objective again.

## Creating one: `/orca:new`

1. **Create.** The slug comes from the idea — a provisional `objective-<h4>` when the idea is too vague to name. Before anything else happens, the session runs `objective new <repo> <slug> <base> --idea -` with the idea on stdin: that writes the files, the idea verbatim under `## Idea`, and creates `feature/<slug>` at the base commit — the one point where a slug can collide. The base is the branch the user names, else the trunk. It refuses a conventional checkout (`NOT_BARE` → `/orca:init`), an existing branch (`BRANCH_EXISTS`), objective (`OBJECTIVE_EXISTS`), or worktree path (`WORKTREE_EXISTS`). A slug a branch or worktree already holds is retried once with a `-<h4>` suffix; an existing objective with the slug is offered to the user to continue instead.
2. **Open and check the reviewer.** The session runs `objective open <dir>`: it claims the objective and creates the worktree off the base commit, provisioning nothing, so it returns at once. In the worktree it then runs `config validate` and the preflight's `REVIEWER:`/`CODEX:` lines itself — seconds, a few lines — and holds the reviewer for planning and the loop; re-checking after `/orca:doctor` or `/orca:config` is that call again.
3. **Provision and research, in the background.** `orca:provision` runs `orca.sh provision` on the worktree (secrets, then `.orca/setup`) as a warm-up, so a cold install overlaps the discussion, and returns one compact object — the setup output never enters the session. `orca:research` explores the code at the base: the current checkout when it is clean at the base commit, else the objective's worktree, which already exists. A setup or Codex problem is reported in a line when it lands — with an offer of `/orca:doctor` — and never pauses the discussion.
4. **Discuss.** Once research returns, the session opens with a reflection of the idea against the code and asks two or three questions at a time. It writes `objective.md`'s sections and one `decisions.md` entry per question as each is raised (`open`) or settled (`decided`), never one document at the end. The research report is never written into the files.
5. **Hand off.** When the user says go and no decision is open, planning runs. A user who stops leaves the objective `discussing`; `/orca:open` picks it up.

## Planning and plan review

Planning turns the decided work into sequential phases and ends at one confirmation.

1. **Plan.** `orca:phases` explores the worktree read-only and writes `plan/proposed.md` — the whole next `phases.md`. Done phases, and blocked phases whose decision is still undecided, are copied byte for byte; a blocked phase whose decision is now decided is rewritten as pending under its own id; pending phases may be kept, rewritten, reordered, or dropped; new phases continue the id sequence. A phase that was attempted cannot be dropped while its work may remain — the worktree dirty, or the branch past that phase's base (`PLAN_DROPS_WORK`): it is kept, rewritten to finish or undo that work, or reverted first.
2. **Check.** `objective plan-accept <dir> --check` validates the proposal without installing it. A broken rule is typed — `PLAN_REWRITES_DONE`, `PLAN_BAD_ID`, `PLAN_BAD_PHASE`, `PLAN_UNDECIDED`, `PLAN_DROPS_WORK`, plus `DECISION_OPEN`, `PHASE_ACTIVE`, `NO_PLAN` — and goes back to the planner once.
3. **Review.** Secrets are stripped from the worktree, a fresh `orca:phases-review-codex` or `orca:phases-review-claude` (the configured or detected reviewer) attacks the proposal against `objective.md`, `decisions.md`, and the code at the worktree's HEAD, and secrets are put back. Findings land at `plan/review-<n>.json`. Critical/High findings get exactly one revise round by the planner, then the check again — no re-review. A reviewer that fails twice fails open: the plan goes to the confirmation unreviewed, with the reason.
4. **Confirm.** The user sees the proposed phases (id, title, acceptance count, from the check's frame), the planner's notes, and the review's remaining findings by severity and title (`rounds summary`). Yes → `objective plan-accept <dir>` installs it as `phases.md` and removes the proposal; a blocked phase the plan keeps starts over (below). Changes → back to the discussion, written as decisions, then a new pass. Not now → the proposal stays and the objective lists as `planning`.

## The phase loop

The session runs pending phases in file order, one at a time. It never edits code and never judges a round: after every implementer turn and every review, `orca.sh rounds next <phase-dir>` reads the phase directory and prints the one next action.

1. **Start.** The session runs `objective phase-start`: the worktree is arrived in, `base` is recorded (kept on a re-start, so a resumed phase keeps its base), `brief.md` is rendered from the phase block and every decision it lists, and the phase becomes `active`. Then `orca:provision` provisions the worktree — again, after a warm-up at open, since phases change dependencies; it waits for a warm-up still in flight, one provisioning at a time — and the implementer starts once it has returned. A provisioning failure is relayed and the implementer told; it does not stop the phase.
2. **Implement and review, round by round.** One `orca:loop-implement` agent per phase, kept alive by `SendMessage` until the phase's commit stands, runs the repository's full checks after every pass, writes `responses/round-<N>.json` every turn (checks, one disposition per finding, `followups`, status), and keeps `notes.md` current. Each review round strips secrets, spawns a fresh `orca:loop-review-codex` or `orca:loop-review-claude` with the brief, the rounds directory — so it verifies earlier `fixed` findings and skips settled declines — and the phase's base, writes `reviews/round-<N>.json`, and puts secrets back. The reviewer's subject is everything since the base, committed or not (`git diff <base>` plus untracked files).
3. **Commit.** `loop snapshot` records the tree to commit in `snapshot`, against the latest review round, and returns that same tree until a new review round exists — across commit-only retries and a resumed session. The commit request names the round being committed, and the implementer answers it in that round's response file, so a failed commit hook is that round's red checks and the review after its fix is the next round. The implementer writes one Conventional Commit whose body carries a `- chose X over Y: <why>` line per decision the phase realizes, and `loop check` judges it: `accepted`, `needs_commit`, `incomplete`, `diverged`, a banned message reset softly (`violation_reset`), or content that differs from the snapshot reset the same way (`content_reset`, then checks and a review round again).
4. **Done.** `objective phase-done <dir> <P> <sha>` marks the phase done and renders its report entry and follow-ups. The next pending phase starts with a fresh implementer.

`rounds next`'s actions:

| Action | The session |
|---|---|
| `implement 0` | spawns the implementer with the brief |
| `review N` | runs review round N |
| `fix N` | sends a fix request for review N, a re-review to follow |
| `fix-minor N` | sends a fix request for review N's Medium/Low findings, no re-review to follow |
| `fix-checks N` | sends a checks request; when the same failure persists, asks the user to carry on with it red (`rounds record … checks-override`) or stop |
| `ask-questions N` | puts the implementer's questions to the user and sends the answer back |
| `ask-disputes N` | puts each disputed Critical/High to the user: decline it (`rounds record … decline`) or have it fixed |
| `stalled N` | from round 2, the gating count did not shrink or a `fixed` finding came back: the user chooses continue (`rounds record … continue N`), commit anyway, or stop |
| `infeasible N` | tells the user why; the phase blocks on a new open decision |
| `drifted N` | the work tree changed since round N's last file (edits while the session was stopped): sends a revalidation request for round N — checks and dispositions over the current tree — after which a review follows before any commit |
| `commit N` | takes the snapshot and sends the commit request |

The round engine guards the tree: it records the tree each review was asked for (`trees`, against the phase's `worktree` file), and each response carries the tree its checks were of (`tree`, from `rounds tree`), and a work tree that no longer matches the latest one is `drifted N` until the implementer answers that round again over the tree as it is, and a review is required before the round commits. Findings routed to `another work item` never gate a round and never reach the implementer as work; an unknown severity gates. There is no round cap — the stall rule is the brake. A malformed or missing round file is a typed failure (`BAD_JSON`, `BAD_ROUNDS`), never a guessed action. The verb's full rules are in its header, `scripts/verbs/rounds.sh`.

Every ruling the user makes on the spot — an answer, a dispute settled either way, a stall's continue or commit anyway — is recorded twice: by `rounds record` where one applies, and as a decided entry in `decisions.md`.

## Blocks and replanning

At every ask, the user may **decide later**. The session then writes the question as an `open` decision and runs `objective phase-block <dir> <P> D<n>`: the phase becomes `blocked`, the report's `## Blocked` names it, and **the pass stops** — later phases wait too. `phase-start` enforces it: no pending phase starts while any phase is blocked (`PHASE_BLOCKED`) or a decision is open (`DECISION_OPEN`), and `phase-add` is refused while one is blocked. An `infeasible` implementer blocks the phase the same way.

The next `/orca:open` routes to the discussion with the blocking decision first. Once it is decided, the blocked phase and the pending ones go back through planning — the planner rewrites the blocked phase as pending under its id, the plan is reviewed, and the user confirms it — before the loop runs again.

A blocked phase the accepted plan keeps **starts over**, and runs before every pending phase that has not started, since it keeps its earlier base — `plan-accept` refuses another order (`PLAN_BAD_ORDER`), and `phase-start` and `phase-add` refuse to start or add anything else first (`RESTART_PENDING`): `plan-accept` moves its earlier attempt's round state — reviews, responses, declines, overrides, action, notes, brief — to `phases/P<n>/superseded/<k>/`, keeping `base`, so the round engine answers `implement 0` against the new brief. The fresh implementer is pointed at the superseded notes, since the attempt's changes may still be in the worktree.

## The report and follow-ups

`report.md` is written only by `phase-done` and `phase-block`:

```markdown
# Report: <title>

**Deliverable:** `feature/<slug>`
**Deliverable state:** verified | unverified — P2 (a1b2c3d) committed <why>

## Phases

### P2 — <title> — a1b2c3d
- Decisions: D1, D3
- Review: codex, 3 rounds, Critical/High fixed 4
- Fixed after the last review: <titles>        (omitted when none)
- Declined: <title — reason; …>                (omitted when none)
- Follow-ups: F4, F5                           (omitted when none)
- Checks: pass | fail — <commands>

## Blocked

None | P4 — waiting on D7: <question>

## Follow-ups

- F4 · P2 · out of scope · <title> — <file>
- F5 · P2 · left unfixed (Medium) · <title> — <the implementer's reason>
- F6 · P3 · gap · <title> — <why it was left>

## Landing

git merge --no-ff feature/<slug>
```

- **Deliverable state** starts `verified` and only goes down: a phase committed with red checks in its latest response, with gating findings left in its last review (a stall's commit anyway), or with no review turns it `unverified`, naming the phase. An `unverified` line is never touched again.
- **Follow-ups** come from each phase: the last review's `another work item` findings, Medium/Low findings the implementer left declined, and the implementer's `followups[]` (gaps it left on purpose). Ids come from the `followups` ledger: a title and file already listed keeps its id, and no id is given twice. A follow-up is **taken** — no longer counted open — once a decision's `**Source:**` cites it (`**Source:** F4`); the list itself is never edited.

## Re-opening: `/orca:open`

`/orca:open [slug]` lists the objectives and offers the newest — or one this session already owns — never forcing the choice. Another live session's objective is never taken; a stale owner is taken over only on the user's yes (`--steal`). An archived or abandoned one is restored with `/orca:archive --undo` first.

`objective open` claims it and arrives in its worktree, re-adding it when it is gone; a worktree at the saved path on another branch, detached, or not this repository's is `WORKTREE_MISMATCH` (as in `phase-start`). The session checks the config and the reviewer in the worktree, then reads `objective digest <dir>` — at most 40 lines, whatever the objective's size: title and outcome, state, worktree (clean, dirty, absent) and branch, decision counts with the open ones listed, one line per phase (the active one always, then the other unfinished ones), the active phase's last action, open follow-ups by count, and the last report entry's heading. The digest is the session's whole starting context; an entry is read only when the conversation turns to it. A route into the phase loop (`active`, or `ready` and run now) provisions nothing at open — the loop's phase start does it; every other route spawns `orca:provision` in the background as a warm-up.

Routing by state:

| State | Goes to |
|---|---|
| `discussing`, `blocked` | the discussion, open decisions first — a blocking one before anything else |
| `planning` | the planning gate, from where it stopped |
| `ready` | one confirmation, then the phase loop |
| `active` | the phase loop: a fresh implementer resumes the active phase from its notes, its diff, and its latest round |
| `idle` | what's next: open follow-ups, new decisions, `/orca:review`, `/orca:pr`, `/orca:archive` |
| `landed` | `/orca:archive`, or more work as `idle` |

## One more phase: `/orca:loop`

`/orca:loop [instructions]` works only in a session that owns an objective (`objective current`). It refuses with no objective (pointing at `/orca:new` and `/orca:open`), while a phase is `active` or `blocked`, or while a decision is open. Otherwise the session writes one phase block from the conversation — title, goal, one to three acceptance lines, `**Source:** loop` — without asking the user to confirm it, adds it with `objective phase-add <dir> <block-file>` (no planner, no plan review), and runs that one phase through the phase loop. Work it cannot describe in a few lines goes to the objective's discussion instead.

## Review and PR

- **`/orca:review`** opens an objective's branch like a run's; addressing its comments needs this session to own the objective with no phase active, blocked, or restarted and waiting (`objective idle`, else it points at `/orca:open`): `review discover` follows the deliverable with an `OBJECTIVE_DIR:` line from its `objective.md`, report or not, and a `REPORT:` line once it has a report. Review rounds are recorded in that report under `## Review rounds`, which phases leave as they are. A comment that changes the objective's direction is not addressed in review; it becomes a decision at the next `/orca:open`.
- **`/orca:pr`** publishes an objective whose report says `verified`, with `## Blocked` reading `None` and no phase pending, blocked, or active. The description is composed from `report.md`, `objective.md`'s outcome and idea, and the decided entries of `decisions.md`.
- **`/orca:status`** lists objectives in their own group, each naming its next command; archived and abandoned ones are counted, not listed.

## Archive and undo

`/orca:archive` retires any objective, one confirmation each; the directory always stays.

- **Landed** — `objective archive <dir>`: the worktree and branch are removed.
- **Not landed (abandon)** — the confirmation names what is set aside: commits ahead of the trunk, a dirty tree, open follow-ups, pending or blocked phases. `objective archive <dir> --abandon [--note <reason>]` commits uncommitted work as one `wip: <slug> — set aside, partial work` commit — first turning the report's `**Deliverable state:**` to `unverified` when no unfinished phase has a recorded base whose review would cover that work — keeps the branch tip at `refs/orca/archive/<slug>` (a hidden ref `git gc` keeps), removes the worktree and the branch, removes `owner`, and writes `archived`.
- Refused while another session's claim reads live or unknown (`OWNED_ELSEWHERE`), and when the worktree is in use — this shell's current directory, another branch checked out, or the branch checked out elsewhere (`WORKTREE_IN_USE`). Without `--abandon`, an objective that is not landed, or whose worktree is dirty, is `NOT_LANDED`. The decision is written to `archiving` before the worktree and branch are removed; an archive interrupted after that is refused by `open` (`ARCHIVED`), finished by re-running `/orca:archive` from that record, or undone directly. An archived objective is a no-op.
- **`--undo`** — `objective unarchive <dir>` recreates the branch from the kept ref (or the recorded tip), removes `archived`, and drops the ref. The next `/orca:open` re-adds the worktree. A salvaged `wip:` commit stays on the branch; an active phase resumes against its recorded base, so its reviews still cover the salvaged work.

## The objective band

The session that owns an objective shows it live above the prompt, in the slot the [run band](anatomy.md#the-run-band) uses:

```text
── orca ─ rate-limit-public-api · discussing · 3 decided · 2 open ──────
  D4  Per-key or per-IP limits?            ○ open
  D5  Where do 429 bodies come from?       ○ open

── orca ─ rate-limit-public-api · P2/4 · 2 follow-ups ──────────────────
  P1  Token bucket + store                 ✓ done a1b2c3d
  P2  Middleware on public routes          ● review r2
  P3  429 responses + headers              ◌ pending
  P4  Docs                                 ◌ pending
```

- **Header** by state: `discussing · <n> decided · <n> open`; `reviewing plan`, then `planning` once a review of the current pass is written; `P<n>/<total>` while a phase is active; `blocked on D<n>`; `ready · <n> pending`; `idle · <n> phases done`; open follow-ups appended when there are any.
- **Rows** while discussing are the open decisions (deferred ones dimmed); otherwise one row per phase. The active phase's tail comes from its `action` file: `implement`, `review rN`, `fix rN (<n> gating)`, `fix minor`, `fix checks`, `waiting on you: dispute rN | stall rN | questions | infeasible`, `committing`.
- **What it follows:** the objective whose `owner` names this session, found by walking up from the session's directory to `.orca/objectives/`. It looks on session start, on every prompt, and after the session's own `objective open` call, then reads that objective's files every 1.5 s. A live run this session launched takes the slot over.
- **When it goes:** at session end; when the directory, or this session's claim on it, disappears; when it is archived or landed; and when it has sat `idle` through three of your prompts. A new phase brings it back.
- Collapse it with `[-]` or ctrl+x ctrl+a — the same collapse as the run band. It is read-only (`hooks/objective-band.tsx`, logic in `hooks/derive-objective.ts`).

## Stage agents

| Stage | Role | Model | Effort |
|---|---|---|---|
| `provision` | Provisions the worktree after the session's `objective open` (a warm-up) or `phase-start` (`orca.sh provision`: secrets, then `.orca/setup`); names a setup failure's cause in one line | sonnet | low |
| `phases` | Read-only planner: writes `plan/proposed.md` from the objective, its decisions, and the code | fable | high |
| `phases-review-codex` | Courier driving the Codex plan review via `orca.sh codex` | sonnet | medium |
| `phases-review-claude` | Performs the plan review itself | opus | high |
| `research` | Explores what the idea touches, before the discussion | fable | high |
| `loop-implement` | Implements, fixes, and commits one phase, kept alive across its rounds | opus | high |
| `loop-review-codex` | Courier driving one round's Codex review via `orca.sh codex` | sonnet | medium |
| `loop-review-claude` | Performs one round's review itself | opus | high |

The reviewer is the configured `reviewer`, else the detected one — the same resolution as a run. Only `research` takes `.orca/config` overrides.
