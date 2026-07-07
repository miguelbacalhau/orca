# orca

A [Claude Code](https://claude.com/claude-code) plugin for autonomous, multi-agent feature development. Capture intent as a brief, set the repository up once, then let a deterministic workflow drive the feature from idea to a committed integration branch — planned, implemented, independently reviewed, fixed, committed, merged, and verified, with the user interacting exactly once (or twice, by opt-in).

```text
/orca:brief <idea>     # interview → durable brief file        (interactive)
/orca:init             # one-time repository layout setup      (interactive, consent per step)
/orca:doctor           # one-time machine tooling setup        (interactive, consent per step)
/orca:run              # brief → spec → work loop → report     (autonomous after one confirmation)
/orca:config           # optional per-repo reviewer & model/effort tuning
```

The deliverable of a run is a `feature/<slug>` branch on an integration worktree, which you land yourself with `git merge --no-ff feature/<slug>`. The run never touches your own worktree, and no commit it produces mentions Claude, AI, agents, or orca.

## Table of contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Anatomy of a run](#anatomy-of-a-run)
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

**Double isolation.** Every stage (spec, plan, implement, review, fix, commit, merge, integrate) runs in a dedicated subagent with its own context window, and every work item gets its own git worktree off a shared bare repository. Heavy context — codebase exploration, diffs, test output — lives and dies inside subagents; the main conversation only reads artifact files and the workflow's structured result. Parallel items can never corrupt each other's files: overlap surfaces as an explicit merge conflict, resolved by a merge agent holding both items' plans.

**Independent review.** Claude implements; a separate reviewer attacks the result before anything is committed. The featured default is cross-model: [Codex](https://openai.com/codex/) reviews, through an MCP registration the plugin bundles for the global `codex` binary (`codex mcp-server`), driven adversarially over each item's diff by a dedicated courier agent — an independent second opinion from a different model family, one that does not share the implementer's blind spots. The review explicitly attacks the tests, since the same model family wrote the code and the tests. With `reviewer=claude` — the detected default wherever codex isn't installed, or an explicit pin via `/orca:config` — a dedicated Claude review agent performs the same adversarial review itself: it keeps fresh-context independence (a separate agent, only the artifacts and the diff), but it is same-model, so it may share the implementer's blind spots. That trade-off is stated wherever the choice is made; cross-model stays the stronger design.

**A deterministic work loop.** The long autonomous middle of a run is one bundled script executed through Claude Code's Workflow tool, not conversational orchestration. Scheduling, retry bounds, review throttling, merge serialization, and the commit-attribution check are code, so the guarantees are structural rather than model discipline that decays over a long context. Judgment calls (plan reconciliation, escalation, review verdicts) stay in agents, but as schema'd calls whose reasons land in the run's artifacts. Every agent call is journaled, so an interrupted run resumes where it stopped.

State lives in files, never in conversation memory: the brief, the spec with its work breakdown and decision log, one plan per item, the raw review findings per round, and a final report — all under a per-run directory in `.orca/`.

## Requirements

| Requirement | Detail |
|---|---|
| Claude Code | A harness with the **Workflow tool** (the work loop runs through it). `/orca:run` checks and refuses without it. |
| Codex CLI | Required only **when the reviewer is codex** (the default wherever it is installed): the **global `codex` binary on PATH**, version **≥ 0.142.5**, authenticated via `codex login`. **Never install codex via npm** — use `brew install codex` or the official release binaries. With `reviewer=claude`, the codex rows don't apply. |
| Repository layout | Bare-repo-with-worktrees (`.bare/` + peer worktrees). `/orca:init` sets this up, including converting an existing conventional checkout in place. |
| git | ≥ 2.5 (worktrees); ≥ 2.42 for `worktree add --orphan` when `/orca:init` creates a brand-new repository. |
| `MCP_TOOL_TIMEOUT` | Codex-only, like the row above: set to `1200000` (~20 min) in a Claude Code settings `env` block, so Codex reviews are not killed at the default MCP tool timeout. A plugin cannot ship session env, so `/orca:doctor` writes it for you. |
| Permission mode | Runs need `bypassPermissions` for the session — see [Permissions and autonomy](#permissions-and-autonomy). |

Everything else — the nine stage agents and the codex MCP server registration — ships inside the plugin itself; there is nothing to install per repository beyond the layout.

## Installation

For local development, load the checkout directly:

```bash
claude --plugin-dir /path/to/this/repo
```

Distribution through a plugin marketplace is the eventual install story; it is not set up yet.

MCP servers load at session start, so after installing or enabling the plugin, **start a fresh session** before running — when the reviewer is codex, `/orca:run` verifies live that the codex MCP tool resolves and stops if it does not.

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

# 2. Capture intent. An interview: outcome, features, non-goals, constraints,
#    doubt rule. Takes as many rounds as the idea needs; writes a brief file.
/orca:brief add rate limiting to the public API

# 3. Run. Discovers the brief, restates it, asks for ONE confirmation,
#    then runs autonomously to a final report and a feature/<slug> branch.
/orca:run

# 4. Land the deliverable from your own worktree.
git merge --no-ff feature/<slug>
```

Briefs can be queued ahead of time — everything at the top level of `.orca/briefs/` is ready and unconsumed, and a run consumes exactly one.

## Commands

### `/orca:brief <idea>`

An interactive interview that sharpens a rough idea into a durable brief at `.orca/briefs/<timestamp>-<slug>.md`. The brief is the *entire* intent a later run acts on — the run asks nothing beyond one confirmation — so the interview is deliberately adversarial about scope: it pushes back, hunts for unstated non-goals, and makes you resolve ambiguities now rather than leaving them for an autonomous run to guess at.

A brief records: **outcome**, **features**, **non-goals**, **inputs & outputs**, **constraints**, plus two run-controlling choices:

- **Doubt rule** — when the run hits an ambiguity, does it prefer the smaller interpretation and cut scope (`prefer-smaller-scope`, the default) or the more complete one (`prefer-complete`)?
- **Breakdown checkpoint** — review the spec and work breakdown once before any code (`review-once`), or run straight through (`straight-through`, the default)?

The brief is *what and why*, never *how*: no work breakdown, no interfaces, no file ownership — those come from the run's spec stage, grounded in real codebase exploration. Location is status: top-level briefs are ready; park unfinished ones in `.orca/briefs/drafts/`. One brief is one run's scope — two independent efforts get two briefs.

### `/orca:init [path or clone URL]`

One-time, consent-per-step setup that makes a repository pass `/orca:run`'s pre-flight. Handles three cases:

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

Optionally — offered, never defaulted — it can write `bypassPermissions` as the default mode for a repo where runs are always unattended. Layout failures route the other way: `BARE_REPO: FAIL` goes to `/orca:init`.

### `/orca:run`

The autonomous run. See [Anatomy of a run](#anatomy-of-a-run) for the full lifecycle. Interaction surface, in total:

1. **One confirmation** of the restated brief (plus trunk-branch confirmation) — this authorizes everything that follows.
2. **One optional checkpoint** — only if the brief opted in: review the spec and work breakdown before any code.

After that, nothing asks you anything. Ambiguities resolve against the spec and the doubt rule; what cannot be resolved that way becomes a `blocked` item in the final report, with the options you must choose between recorded. Mid-run, live per-item status shows on the session task list; the outcome lands in `report.md`.

Without a brief, `/orca:run` stops and points you at `/orca:brief` — it never interviews as a substitute. (This is orca's feature run, not Claude Code's built-in `/run` skill that launches the project's app; the namespace keeps them apart.)

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
/orca:run
   │
   ├─ 0. Discover the brief         .orca/briefs/*.md — exactly one, or ask which
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

**Pre-flight** (`skills/run/scripts/preflight.sh`, read-only, also runnable early from `/orca:brief`) prints one machine-readable line per gate: `BARE_REPO`, a `REVIEWER: codex|claude (pinned|detected)` line resolving which reviewer the run uses, `CODEX` (binary ≥ 0.142.5, authenticated, `MCP_TOOL_TIMEOUT` set — checked only when the resolved reviewer is codex, `SKIPPED` otherwise), an informational `TRUNK_CANDIDATE`, and a final `RESULT` mirrored by the exit code. On any `FAIL` the run does not start; remediation goes through `/orca:init` for the layout gate and `/orca:doctor` for the machine gates.

**Spec** is written once, by a dedicated read-only agent, from the confirmed brief. Its two load-bearing sections: **Interfaces Between Work Items** — the contracts (type shapes, signatures, file ownership, naming) that let items build in parallel without inventing incompatible seams — and the **Work Breakdown**, which becomes the workflow's item list verbatim. If the requested scope cannot be split cleanly against the codebase, the run surfaces that and stops rather than launching against a spec known to be wrong.

**The work loop** is completion-driven: an item launches the moment its dependencies merge and advances the moment its previous stage finishes. The only synchronization points are deliberate — a per-wave plan-reconciliation barrier (an opus agent checks the wave's plans against the spec Interfaces before anything builds) and the serialized merge queue. Bounded loops keep it from thrashing: max 2 fix rounds gated on Critical/High review findings; a deterministic commit-attribution check against the actual `git log` (two attempts, then a forced rewrite); one amendment round per reconciliation failure; at most one escalation-backed replan-and-rebuild per item. Codex reviews — and only codex reviews, which contend for one Codex auth — are throttled to 2 concurrent slots while everything else parallelizes freely; claude reviews ride the workflow's normal concurrency cap.

**Escalation** applies one rule: **amend and continue** when a fix preserves the brief's outcome, features, and non-goals (the change touches only *how*) — recorded in the spec's `## Decisions` log with the doubt rule cited; **block and route around** when every fix would change *what* was agreed. A blocked item keeps its worktree and branch for a follow-up run and never stalls unaffected work. Under `prefer-smaller-scope`, cleanly cutting a feature counts as an amendment.

**Integration verification** runs after the loop drains: a dedicated agent builds, tests, and exercises each spec feature end to end in the integration worktree, judging against the spec's Outcome and Features — looking specifically at the seams where items compose. Small integration bugs are fixed, review-checked, and committed; larger mismatches are reported as gaps.

**The report** (`report.md`) is the durable record: shipped items with commit hashes, deviations mirroring the spec's Decisions log, blocked items with the decision each waits on, per-feature integration results, follow-ups sourced from the plans' Deviations sections, and the landing command.

## Repository layout

What a repository looks like mid-run (`/orca:init` creates the top three entries; the run creates the rest and cleans up its item worktrees after merge):

```text
<repo-root>/
├── .bare/                        # the bare repository (shared object store)
├── .git                          # one line: gitdir: ./.bare
├── main/                         # your worktree(s) — never touched by the run
├── orca-<slug>/                  # integration worktree (branch feature/<slug>)
├── orca-<slug>-W1/               # one worktree per in-flight item (branch feature/<slug>-W1)
└── .orca/
    ├── config.json               # optional per-repo model/effort overrides
    ├── briefs/                   # unconsumed briefs (drafts/ for parked ones)
    └── YYYYMMDD-HHMMSS-<slug>/   # one directory per run
        ├── brief.md              # the consumed brief — moved here when the run starts
        ├── spec.md               # spec, work breakdown, Decisions log, workflow runId
        ├── report.md             # final run report
        ├── plans/                # one plan per item, with its Deviations section
        └── reviews/              # raw findings JSON per review round (codex or claude)
```

Two naming namespaces, deliberately different: `orca-*` **directory** names are local scratch — the cleanup and discovery story via `git worktree list` — and never enter git; `feature/<slug>[-<ID>]` **branch** names are what lands in history and on GitHub, and carry no orca trace. `.orca/` sits outside every worktree, so its contents cannot be committed by accident.

## Stage agents

Nine agents ship in the plugin (`agents/<stage>.md`, loaded as `orca:<stage>`). Each runs with its own context window and only the per-item values it needs; context passes between stages through artifact files, never relayed summaries.

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

A present `reviewer` key **pins** the choice; an absent key means each launch **detects** (codex on PATH at the minimum version → codex, else claude). The `agents` overrides sit on top of the agent defaults.

**`MCP_TOOL_TIMEOUT`** — codex-only: client-side session env governing MCP tool-call timeouts; a plugin cannot ship it, so `/orca:doctor` writes it into the `env` block of `.claude/settings.local.json` (or `~/.claude/settings.json`):

```json
{ "env": { "MCP_TOOL_TIMEOUT": "1200000" } }
```

~20 minutes is deliberate: the workflow retries reviews at two levels, so this value multiplies into the per-item worst case (~80 minutes at this setting; an hour would balloon it to several). Settings env loads at **session start** — restart the session after writing it.

**Bundled `.mcp.json`** — registers the codex MCP server as the global PATH binary, nothing else:

```json
{ "mcpServers": { "codex": { "command": "codex", "args": ["mcp-server"] } } }
```

## Permissions and autonomy

A run only stays autonomous if the harness never raises a permission prompt: every workflow-spawned subagent inherits the session's permission mode, a single foreground prompt breaks autonomy mid-run, and an auto-denied call makes an agent fail confusingly instead.

**This requires `bypassPermissions` mode — an allow-list is not sufficient.** The subagents decide commands at runtime (dependency installs, build/test variants, assorted git invocations), so the command set is open-ended; and Bash permission rules match as prefix globs against the literal command string, so listed commands still slip through when they contain `$(…)`, lead with flags, or are compound. A leaked prompt is a question of *when*, not *whether*.

Enable it one of three ways: Shift+Tab in-session until the footer shows "bypass permissions" (easiest, right before the run); `claude --dangerously-skip-permissions` at launch; or `"permissions": { "defaultMode": "bypassPermissions" }` in `.claude/settings.local.json` for always-unattended repos (offered by `/orca:doctor`, never defaulted).

The tradeoff is real and `/orca:run` states it before starting: bypass mode disables the approval gate for the **whole session**, not just the run — a dedicated session for the run is the clean choice. If you won't enable it, the run does not start; it would only pause partway.

## Interruption, resume, and cleanup

Every agent call in the work loop is journaled, and the workflow `runId` is persisted to the end of `spec.md` (as `**Workflow run:** <runId>`, alongside the launch-time reviewer as `**Workflow reviewer:**` and the launch-time `agents` block when one was passed) the moment the workflow launches — precisely because the interruption that needs it, session death, also erases the conversation. A resume replays those recorded values, never the current `.orca/config.json`.

- **Interrupted run** (session death, kill, harness restart): re-invoke `/orca:run`'s workflow with the same script and args plus `resumeFromRunId`, rebuilt from `spec.md` — the skill knows this procedure; you just ask it to resume. Completed agent calls replay instantly from the journal; only in-flight and remaining work runs live. Never re-run stages conversationally.
- **Blocked items** keep their worktree and branch deliberately — the report lists them for a follow-up run.
- **Abandoned run**: `git worktree list`, remove leftover `orca-*` worktrees and their `feature/<slug>*` branches. Prefer resuming.
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
| `/orca:run` says the codex MCP tool doesn't resolve | MCP servers load at session start. Check the plugin is installed and enabled, then start a fresh session in the project. |
| `/orca:run` says the harness has no Workflow tool | The work loop needs a Claude Code harness with workflows; there is no conversational fallback. |
| Run pauses on a permission prompt | The session wasn't in `bypassPermissions` mode. Enable it (Shift+Tab) and resume via the journal rather than restarting. |
| `/orca:run` finds no brief | Runs start only from a brief. Run `/orca:brief <idea>` first; `/orca:run` discovers it automatically. |
| `git fetch` does nothing in a bare clone made by hand | Bare clones get no fetch refspec. `/orca:init`'s clone path sets `remote.origin.fetch` — do the same, or re-clone through it. |

## Migrating from the pre-plugin skills

This repository previously shipped the same workflow as symlink-installed skills named `briefify`/`initify`/`orchestrify` (plus a Codex CLI variant, now scrapped). If you used those:

- Remove the old symlinks from `~/.claude/skills` and `~/.claude/agents`.
- Queued briefs migrate with `mv .orchestrify .orca` at the repo root.
- In-flight pre-migration runs cannot resume under the plugin — clean up any leftover `orchestrify-*` worktrees and start fresh from a new brief.

## Repository contents

| Path | Contents |
|---|---|
| `.claude-plugin/plugin.json` | The plugin manifest (`orca`). |
| `.mcp.json` | Bundled codex MCP server registration — the global PATH `codex` binary, never npm. |
| `skills/brief/`, `skills/init/`, `skills/doctor/`, `skills/run/`, `skills/config/` | The five skills. |
| `skills/run/scripts/preflight.sh` | Read-only environment validation — the gate lines above. |
| `skills/run/scripts/work-loop.workflow.js` | The deterministic work loop, run through the Workflow tool. |
| `agents/` | The nine stage agents, loaded as `orca:<stage>` (the reviewers are `review-codex` and `review-claude`). |
