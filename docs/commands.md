# Commands

Every user-facing skill in detail. The [README](../README.md#commands) has the one-paragraph versions.

**Run, objective, or loop.** A run (`/orca:run`) takes one confirmed brief to a finished deliverable autonomously: a spec, parallel work items, one report, and `/orca:retry` and `/orca:followup` for what comes after. An objective (`/orca:new`, then `/orca:open` in any later session) is for work you expect to come back to, with you deciding along the way: a recorded discussion, a reviewed plan of sequential phases on one branch, each phase reviewed round by round, and more decisions and phases whenever there is more to do. `/orca:loop` adds one small phase to the objective your session has open; outside an objective it refuses. A small fix on a run's deliverable is done by hand, or through `/orca:review`'s address flow.

- [`/orca:run`](#orcafeature-idea)
- [`/orca:new`](#orcanew-idea)
- [`/orca:open`](#orcaopen-objective)
- [`/orca:review`](#orcareview-branch)
- [`/orca:pr`](#orcapr-run)
- [`/orca:retry`](#orcaretry-run)
- [`/orca:followup`](#orcafollowup-run)
- [`/orca:loop`](#orcaloop-instructions)
- [`/orca:status`](#orcastatus-run)
- [`/orca:archive`](#orcaarchive-run-or-objective)
- [`/orca:council`](#orcacouncil-question-or-instruction)
- [`/orca:init`](#orcainit-path-or-clone-url)
- [`/orca:doctor`](#orcadoctor)
- [`/orca:config`](#orcaconfig-assignments--reset)

## `/orca:run <idea>`

A dispatcher over `.orca/` state. Triage offers the first match, never forcing it:

1. **An interrupted run** — a run directory whose `spec.md` records a workflow runId but has no `report.md`. Offers to resume from the journal: completed work replays instantly, only in-flight and remaining work runs live.
2. **A queued brief** — anything at the top level of `.orca/feat-briefs/`. Offers to run one, or to interview a new idea instead.
3. **Nothing waiting** — interviews the idea into a brief, restates it once with the trunk and reviewer, and asks: run it now, leave it queued, or revise?

### The interview

Turns a rough idea into a brief at `.orca/feat-briefs/<timestamp>-<slug>.md`. It first researches the subsystems the idea touches through the `orca:research` agent, then opens by reflecting the idea against the system as it exists. It is adversarial about scope: it pushes back, hunts for unstated non-goals, and makes you resolve ambiguities now, because the brief is the *entire* intent the run acts on.

A brief records **outcome**, **features**, **non-goals**, **inputs & outputs**, **constraints**, any direction decisions settled in the interview (binding on the spec), and two run controls:

- **Doubt rule** — on an ambiguity, prefer the smaller interpretation and cut scope (`prefer-smaller-scope`, default) or the more complete one (`prefer-complete`).
- **Breakdown checkpoint** — review the spec and work breakdown once before any code (`review-once`), or run straight through (`straight-through`, default).

The brief is *what and why*, never *how*: no work breakdown, interfaces, or file ownership — those come from the spec stage. Top-level briefs are ready; park unfinished ones in `.orca/feat-briefs/drafts/`. One brief is one run.

### The run

You are asked exactly:

1. **One confirmation** of the restated brief, plus the trunk branch. This authorizes everything that follows. Fresh from the interview, it is the interview's closing run-now answer, so you approve a new brief once; a queued brief is restated, age-checked, and confirmed when its run starts.
2. **One optional checkpoint**, only if the brief opted in: approve the spec and work breakdown before any code.

After that nothing asks you anything. Ambiguities resolve against the spec and the doubt rule; what cannot be resolved becomes a `blocked` item in `report.md`, with the options you must choose between. See [Anatomy of a run](anatomy.md).

## `/orca:new <idea>`

Starts an objective under `.orca/objectives/<YYYYMMDD-HHMMSS>-<slug>/` — see [Objectives](objectives.md) for its files and states. Requires the bare layout; bypass mode is not needed.

1. **Create, first.** Before any question or research, the session names a slug from the idea (a provisional `objective-<h4>` when it is too vague to name) and runs `objective new` against the trunk, or the branch you name. That writes the objective's files and creates `feature/<slug>` at the base commit — nothing else. A slug a branch or worktree already holds gets a `-<h4>` suffix; an objective with the same slug is offered for `/orca:open` instead.
2. **Set up and research.** In the background, `orca:worktree` claims the objective for this session and creates and provisions `<repo-root>/orca-<slug>` on `feature/<slug>` (secrets, then `.orca/setup`), then checks the config and the reviewer; `orca:research` explores the code the idea touches, at the objective's base — the current checkout when it is clean at the base commit, else the objective's worktree once it exists. A setup or reviewer problem is reported in a line when it lands, with an offer of `/orca:doctor`, and never holds up the discussion.
3. **Discuss.** Once research returns, the session reflects the idea against the system as it is and asks two or three questions at a time, pushing back on scope. It writes the outcome, non-goals, and constraints into `objective.md`, and every question into `decisions.md` as it is raised (`open`) or settled (`decided`); a question you want to leave out of this pass is `deferred`.
4. **Plan.** When you say go and no decision is open, `orca:phases` writes a proposed phase plan, `objective plan-accept --check` validates it, and the reviewer (`orca:phases-review-codex` or `-claude`) attacks it; Critical/High findings get one revise round, without a re-review. You see the phases and the remaining findings and confirm once.
5. **Loop.** Each phase runs in order in the objective's worktree: one `orca:loop-implement` agent kept alive for the phase implements, fixes every round, and commits; a fresh reviewer attacks each round; `orca.sh rounds next` decides every next step until a round has no Critical/High. Disputes, stalls, and the implementer's questions come to you and are recorded as decisions; one you want to decide later blocks the phase and stops the pass. Each finished phase adds its entry and follow-ups to the objective's `report.md`.

Stopping anywhere is safe: the files say where the objective is, and `/orca:open` continues it.

## `/orca:open [objective]`

Re-opens an objective in this session and continues it from where its files say it stands.

1. **Pick.** `objective list` — the newest is offered, or one this session already owns; a slug or fragment argument picks one. An objective another live session owns is never taken; one whose owner is provably gone is taken over only on your yes. An archived or abandoned one is restored with `/orca:archive --undo` first.
2. **Open.** `orca:worktree` claims it, arrives in its worktree (re-adding it when it is gone), provisions it, and checks the reviewer.
3. **Digest.** `objective digest` prints at most 40 lines — title and outcome, state, worktree and branch, decisions with the open ones listed, one line per phase, the active phase's last action, open follow-ups, the last report entry. That is the session's whole starting context; entries are read one at a time when the conversation reaches them.
4. **Route.** `discussing` or `blocked` → the discussion, open decisions first; `planning` → the planning gate, where it stopped; `ready` → one confirmation, then the loop; `active` → the loop, with a fresh implementer resuming the interrupted phase from its notes, its diff, and its latest round; `idle` → what's next (open follow-ups, new decisions, `/orca:review`, `/orca:pr`, `/orca:archive`); `landed` → `/orca:archive`, or more work. Once a decision that blocked a phase is settled, the pending and blocked phases are replanned and confirmed before the loop runs again.

## `/orca:review [branch]`

Opens a finished deliverable — a run's, or an objective's done phases — in *your* editor before you land it. It discovers unmerged `feature/<slug>` branches (one → opens it; several → asks; a missing integration worktree → offers to re-add it) and starts a review session on the integration worktree: file list, side-by-side merge-base diffs, your LSP and colors.

- **nvim** — a new tmux window in your current session running [orca.nvim](https://github.com/miguelbacalhau/orca.nvim)'s `:OrcaReview`. Quit nvim (`:qa`) and the window closes, returning you to where you invoked it.
- **vscode** — [orca.vscode](https://github.com/miguelbacalhau/orca.vscode)'s review session, opened via `code --open-url`. Close the review window when done.

Without tmux (nvim path) or without a companion installed, it prints the command to run instead (`cd <worktree> && nvim "+OrcaReview"`, `cd <worktree> && code .` plus the palette command, or a `git difftool` fallback).

The `editor` (`nvim`|`vscode`|`none`) and `terminal` (`tmux`|`none`) config keys control this; see [Configuration](../README.md#configuration).

### Review comments round-trip

Comments you leave in the review persist to `.orca/review-notes/<key>.json` (`<key>` is the sanitized branch name). On an objective's deliverable, addressing them needs this session to own the objective with no phase mid-loop (`objective idle`); otherwise the skill points at `/orca:open` first.

On the nvim path the skill waits on the tmux window. When you quit nvim it reads the file and lays out each open comment with what it intends to do — fix (with a one-line approach), answer, decline with reasoning, or defer — and **asks** before acting. You can correct the plan, address now, resume the review, or leave the comments for later.

On consent, the `orca:address` agent works in the integration worktree: change requests are fixed with tests and committed (under the same no-attribution rules as run commits), questions are answered from the code. It writes `status`/`resolution` back into the notes file, and the next `:OrcaReview` shows them inline. Each round is appended to the run's or objective's `report.md` under `## Review rounds`; a round whose verification fails marks the deliverable `unverified`. Editing a resolved comment re-opens it for the next round.

Comments left from vscode, a print-only session, or a dead session are picked up by the next `/orca:review`, which reports "N unaddressed comments". Both sides fail loudly on a notes schema version they don't support (`/orca:doctor`'s nvim check diagnoses the mismatch).

## `/orca:pr [run]`

Publishes a **delivered-but-unlanded run or objective** (newest by default, or the one the argument names) as a GitHub pull request via `gh`. Every fact in the PR body comes from the run's `report.md` and `brief.md`, or the objective's `report.md`, `objective.md`, and decided `decisions.md` entries; for a branch neither produced, use plain `gh pr create`.

Guards: the report must say `**Deliverable state:** verified` and `## Blocked` must be `None`; an objective must also have no phase pending, blocked, or active. Anything else is refused with a pointer to `/orca:run`'s resume, `/orca:retry`, or `/orca:open`.

- **New PRs are always drafts.** Mark it ready on GitHub after your own pass. Refreshing an existing PR never changes its draft status.
- **Body shape:** the repo's `pull_request_template.md` if it has one; otherwise a plain-language summary of the problem and the change, **What changed**, **Testing**, and **How it works** / **Notes** only when needed — 200–350 words, grouped by outcome rather than by work item, with no orca vocabulary (item IDs, hashes, run paths, `/orca:*` pointers).
- **No attribution** in the title or body, enforced by the same marker scan as run commits.
- **One confirmation:** you see the exact title, body, base, and head before the push and PR creation. Re-running on an existing PR refreshes it.

It never merges, never edits the report, never touches the integration worktree.

## `/orca:retry [run]`

Finishes a finished run's unmet items **inside the same run** — same run directory, same spec, same integration branch.

1. Picks a finished run with leftovers (newest by default, or the argument).
2. Audits it with `orca:audit`: the report's claims reconciled against the spec's work breakdown and git.
3. Resolves every blocked item's recorded decision with you. This interview is required — a retry without new input would block the same way. You can also restore items the run cut autonomously, and a resolution may let a retried item amend code an earlier item already merged.
4. Appends your resolutions to `spec.md` as binding Decisions bullets, archives the superseded plans, reviews and report in place (`plans/<ID>.round<N>.md`, `reviews/prev<N>/`, `report.round<N>.md`), and relaunches the work loop over the unmet items only. Surviving item branches (including salvaged WIP commits) are resumed, not restarted.

The rewritten report keeps the whole-run picture, with a Prior rounds section. An *interrupted* run goes to `/orca:run`'s resume; a `clean` run has nothing to retry.

## `/orca:followup [run]`

Turns a finished run's *optional follow-ups* — deferred findings, known gaps, improvements reviews flagged without blocking — into a new brief.

It audits the run with `orca:audit` (which items verifiably merged, whether the deliverable branch still exists or already landed) and names any discrepancies. You choose which follow-ups ride along; the rest stay deferred in the old report. The result is a standard brief in `.orca/feat-briefs/`, building on the integration branch or the trunk depending on whether the deliverable landed, with the prior spec's Interfaces and Decisions as binding inputs. `/orca:run` runs it like any other brief; this skill never launches a run.

A run with unmet items is pointed at `/orca:retry` first; a run whose follow-up brief already exists is surfaced, not duplicated.

## `/orca:loop [instructions]`

Adds one small phase to the objective this session has open and runs it now — no planner, no plan review, no confirmation. It works only inside an objective: in a session that has not run `/orca:new` or `/orca:open` (or has since been cleared) it refuses and points at them. Bypass mode is not needed.

1. **Gate.** `objective current` names the objective this session owns. It refuses with none, while one of its phases is active (`/orca:open` continues it) or blocked, or while a decision is open (settle it in the discussion first).
2. **Phase.** The session writes a phase entry from the conversation and the argument — title, goal, one to three acceptance lines, `**Source:** loop` — without asking you to confirm it, and adds it with `objective phase-add`. It is the reviewer's yardstick and the implementer's test contract. Work it cannot state in a few lines without asking is offered to the objective's discussion instead.
3. **Run.** That one phase goes through the objective's phase loop, exactly as a planned phase does: `orca:worktree` starts it, one `orca:loop-implement` agent implements it, runs the repository's checks, fixes every round, and commits; each round a fresh `orca:loop-review-codex` or `orca:loop-review-claude` reviews the uncommitted change with secrets stripped; `orca.sh rounds next` decides every next step until a round has no Critical/High. Findings outside the change become follow-ups and never block it; Medium/Low findings left in the clean round are fixed without a re-review. A disputed Critical/High, a stall (from round 2, a Critical/High count that didn't shrink or a fixed finding back), a persistent checks failure, and the implementer's questions come to you, and your ruling is recorded as a decision — or, if you decide later, the phase blocks on an open one.
4. **Commit.** The implementer writes one Conventional Commit; `orca.sh loop check` judges it against a snapshot taken just before. A commit holding anything else (a commit hook that rewrote code) is undone with its changes staged and goes through checks and review again; a message naming Claude, AI, agents, or orca, or carrying an attribution trailer, is undone and rewritten; a commit that missed files is sent back.
5. **Report.** `objective phase-done` adds the phase's entry and follow-ups to the objective's `report.md`. Committing with red checks or a stall's commit anyway marks the deliverable `unverified`.

The phase's files live in the objective's `phases/P<n>/` and stay; an interrupted phase is resumed by `/orca:open`.

## `/orca:status [run]`

A strictly read-only dashboard answering "where was I?". It joins `.orca/` state (interrupted and unlaunched runs, finished runs and their leftovers, queued briefs, objectives by derived state) with git (unmerged deliverables, kept item branches, leftover `orca-*` worktrees, orphans from abandoned runs) into one screen grouped by next action, each state naming the skill that owns it. It prescribes cleanup commands where deletion is provably safe but never runs them. Objectives get their own group, each with the command that continues it; an objective's branch and worktree are never listed as cleanup, and archived or abandoned objectives are counted, not listed. With an argument, only the matching run or objective is shown.

Readiness questions — tooling, config, secrets, setup — belong to `/orca:doctor`, not here.

## `/orca:archive [run or objective]`

Retires finished runs from triage and removes their git footprint. The run directory and report always stay.

A run is archivable only when its report exists, `## Blocked` is `None`, no live lease owns it, **every `feature/<slug>` branch attributed to it (integration and item) is merged into the trunk** or already gone, and every `orca-*` worktree it left is clean, unlocked, not your current directory, and not holding a run branch checked out elsewhere.

`triage archive --scan` reports each finished run as `ARCHIVABLE:` (with one `PRUNE:` line per worktree and branch it would remove) or `KEPT:` with a reason: `NOT_LANDED`, `WORKTREE_IN_USE`, `NOT_CLEAN`, `LEASE_LIVE`, `NO_TRUNK`. The skill shows both and asks before removing anything.

Archiving re-checks the gate, removes the worktrees and then the branches (never `--force`), and writes an `archived` marker beside `report.md` recording each removal and branch tip. An archived run shows as one `ARCHIVED:` line in triage, stays addressable by fragment, and `/orca:followup` can still pick it. `--undo` removes the marker and recreates the branches at their recorded tips.

**Objectives** retire through `objective archive`, never the run gate, and may be retired landed or not; their directory always stays. Each gets its own confirmation:

- **Landed** (every phase done, the branch merged into the trunk) — its worktree and branch are removed.
- **Abandoned** (anything else, only when you name it) — the confirmation names what is set aside: commits ahead of the trunk, a dirty tree, open follow-ups, pending or blocked phases. On yes, uncommitted work becomes one `wip:` commit, the branch tip is kept at `refs/orca/archive/<slug>` (safe from `git gc`), the worktree and branch are removed, the owner claim is cleared, and an `archived` file records the state, tip, and your optional one-line reason.
- An objective another live session owns is refused. `--undo <objective>` recreates the branch from the kept tip and removes the `archived` file; the next `/orca:open` re-adds the worktree.

## `/orca:council <question or instruction>`

One read-only question, several independent answers, one merged result. Not part of a run, and never edits or saves anything.

The argument is either a self-contained question, which goes to the seats exactly as typed, or an instruction that points at the current conversation (`/orca:council validate the retry design we just settled`). For an instruction, your session composes the question plus a context brief — your stated premises, its own conclusions as claims to check (left out when you ask for the question alone), and what was rejected — and shows you both. The council convenes only once you approve them. The seats see the brief labelled as the session's summary, not your words.

1. **Seating.** `orca.sh council resolve` reads the `council` key — absent means `opus,fable,astra` — and checks Codex. With the default roster, a Codex that is missing or below the minimum version vacates the `astra` seat and the council sits with the rest; a **pinned** `astra` with Codex missing fails `NO_CODEX`. An installed Codex that is unauthenticated or lacks the `codex exec` flags orca drives fails `CODEX_UNUSABLE` either way — fix it with `/orca:doctor`.
2. **Deliberation.** Every seat gets the identical prompt — the question and any approved brief, plus the shared rules: read-only, one assertion per claim, each claim anchored to `path:line` or a command's output — in a fresh context, in parallel, blind to the others. Claude seats are `orca:council` agents on their seat's model; the `astra` seat is Codex itself, driven by the `orca:council-codex` courier through `orca.sh codex --model gpt-6-astra --schema council` with a 9-minute cap. A seat that dies or times out is reported, not fatal.
3. **Merge.** Your session — not another agent — groups claims that say the same thing, counts each group's support (`2/3 — opus, astra`), opens the evidence on both sides of every contradiction and settles it against the code, and never drops a single-seat claim for being outvoted. With a brief, each of the session's conclusions is scored upheld, refuted, or unaddressed by the seats. The answer leads with who sat, then the direct answer, the scored brief (if any), the claims, the contradictions, and the merged open questions.

```bash
/orca:config council=opus,fable,astra      # the default, pinned (astra now required)
/orca:config council=opus,opus,opus        # three draws from one model
/orca:config council=default               # back to the detected default
```

## `/orca:init [path or clone URL]`

One-time, consent-per-step setup of the bare-repo-with-worktrees layout:

- **New repository** — bare init plus a default-branch worktree.
- **Clone a URL** — bare clone, fetch refspec fix (bare clones fetch nothing without it), default-branch worktree.
- **Convert an existing checkout** in place — `.git` becomes `.bare`, tracked files move into a `<branch>/` worktree, and **untracked and ignored files (`.env`s, caches) are carried over**. Every path changes, so re-point editors and terminals. Layout-only (no history, refs, or remotes touched) and reversible until the final cleanup step, which is confirmed separately. Requires a clean tree, no linked worktrees, and no submodules.

Every case ends by **root-linking** the default worktree's `.claude` and `CLAUDE.md` at the repo root, so a session started there gives every stage agent the checkout's conventions. It then offers (never defaults) `/orca:doctor`'s [provisioning pass](worktrees.md#provisioning).

Machine-gate failures (Codex, the review timeout) are `/orca:doctor`'s.

## `/orca:doctor`

Interactive, consent-per-step readiness on two axes: **machine and session tooling**, and **repo readiness** (whether a fresh worktree arrives provisioned). Diagnosis is free; it fixes only what was flagged:

- **Codex missing or stale** — points at the official install (`brew install codex` or release binaries; never npm).
- **Not authenticated** — `codex login`, verified with `codex login status`.
- **`codex exec` interface moved** — names the missing flags and whether the fix is a Codex upgrade or an orca update; offers `reviewer=claude` to unblock.
- **`BASH_MAX_TIMEOUT_MS` unset** — writes it into a settings `env` block (project or user level, your choice).
- **A stale orca status line** — older versions offered a `statusLine` block calling the retired `orca.sh statusline`; doctor offers to remove it. A status line that doesn't mention orca is never touched.

It reports the resolved reviewer. With codex absent it explains that runs use the Claude reviewer and offers to pin either choice. A codex gate failing while the reviewer is codex is always a failure to fix, never a silent switch.

Inside a repository it reads `orca.sh setup status`: `absent`, `current`, `drifted` (naming the manifests that changed), or `unstamped` (hand-written). Any but `current` earns an **offer** of the deep pass: the `orca:doctor` agent derives a `.orca/setup` script from the repo's own evidence and proves it in a throwaway worktree under `.orca/doctor/`; doctor re-runs the verification itself, shows you the script, and installs it only when you say so. See [Worktree provisioning](worktrees.md#provisioning).

Also offered, never defaulted: writing `bypassPermissions` as the repo's default mode, and checking the editor companions — [orca.nvim](https://github.com/miguelbacalhau/orca.nvim) when Neovim is on PATH, [orca.vscode](https://github.com/miguelbacalhau/orca.vscode) when `code` is. `BARE_REPO: FAIL` is routed to `/orca:init`.

## `/orca:config [assignments | reset]`

Per-repository overrides in `.orca/config`, applied at the **next** run launch (a running or resumed run keeps its launch-time config).

```bash
/orca:config                                # show the reviewer + effective table
/orca:config reviewer=claude                # pin the Claude reviewer
/orca:config reviewer=default               # unpin — back to detection
/orca:config plan.model=sonnet review.effort=high
/orca:config plan.model=default             # clear one field
/orca:config reset plan                     # clear one stage
/orca:config reset                          # clear everything (reviewer included)
```

- **`reviewer`** — `codex` or `claude`. Absent, each launch detects (codex on PATH at the minimum version → codex, else claude). Setting it pins the choice, so a broken codex becomes a pre-flight `FAIL` instead of a silent Claude run.
- **Stage model/effort** — models `haiku` | `sonnet` | `opus` | `fable`, efforts `low` | `medium` | `high` | `xhigh` | `max`. The `review` key applies to whichever reviewer agent is active: with codex it only changes the courier that drives Codex, not Codex itself. `fable` is the default for `spec`, `research`, and `plan`; on a plan without fable access, pin them with `/orca:config spec.model=opus research.model=opus plan.model=opus`.
- **`editor` / `terminal`** — for `/orca:review`.
- **`council`** — the seats for `/orca:council`: 2 to 5 of `haiku` | `sonnet` | `opus` | `fable` | `astra`, comma-separated, repeats allowed. Absent → `opus,fable,astra` with `astra` dropped when Codex isn't installed; pinned → `astra` requires Codex.

The configurable stages and their defaults are in [Stage agents](anatomy.md#stage-agents). Overrides survive plugin updates.
