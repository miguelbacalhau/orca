# orca

A [Claude Code](https://claude.com/claude-code) plugin for autonomous, multi-agent development — two verbs on one substrate. Set the repository up once, then **`/orca:feature`** takes a feature from idea to a committed integration branch (an adversarial interview captures intent as a durable brief; a deterministic workflow plans, implements, independently reviews, fixes, commits, merges, and verifies), and **`/orca:debug`** takes a bug from symptom to a verified diagnosis — and, in scope, a committed fix (an interview captures the symptom as a durable case; a deterministic workflow establishes a reproduction, fans out adversarial hypothesis verification, judges a root cause, and lands a fix that must turn the repro green). Either way the user interacts exactly once after the interview (features: twice, by opt-in).

```text
/orca:feature <idea>     # triage → interview/brief → spec → work loop → report
                         # (interactive until one confirmation, autonomous after)
/orca:debug <symptom>    # triage → interview/case → repro gate → hypotheses →
                         # verify → diagnose → fix → repro check → report
/orca:init               # one-time repository layout setup      (interactive, consent per step)
/orca:doctor             # one-time machine tooling setup        (interactive, consent per step)
/orca:config             # optional per-repo reviewer & model/effort tuning
```

The deliverable of a run is a branch on an integration worktree — `feature/<slug>` for features, `fix/<slug>` for fixed bugs — which you land yourself with `git merge --no-ff <branch>`. The runs never touch your own worktree, and no commit they produce mentions Claude, AI, agents, or orca.

## Table of contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Anatomy of a run](#anatomy-of-a-run)
- [Anatomy of a debug run](#anatomy-of-a-debug-run)
- [Repository layout](#repository-layout)
- [Stage agents](#stage-agents)
- [Configuration](#configuration)
- [Permissions and autonomy](#permissions-and-autonomy)
- [Interruption, resume, and cleanup](#interruption-resume-and-cleanup)
- [Troubleshooting](#troubleshooting)
- [Migrating from the pre-plugin skills](#migrating-from-the-pre-plugin-skills)
- [Repository contents](#repository-contents)

## How it works

Three design choices carry the whole system:

**Double isolation.** Every stage — spec, plan, implement, review, fix, commit, merge, integrate on the feature side; reproduce, hypothesize, verify, diagnose on the debug side — runs in a dedicated subagent with its own context window, and every unit of parallel work (a feature's work item, a debug run's hypothesis) gets its own git worktree off a shared bare repository. Heavy context — codebase exploration, diffs, instrumented runs, test output — lives and dies inside subagents; the main conversation only reads artifact files and the workflow's structured result. Parallel items can never corrupt each other's files: overlap surfaces as an explicit merge conflict, resolved by a merge agent holding both items' plans.

**Independent review.** Claude implements; a separate reviewer attacks the result before anything is committed. The featured default is cross-model: [Codex](https://openai.com/codex/) reviews, through an MCP registration the plugin bundles for the global `codex` binary (`codex mcp-server`), driven adversarially over each item's diff by a dedicated courier agent — an independent second opinion from a different model family, one that does not share the implementer's blind spots. The review explicitly attacks the tests, since the same model family wrote the code and the tests. With `reviewer=claude` — the detected default wherever codex isn't installed, or an explicit pin via `/orca:config` — a dedicated Claude review agent performs the same adversarial review itself: it keeps fresh-context independence (a separate agent, only the artifacts and the diff), but it is same-model, so it may share the implementer's blind spots. That trade-off is stated wherever the choice is made; cross-model stays the stronger design.

**A deterministic work loop.** The long autonomous middle of a run is one bundled script executed through Claude Code's Workflow tool, not conversational orchestration. Scheduling, retry bounds, review throttling, merge serialization, and the commit-attribution check are code, so the guarantees are structural rather than model discipline that decays over a long context. Judgment calls (plan reconciliation, escalation, review verdicts) stay in agents, but as schema'd calls whose reasons land in the run's artifacts. Every agent call is journaled, so an interrupted run resumes where it stopped.

State lives in files, never in conversation memory: the brief, the spec with its work breakdown and decision log, one plan per item, the raw review findings per round, and a final report — all under a per-run directory in `.orca/`.

## Requirements

| Requirement | Detail |
|---|---|
| Claude Code | A harness with the **Workflow tool** (the work loop runs through it). `/orca:feature` checks and refuses without it. |
| Codex CLI | Required only **when the reviewer is codex** (the default wherever it is installed): the **global `codex` binary on PATH**, version **≥ 0.142.5**, authenticated via `codex login`. **Never install codex via npm** — use `brew install codex` or the official release binaries. With `reviewer=claude`, the codex rows don't apply. |
| Repository layout | Bare-repo-with-worktrees (`.bare/` + peer worktrees). `/orca:init` sets this up, including converting an existing conventional checkout in place. |
| git | ≥ 2.5 (worktrees); ≥ 2.42 for `worktree add --orphan` when `/orca:init` creates a brand-new repository. |
| `MCP_TOOL_TIMEOUT` | Codex-only, like the row above: set to `1200000` (~20 min) in a Claude Code settings `env` block, so Codex reviews are not killed at the default MCP tool timeout. A plugin cannot ship session env, so `/orca:doctor` writes it for you. |
| Permission mode | Runs need `bypassPermissions` for the session — see [Permissions and autonomy](#permissions-and-autonomy). |

Everything else — the thirteen stage agents and the codex MCP server registration — ships inside the plugin itself; there is nothing to install per repository beyond the layout.

## Installation

This repository hosts its own plugin marketplace (`.claude-plugin/marketplace.json`), so installing is two commands inside Claude Code:

```
/plugin marketplace add miguelbacalhau/orca
/plugin install orca@orca
```

The install persists across sessions. Updates are manual by default for third-party marketplaces — pull new versions with `/plugin marketplace update orca`, or toggle auto-update in the `/plugin` → Marketplaces UI. Removal is symmetric: `/plugin marketplace remove orca` uninstalls the marketplace and the plugin in one step.

Teams can make the install declarative instead: commit this to the project's `.claude/settings.json`, and Claude Code prompts each teammate to install the marketplace and pre-enables the plugin when they trust the workspace:

```json
{
  "extraKnownMarketplaces": {
    "orca": { "source": { "source": "github", "repo": "miguelbacalhau/orca" } }
  },
  "enabledPlugins": { "orca@orca": true }
}
```

For local development on the plugin itself, load a checkout directly for a single session:

```bash
claude --plugin-dir /path/to/this/repo
```

MCP servers load at session start, so after installing or enabling the plugin, **start a fresh session** before running — when the reviewer is codex, `/orca:feature` verifies live that the codex MCP tool resolves and stops if it does not.

## Quick start

```bash
# 1a. One-time per repo: the bare-repo-with-worktrees layout. Interactive,
#     consent per step. Converting an existing checkout preserves untracked
#     files (.env, caches) but changes every path — see /orca:init.
/orca:init

# 1b. One-time per machine, only if the pre-flight flags it: Codex CLI
#     install/auth guidance and the MCP timeout settings write. Skippable
#     outright if you'll run with the Claude reviewer.
/orca:doctor

# 2. The feature. An interview captures intent as a brief file — outcome,
#    features, non-goals, constraints, doubt rule, as many rounds as the
#    idea needs — then, after ONE confirmation, the run drives autonomously
#    to a final report and a feature/<slug> branch. Decline the run prompt
#    to leave the brief queued for a later /orca:feature instead.
/orca:feature add rate limiting to the public API

# 2b. Or the bug. An interview captures the symptom as a durable case —
#     reading the stack traces and logs you point at — then the run
#     reproduces, hypothesizes, verifies, diagnoses, and (by default)
#     lands a fix with a regression test on a fix/<slug> branch.
/orca:debug the export endpoint returns 500 on files over 2MB

# 3. Land the deliverable from your own worktree.
git merge --no-ff feature/<slug>     # or fix/<slug>
```

Briefs can be queued ahead of time — everything at the top level of `.orca/feat-briefs/` is ready and unconsumed; a later `/orca:feature` finds them, offers to run one, and a run consumes exactly one.

## Commands

### `/orca:feature <idea>`

The one feature verb — a dispatcher over `.orca` state. Triage looks at what is on disk and offers the first match, never forcing it:

1. **An interrupted run** — a run directory whose `spec.md` records a workflow runId with no `report.md` beside it. Offers to resume from the journal; completed work replays instantly, only in-flight and remaining work runs live.
2. **A queued brief** — anything at the top level of `.orca/feat-briefs/`. Offers to run one, or to interview a new idea instead.
3. **Nothing waiting** — interviews the idea into a brief, then asks once: run it now, or leave it queued?

**The interview** sharpens a rough idea into a durable brief at `.orca/feat-briefs/<timestamp>-<slug>.md`. The brief is the *entire* intent the run acts on — the run asks nothing beyond one confirmation — so the interview is deliberately adversarial about scope: it pushes back, hunts for unstated non-goals, and makes you resolve ambiguities now rather than leaving them for an autonomous run to guess at.

A brief records: **outcome**, **features**, **non-goals**, **inputs & outputs**, **constraints**, plus two run-controlling choices:

- **Doubt rule** — when the run hits an ambiguity, does it prefer the smaller interpretation and cut scope (`prefer-smaller-scope`, the default) or the more complete one (`prefer-complete`)?
- **Breakdown checkpoint** — review the spec and work breakdown once before any code (`review-once`), or run straight through (`straight-through`, the default)?

The brief is *what and why*, never *how*: no work breakdown, no interfaces, no file ownership — those come from the run's spec stage, grounded in real codebase exploration. Location is status: top-level briefs are ready; park unfinished ones in `.orca/feat-briefs/drafts/`. One brief is one run's scope — two independent efforts get two briefs, and declining the run prompt leaves a brief queued for any later `/orca:feature`.

**The run.** See [Anatomy of a run](#anatomy-of-a-run) for the full lifecycle. Interaction surface, in total:

1. **One confirmation** of the restated brief (plus trunk-branch confirmation) — this authorizes everything that follows. It runs in full even when the brief was written seconds earlier in the same session: the file, not the conversation, is the authorized intent.
2. **One optional checkpoint** — only if the brief opted in: review the spec and work breakdown before any code.

After that, nothing asks you anything. Ambiguities resolve against the spec and the doubt rule; what cannot be resolved that way becomes a `blocked` item in the final report, with the options you must choose between recorded. Mid-run, live per-item status shows on the session task list; the outcome lands in `report.md`.

### `/orca:debug <symptom>`

The debug verb — a dispatcher over `.orca/bug-cases/`, where an open **case** is the durable unit the way a brief is for features (location is status: a case stays there until a run closes it). Triage offers the first match, never forcing it:

1. **An interrupted run** — found through its open case, whose `case.md` records the workflow runId and launch args. Offers to resume from the journal.
2. **An open case** — never launched, or left open by a run that ended `not-fixed`, `undiagnosed`, or `no-repro`. Offers to run it with its **ledger** loaded: refuted hypotheses are never re-proposed, inconclusive ones are picked up first, failed-fix diffs are evidence — a re-run starts smarter, not over.
3. **Nothing waiting** — interviews the symptom into a case, then asks once: run it now, or leave it open?

**The interview** differs from the feature one in a single deliberate way: it *reads the evidence you point at* — stack traces, failing CI logs, error output — because the symptom lives in artifacts, not intent, copying them into the case's `evidence/` directory. It captures the symptom verbatim, expected behavior, reproduction steps (or "none known"), last known good (which unlocks automated `git bisect`), environment, what you've already ruled out, and the **scope rule**: `diagnose-and-fix` (the default — the run lands a fix) or `diagnose-only` (the run ends after the judge with a root-cause report).

**The run** (see [Anatomy of a debug run](#anatomy-of-a-debug-run)) interacts exactly once — one confirmation of the restated case and scope. Two hard rules shape it: the **repro gate** (no deterministic reproduction → the run records the attempt in the ledger and stops loudly; there is no evidence-only fallback) and **three-valued verdicts** (`confirmed` requires observed evidence; `inconclusive` is honest and seeds the next run — no manufactured confidence). On `fixed`, the deliverable is a `fix/<slug>` branch carrying the fix plus a regression test derived from the repro.

### `/orca:init [path or clone URL]`

One-time, consent-per-step setup that makes a repository pass `/orca:feature`'s pre-flight. Handles three cases:

- **New repository** — bare-init plus a default-branch worktree.
- **Clone a URL** — bare clone, fetch refspec fix (bare clones silently fetch nothing without it), default-branch worktree.
- **Convert an existing checkout** — restructures in place: `.git` becomes `.bare`, tracked files move into a `<branch>/` worktree, and **untracked files (including ignored ones — `.env`s, caches) are carried over** via a manifest before anything is deleted. Every path changes, so editors and terminals need re-pointing; the conversion is layout-only (no history, refs, or remotes touched) and reversible until the final cleanup step, which is confirmed separately.

Preconditions for conversion — it stops rather than improvising: a clean tree, no existing linked worktrees, no submodules.

Layout only: machine-gate failures the pre-flight reports (Codex, the MCP timeout) are routed to `/orca:doctor`, not fixed here.

### `/orca:doctor`

Interactive, consent-per-step machine and session tooling — the per-machine counterpart to `/orca:init`'s per-repo layout. It diagnoses with the same read-only pre-flight (or probes codex directly when run outside a repository), reports every gate plus the resolved reviewer in plain language, and fixes only what was flagged:

- **Codex missing or stale** — points you at the official non-npm install (`brew install codex` or the release binaries; never npm). Installing is your action.
- **Not authenticated** — suggests `codex login` and verifies with `codex login status`. Also yours.
- **`MCP_TOOL_TIMEOUT` unset** — writes it into a settings `env` block (project or user level, your choice), merged, with the session-restart caveat.

It is reviewer-aware: with a detected claude reviewer (codex not installed) there is nothing to fix — it says runs will use the Claude reviewer, explains that installing codex enables the stronger cross-model review, and offers to pin either choice via `/orca:config`. With claude pinned and codex present, it notes the codex gates were skipped by choice. A codex gate failing while the reviewer is codex is always a failure to fix — never a silent switch to the other reviewer.

Optionally — offered, never defaulted — it can write `bypassPermissions` as the default mode for a repo where runs are always unattended, and, when Neovim is on PATH, check for the [orca.nvim](https://github.com/miguelbacalhau/orca.nvim) companion and prescribe its install so `:OrcaReview` walks a deliverable branch's merge-base diff in your own editor (quickfix file list, native side-by-side diff, your LSP and colors) before you `git merge --no-ff` it. Layout failures route the other way: `BARE_REPO: FAIL` goes to `/orca:init`.

### `/orca:config [assignments | reset]`

Optional per-repository overrides, written to `.orca/config.json` and applied by the **next** run launch (a run in flight, or a resume of one, keeps its launch-time config): which independent reviewer the work loop uses (top-level `reviewer` key), and which Claude model and reasoning effort each stage agent runs with (`agents` block).

```bash
/orca:config                                # show the reviewer + effective table
/orca:config reviewer=claude                # pin the Claude reviewer
/orca:config reviewer=default               # unpin — back to detection
/orca:config plan.model=sonnet review.effort=high
/orca:config plan.model=default             # clear one field
/orca:config reset plan                     # clear one stage
/orca:config reset                          # clear everything (reviewer included)
```

`reviewer` is `codex` or `claude`; when the key is **absent**, each run launch detects — codex binary on PATH at the minimum version → codex, else claude — and a written key pins the choice (pinning `codex` turns a future broken codex into a loud pre-flight `FAIL` instead of a silent claude run). On `reviewer=claude` the skill states the independence trade-off; on `reviewer=codex` it checks that the codex machine gates pass and points at `/orca:doctor` if they don't.

Valid stage values — models `haiku` | `sonnet` | `opus` | `fable`, efforts `low` | `medium` | `high` | `xhigh` | `max`. Two caveats: `spec` accepts a model override only (it is spawned conversationally, where effort cannot be set), and what configuring `review` means depends on the reviewer — with codex it changes the cost of the *courier* that drives Codex, never Codex's review quality; with claude it tunes the actual reviewer (default opus/high). Overrides survive plugin updates; the plugin's own agent definitions are never edited.

## Anatomy of a run

```text
/orca:feature
   │
   ├─ 0. Triage                     resume an interrupted run · run a queued brief
   │                                · or interview → brief, then run now or queue
   ├─ 1. Pre-flight + confirm       preflight.sh gates, Workflow tool, live MCP
   │                                check, bypassPermissions; ONE user confirmation
   ├─ 2. Spec (orca:spec)           read-only codebase exploration → spec.md with
   │                                Interfaces + a 2–8 item dependency-ordered
   │                                Work Breakdown with file ownership
   ├─ 3. Announce / checkpoint      status update, or the one opt-in approval;
   │                                create integration worktree on feature/<slug>
   ├─ 4. Work loop (Workflow tool)  deterministic script, per readiness wave:
   │       plan ∥ ──► reconcile ──► [escalate/amend once] ──► per item:
   │       worktree ► implement ► review (codex or claude) ► fix ► re-review ► commit ► merge
   │       …then, after the loop drains: integrate (verify the assembled feature)
   └─ 5. Report                     report.md: shipped/cut/blocked, deviations,
                                    integration verification, follow-ups, landing
```

**Pre-flight** (`scripts/preflight.sh`, read-only, also run early during the interview) prints one machine-readable line per gate: `BARE_REPO`, a `REVIEWER: codex|claude (pinned|detected)` line resolving which reviewer the run uses, `CODEX` (binary ≥ 0.142.5, authenticated, `MCP_TOOL_TIMEOUT` set — checked only when the resolved reviewer is codex, `SKIPPED` otherwise), an informational `TRUNK_CANDIDATE`, and a final `RESULT` mirrored by the exit code. On any `FAIL` the run does not start; remediation goes through `/orca:init` for the layout gate and `/orca:doctor` for the machine gates.

**Spec** is written once, by a dedicated read-only agent, from the confirmed brief. Its two load-bearing sections: **Interfaces Between Work Items** — the contracts (type shapes, signatures, file ownership, naming) that let items build in parallel without inventing incompatible seams — and the **Work Breakdown**, which becomes the workflow's item list verbatim. If the requested scope cannot be split cleanly against the codebase, the run surfaces that and stops rather than launching against a spec known to be wrong.

**The work loop** is completion-driven: an item launches the moment its dependencies merge and advances the moment its previous stage finishes. The only synchronization points are deliberate — a per-wave plan-reconciliation barrier (an opus agent checks the wave's plans against the spec Interfaces before anything builds) and the serialized merge queue. Bounded loops keep it from thrashing: max 2 fix rounds gated on Critical/High review findings; a deterministic commit-attribution check against the actual `git log` (two attempts, then a forced rewrite); one amendment round per reconciliation failure; at most one escalation-backed replan-and-rebuild per item. Codex reviews — and only codex reviews, which contend for one Codex auth — are throttled to 2 concurrent slots while everything else parallelizes freely; claude reviews ride the workflow's normal concurrency cap.

**Escalation** applies one rule: **amend and continue** when a fix preserves the brief's outcome, features, and non-goals (the change touches only *how*) — recorded in the spec's `## Decisions` log with the doubt rule cited; **block and route around** when every fix would change *what* was agreed. A blocked item keeps its worktree and branch for a follow-up run and never stalls unaffected work. Under `prefer-smaller-scope`, cleanly cutting a feature counts as an amendment.

**Integration verification** runs after the loop drains: a dedicated agent builds, tests, and exercises each spec feature end to end in the integration worktree, judging against the spec's Outcome and Features — looking specifically at the seams where items compose. Small integration bugs are fixed, review-checked, and committed; larger mismatches are reported as gaps.

**The report** (`report.md`) is the durable record: shipped items with commit hashes, deviations mirroring the spec's Decisions log, blocked items with the decision each waits on, per-feature integration results, follow-ups sourced from the plans' Deviations sections, and the landing command.

## Anatomy of a debug run

Debugging is a different shape of work — unknown outcome, hypothesis fan-out instead of work-item fan-out, convergence by judgment instead of merge — so it gets its own artifacts and workflow (`scripts/debug-loop.workflow.js`), on the same substrate: worktree isolation, journaled resume, and the same stage machinery for the fix.

The durable state is the **case** at `.orca/bug-cases/<slug>/`: `case.md` (the symptom verbatim, expected behavior, repro steps, last known good, environment, evidence pointers, what's ruled out, and the scope rule), `repro.sh` once established, `evidence/`, and the append-only **`ledger.md`** — every hypothesis ever tested with its verdict and every fix attempt, across runs. The ledger is what makes run N+1 converge instead of re-run.

**`repro.sh` is the run's currency**, under the `git bisect run` exit contract: exit 0 = bug absent, 1–127 = bug present, 125 = cannot test. Verify agents use it as their oracle (and bisect with it automatically when the case records a last known good), and the final fix check is simply running it — a zero-judgment checker agent executes it and the workflow branches on the exit code, never on a model's self-report.

```text
/orca:debug
   │
   ├─ 0. Triage                 resume via the open case · run an open case
   │                            (ledger loaded) · or interview → case
   ├─ 1. Pre-flight + confirm   same gates as a feature run (codex gates serve
   │                            the fix tail); ONE confirmation of case + scope
   ├─ 2. Debug loop (Workflow)  deterministic script:
   │       repro gate (hard) ──► hypothesize (3–8 ranked, ledger-aware)
   │       ──► verify ∥ (adversarial, one throwaway worktree each)
   │       ──► diagnose (judge) ──► [diagnose-only: stop here]
   │       ──► fix: nested work loop over a synthesized one-item contract
   │       ──► repro check ──► [red? one retry: revert → regenerate
   │                            → verify → diagnose → fix]
   └─ 3. Report                 report.md; ledger appended; case closed
                                (fixed/diagnosed) or left open, smarter
```

**The fix tail reuses the feature machinery instead of reimplementing it**: the diagnose agent writes a synthesized spec (root cause, regression-test-from-repro requirement, minimal-diff constraint) to the run's `fix/spec.md`, and the debug workflow nests a call to `work-loop.workflow.js` over that one item — plan, implement, independent review (codex or claude, exactly as configured), fix, commit with the attribution check, merge, integrate. The deliverable branch is `fix/<slug>`, mirroring `feature/<slug>`. A committed fix that leaves the repro red gets exactly one internal retry — the failed attempt is reverted on the branch tip (its diff stays in history as ledger evidence), hypotheses regenerate once with refuted ones excluded — and then the run ends `not-fixed` (or `undiagnosed`, when the retry's hypotheses all die), case open.

A run that ends `no-repro`, `undiagnosed`, or `not-fixed` is a loud, honest stop, not a failure to hide: the ledger records what was tried, and re-invoking `/orca:debug` finds the open case and starts from it.

## Repository layout

What a repository looks like mid-run (`/orca:init` creates the top three entries; the runs create the rest and clean up their transient worktrees):

```text
<repo-root>/
├── .bare/                        # the bare repository (shared object store)
├── .git                          # one line: gitdir: ./.bare
├── main/                         # your worktree(s) — never touched by the runs
├── orca-<slug>/                  # feature: integration worktree (branch feature/<slug>)
├── orca-<slug>-W1/               # feature: one worktree per in-flight item (branch feature/<slug>-W1)
├── orca-bug-<slug>/              # debug: case worktree — repro + exploration (branch bug/<slug>)
├── orca-bug-<slug>-H1/           # debug: one throwaway worktree per hypothesis, removed after its verdict
├── orca-fix-<slug>/              # debug: fix integration worktree (branch fix/<slug>)
└── .orca/
    ├── config.json                    # optional per-repo reviewer & model/effort overrides
    ├── feat-briefs/                   # unconsumed feature briefs (drafts/ for parked ones)
    ├── bug-cases/<slug>/              # open bug cases: case.md, repro.sh, ledger.md, evidence/
    ├── YYYYMMDD-HHMMSS-feat-<slug>/   # one directory per feature run
    │   ├── brief.md                   # the consumed brief — moved here when the run starts
    │   ├── spec.md                    # spec, work breakdown, Decisions log, workflow runId
    │   ├── report.md                  # final run report
    │   ├── plans/                     # one plan per item, with its Deviations section
    │   └── reviews/                   # raw findings JSON per review round (codex or claude)
    └── YYYYMMDD-HHMMSS-bug-<slug>/    # one directory per debug run
        ├── hypotheses.md              # ranked candidates (hypotheses-2.md on the retry round)
        ├── verdicts/                  # one verdict JSON per hypothesis
        ├── diagnosis.md               # the judge's root-cause statement
        ├── report.md                  # final run report
        ├── case/                      # the closed case — moved here when a run resolves it
        └── fix/                       # the nested fix run: spec.md (synthesized), plans/, reviews/
```

Two naming namespaces, deliberately different: `orca-*` **directory** names are local scratch — the cleanup and discovery story via `git worktree list` — and never enter git; the **branch** names that land in history and on GitHub (`feature/<slug>[-<ID>]`, `fix/<slug>[-<ID>]`) are neutral and carry no orca trace, while throwaway `bug/<slug>*` branches never merge at all. `.orca/` sits outside every worktree, so its contents cannot be committed by accident. Inside `.orca/`, every artifact is verb-prefixed — `feat-briefs/` and `feat-` run directories for the feature verb, `bug-cases/` and `bug-` run directories for the debug verb — so a bare `ls .orca/` reads unambiguously.

## Stage agents

Thirteen agents ship in the plugin (`agents/<stage>.md`, loaded as `orca:<stage>`). Each runs with its own context window and only the per-item values it needs; context passes between stages through artifact files, never relayed summaries.

The first nine serve feature runs — and, `spec` excepted (the diagnose agent writes the fix tail's contract, so no spec agent ever runs there), the fix tail of a diagnose-and-fix debug run:

| Stage | Role | Default model | Default effort |
|---|---|---|---|
| `spec` | Explores the codebase; writes the spec and work breakdown (once, at the start) | opus | xhigh |
| `plan` | Read-only planner for one item; writes a plan a cheaper implementer can follow | opus | xhigh |
| `implement` | Builds one item in its worktree, checking off and amending its plan | sonnet | high |
| `review-codex` | Courier that drives the Codex review via MCP and files the findings verbatim | sonnet | medium |
| `review-claude` | Performs the independent review itself — same adversarial contract and artifact schema as the Codex path | opus | high |
| `fix` | Applies review findings; escalates findings rooted in the plan, spec, or other items | opus | high |
| `commit` | One Conventional Commit per item, staged by name, no attribution | haiku | low |
| `merge` | Serialized merge into the integration branch; resolves conflicts with both plans in hand; verifies the merged result | opus | high |
| `integrate` | Verifies the assembled feature end to end against the spec | opus | high |

The last four serve debug runs:

| Stage | Role | Default model | Default effort |
|---|---|---|---|
| `reproduce` | Turns the case into a deterministic `repro.sh` under the bisect exit contract, plus captured evidence | sonnet | high |
| `hypothesize` | Read-only exploration of codebase + case + ledger; writes 3–8 ranked, falsifiable root-cause candidates | opus | xhigh |
| `verify` | Attacks one hypothesis in its own throwaway worktree — instrument, bisect, refute; verdicts need evidence | sonnet | high |
| `diagnose` | The judge: merges verdicts into a root-cause diagnosis and, in scope, the synthesized fix contract | opus | high |

A run uses exactly one of `review-codex` / `review-claude`, chosen by the resolved reviewer at launch. The `/orca:config` stage key for both is `review` — the overrides apply to whichever reviewer agent is active.

Override any of these per repository with [`/orca:config`](#orcaconfig-assignments--reset). The workflow's internal helper agents (reconciliation, escalation) are not configurable — their cost/judgment profile is part of the loop's design.

## Configuration

**`.orca/config.json`** (repo root, written by `/orca:config`) — the reviewer choice and per-stage model/effort overrides, applied at the next run launch:

```json
{
  "reviewer": "claude",
  "agents": {
    "plan": { "effort": "high" },
    "implement": { "model": "opus" }
  }
}
```

A present `reviewer` key **pins** the choice; an absent key means each launch **detects** (codex on PATH at the minimum version → codex, else claude). The `agents` overrides sit on top of the agent defaults. One block serves both verbs — the feature stages and the debug stages (`reproduce`, `hypothesize`, `verify`, `diagnose`) live side by side, and each run applies its own verb's keys while validating and ignoring the other's.

**`MCP_TOOL_TIMEOUT`** — codex-only: client-side session env governing MCP tool-call timeouts; a plugin cannot ship it, so `/orca:doctor` writes it into the `env` block of `.claude/settings.local.json` (or `~/.claude/settings.json`):

```json
{ "env": { "MCP_TOOL_TIMEOUT": "1200000" } }
```

~20 minutes is deliberate: the workflow retries reviews at two levels, so this value multiplies into the per-item worst case (~80 minutes at this setting; an hour would balloon it to several). Settings env loads at **session start** — restart the session after writing it.

**Bundled `.mcp.json`** — registers the codex MCP server as the global PATH binary, nothing else:

```json
{ "mcpServers": { "orca-codex": { "command": "codex", "args": ["mcp-server"] } } }
```

The server is deliberately named `orca-codex`, not `codex`, so it can never collide with a user's own `codex` registration. A harsher failure mode has nothing to do with names: as of Claude Code 2.1.202, a project that carries any MCP config of its own — a `.mcp.json` at the repo root, or local-scope servers from `claude mcp add` — loads **none** of a plugin's bundled MCP servers (upstream bug; verified with installed plugins and `--plugin-dir` alike). The live MCP gate and `/orca:doctor` both diagnose it; the fix is removing the project-level registration (a leftover `codex` entry is redundant — the plugin bundles the server) or pinning `reviewer=claude` until the project's own MCP servers can coexist with plugins.

## Permissions and autonomy

A run only stays autonomous if the harness never raises a permission prompt: every workflow-spawned subagent inherits the session's permission mode, a single foreground prompt breaks autonomy mid-run, and an auto-denied call makes an agent fail confusingly instead.

**This requires `bypassPermissions` mode — an allow-list is not sufficient.** The subagents decide commands at runtime (dependency installs, build/test variants, assorted git invocations), so the command set is open-ended; and Bash permission rules match as prefix globs against the literal command string, so listed commands still slip through when they contain `$(…)`, lead with flags, or are compound. A leaked prompt is a question of *when*, not *whether*.

Enable it one of three ways: Shift+Tab in-session until the footer shows "bypass permissions" (easiest, right before the run); `claude --dangerously-skip-permissions` at launch; or `"permissions": { "defaultMode": "bypassPermissions" }` in `.claude/settings.local.json` for always-unattended repos (offered by `/orca:doctor`, never defaulted).

The tradeoff is real and `/orca:feature` states it before starting: bypass mode disables the approval gate for the **whole session**, not just the run — a dedicated session for the run is the clean choice. If you won't enable it now, the run does not start (it would only pause partway), but the invocation ends cleanly with the brief saved and queued — enable bypass and re-invoke `/orca:feature` when ready.

## Interruption, resume, and cleanup

Every agent call in the work loop is journaled, and the workflow `runId` is persisted the moment the workflow launches — precisely because the interruption that needs it, session death, also erases the conversation. Feature runs persist it to the end of `spec.md` (as `**Workflow run:** <runId>`, alongside the launch-time reviewer as `**Workflow reviewer:**` and the launch-time `agents` block when one was passed); debug runs persist `**Workflow run:**` plus the full launch args as `**Workflow args:**` to the open case's `case.md`. A resume replays those recorded values, never the current `.orca/config.json`.

- **Interrupted run** (session death, kill, harness restart): invoke the same verb — `/orca:feature` triage discovers the interrupted run on disk via `spec.md`; `/orca:debug` triage finds it through its open case — and it offers the resume, re-invoking the workflow with the same script and args plus `resumeFromRunId`. Completed agent calls replay instantly from the journal; only in-flight and remaining work runs live. Never re-run stages conversationally.
- **Blocked items** keep their worktree and branch deliberately — the report lists them for a follow-up run.
- **Open cases persist by design**: a debug run that ends `no-repro`, `undiagnosed`, or `not-fixed` leaves its case in `.orca/bug-cases/` with the ledger appended, and the next `/orca:debug` starts from it.
- **Abandoned run**: `git worktree list`, remove leftover `orca-*` worktrees and their `feature/<slug>*` (or `bug/<slug>*` / `fix/<slug>*`) branches. Prefer resuming.
- **Pre-plugin runs cannot resume** under the plugin (agent types, worktree names, and journal keys all changed) — clean up their leftovers and start fresh from a new brief.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `BARE_REPO: FAIL: conventional checkout` | The repo isn't in the bare-with-worktrees layout. Run `/orca:init` — it converts interactively, preserving untracked files. |
| `CODEX: FAIL: codex not on PATH` / version too old | Install or upgrade the Codex CLI from the official non-npm distribution (`brew install codex` or the release binaries) — `/orca:doctor` walks it through. **Never `npm i -g @openai/codex`.** |
| `CODEX: FAIL: not authenticated` | Run `codex login` (interactive; your action, not the agent's). Verify with `codex login status`. `/orca:doctor` guides and re-checks. |
| `CODEX: FAIL: MCP_TOOL_TIMEOUT not set` | Run `/orca:doctor` to write it into a settings env block, then start a fresh session. |
| Run used the Claude reviewer unexpectedly | The reviewer key is absent and codex wasn't detected — missing or below the minimum version. Fix codex via `/orca:doctor`, or pin `reviewer=codex` via `/orca:config` so a broken codex fails the pre-flight loudly instead. |
| `REVIEWER: FAIL: invalid reviewer` | The `reviewer` key in `.orca/config.json` is not `codex`/`claude` (or appears twice). Fix it with `/orca:config` — the pre-flight never guesses. |
| `/orca:feature` says the codex MCP tool doesn't resolve | Two causes. If the project has any MCP config of its own (a `.mcp.json` at the repo root, or local-scope servers — `claude mcp list` shows both), a Claude Code bug (as of 2.1.202) loads none of the plugin's bundled MCP servers: remove the redundant registration, or pin `reviewer=claude` if the project's own servers must stay. Otherwise check the plugin is installed and enabled — MCP servers load at session start, so the session may simply predate the install or enablement. Either way, start a fresh session in the project. |
| `/orca:feature` says the harness has no Workflow tool | The work loop needs a Claude Code harness with workflows; there is no conversational fallback. |
| Run pauses on a permission prompt | The session wasn't in `bypassPermissions` mode. Enable it (Shift+Tab) and re-invoke the verb — triage offers the resume from the journal — rather than restarting the run. |
| Debug run stopped at the repro gate (`no-repro`) | The bug could not be reproduced deterministically — the gate is hard by design, and there is no evidence-only fallback. The case is still open with the attempt recorded in its ledger; improve the case (repro steps, environment, evidence) and re-invoke `/orca:debug` — triage finds it. |
| Debug run ended `not-fixed` (or `undiagnosed` with a `fixBranch` in the result) | A committed fix (and its one internal retry) left `repro.sh` red — or exited 125, leaving the fix unverified (the returned `notes` say which). The case is open, the failed diffs sit in the history of `fix/<slug>` as ledger evidence, and re-invoking `/orca:debug` starts a smarter run: refuted hypotheses excluded, inconclusive ones first. |
| `git fetch` does nothing in a bare clone made by hand | Bare clones get no fetch refspec. `/orca:init`'s clone path sets `remote.origin.fetch` — do the same, or re-clone through it. |

## Migrating from the pre-plugin skills

Plugin versions before 0.2.0 shipped the interview and the run as two skills, `/orca:brief` and `/orca:run`. Both are folded into `/orca:feature` — triage decides between resume, run, and interview — and the old names are gone, with no aliases. The briefs directory is renamed too: move queued briefs with `mv .orca/briefs .orca/feat-briefs` at the repo root, after which they are discovered exactly as before. A run interrupted under `/orca:run` resumes under `/orca:feature` — the workflow journal keys on agent prompts, not on the script's (now-moved) path, and triage detects old run directories regardless of the new `feat-` naming (detection keys on `spec.md`, not the directory name).

This repository previously shipped the same workflow as symlink-installed skills named `briefify`/`initify`/`orchestrify` (plus a Codex CLI variant, now scrapped). If you used those:

- Remove the old symlinks from `~/.claude/skills` and `~/.claude/agents`.
- Queued briefs migrate with `mv .orchestrify .orca && mv .orca/briefs .orca/feat-briefs` at the repo root.
- In-flight pre-migration runs cannot resume under the plugin — clean up any leftover `orchestrify-*` worktrees and start fresh from a new brief.

## Repository contents

| Path | Contents |
|---|---|
| `.claude-plugin/plugin.json` | The plugin manifest (`orca`). |
| `.mcp.json` | Bundled codex MCP server registration — the global PATH `codex` binary, never npm. |
| `skills/feature/`, `skills/debug/`, `skills/init/`, `skills/doctor/`, `skills/config/` | The five skills. |
| `skills/feature/interview.md`, `skills/debug/interview.md` | The interview instructions, loaded only when a verb's triage lands on a new interview. |
| `scripts/preflight.sh` | Read-only environment validation — the gate lines above. |
| `scripts/work-loop.workflow.js` | The deterministic feature work loop, run through the Workflow tool — also nested by debug runs for the fix tail. |
| `scripts/debug-loop.workflow.js` | The deterministic debug loop: repro gate, hypothesis fan-out, verification, diagnosis, nested fix, repro check. |
| `agents/` | The thirteen stage agents, loaded as `orca:<stage>` (the reviewers are `review-codex` and `review-claude`; the debug stages are `reproduce`, `hypothesize`, `verify`, `diagnose`). |
| [orca.nvim](https://github.com/miguelbacalhau/orca.nvim) *(separate repository)* | The Neovim companion: `:OrcaReview` reviews a branch's merge-base diff in your own editor. Dependency-free, installs like any plugin; `/orca:doctor` checks it and prescribes the install. |
