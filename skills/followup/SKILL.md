---
description: Turn a finished orca:feature run's leftovers into the next run's brief. Picks a finished run (newest by default, or the one named), audits it through a subagent — reconciling the report's claims against the spec's work breakdown and git ground truth, so a run that blocked early is caught even if its report is optimistic — then discusses only what is genuinely open: the decisions the run escalated to the user, and which optional follow-ups ride along; unfinished work items are in unless the user cuts them. The product is a standard brief queued in `.orca/feat-briefs/` that `/orca:feature` discovers, restates, and runs — this skill never launches a run itself. Continuation facts (the integration branch to build on, the prior spec and Decisions log as binding inputs, reusable plans and kept worktrees, recorded plan corrections) land in the brief's Direction and Constraints sections. Interrupted runs are redirected to `/orca:feature`'s resume, never duplicated. Do not use for debug runs, or for new ideas unrelated to a past run — that is `/orca:feature`'s interview.
args: <optional run directory or slug fragment>
user-invocable: true
disable-model-invocation: true
---

# Orca: followup

A finished run leaves three kinds of unfinished business: work items that blocked and never merged, decisions the run explicitly escalated to the user, and follow-ups the reviews flagged but did not block on. This skill converts them into the one artifact the rest of orca already knows how to consume — a brief at the top level of `.orca/feat-briefs/`, discovered and run by `/orca:feature` like any other. Nothing else in the machinery changes or is bypassed: the brief is standard, feature's triage owns confirmation and launch, and location is status.

Two rules shape everything here. First, **the report is a claim, not ground truth** — the audit reconciles it against the spec's work breakdown and against git before anything is discussed, so a run that ended early is picked up from what actually merged, not from what the report says. Second, **interview only over what is genuinely open** — the original brief, spec, and Decisions log already settled intent; re-asking it wastes the user's patience and invites drift. What is open: the escalated decisions (the run recorded them precisely because it could not decide), the selection among optional follow-ups, and any new scope the user volunteers.

## Step 0: Pick the run

Discovery runs through the shared triage spine:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/triage.sh discover
```

Read the `DONE:` lines — finished feature runs, oldest first — plus the `RUN:` and `BRIEF:` lines for the triage below. (`FAIL: NOT_GIT` means there is nothing here to follow up; say so and stop.)

- **No `DONE:` lines** — nothing has finished. If a `RUN: <dir> interrupted` line exists, the user's real move is the resume: say the run is interrupted, not finished-partial, and point at `/orca:feature`, which discovers it in triage — never build a brief that duplicates a resumable run. Otherwise point at `/orca:feature` to run something first. Stop either way.
- **An argument** — match it against the `DONE:` run directories (name or slug fragment). One match → that run. No match → a loud miss: list the finished runs, never guess.
- **No argument** — default to the newest (last `DONE:` line). When several runs finished, name the chosen one and list the others in one line — the audit reflection in Step 2 restates the choice, so a wrong default is visible and cheap to correct.

**Already consumed?** Before auditing, grep the chosen run directory's basename across `.orca/feat-briefs/*.md` and `.orca/feat-briefs/drafts/*.md`. A hit means a follow-up brief for this run already exists: surface it — queued briefs are run by `/orca:feature`, drafts are finished by moving them up a level — and ask whether to continue with it or deliberately write another (a second follow-up on the same run is legitimate when the first one's scope was a subset). Report follow-ups have no location-is-status of their own; this scan is the dedup.

## Step 1: Audit

Spawn **one `orca:audit` subagent**, passing the repository root (the parent of `git rev-parse --path-format=absolute --git-common-dir`) and the run directory. The agent reads the run's artifacts, verifies the report's claims against the work breakdown and git, and returns a compact reconciliation as its final message: the verified completion picture, discrepancies, unfinished items with their surviving worktrees/branches, the decisions the run escalated, optional follow-ups, and the reusable artifacts. All heavy reading lives and dies there — the main conversation consumes only the returned report.

The audit is context for you, never shown raw to the user. If the agent fails, fall back to reading `<run-dir>/report.md` and `<run-dir>/spec.md` directly and say plainly that the git verification was skipped — a degraded but honest basis beats a dead end.

## Step 2: Discuss

**Open with the verification verdict, then the buckets.** The first message states: which run this is and what it set out to do; what verifiably landed and what did not (from the audit, with any report-vs-git discrepancies named plainly — this is the correctability valve, same as the interview's reflection); and the three buckets laid out for decision:

- **Unfinished items** — in by default. They were confirmed scope in the original brief; completing them needs no new consent, only the chance to cut. Present them with their blocked reasons and any recorded correction (the audit quotes the report where the fix is already known — e.g. a plan that needs one seam change); those corrections are settled facts, not questions.
- **Escalated decisions** — must be resolved. These are the questions the run recorded for the user, with their options; the follow-up run would hit the same wall. Ask them with the recorded options quoted faithfully, at most 2–3 per round, grounded in the audit.
- **Optional follow-ups** — a selection, not an obligation. Deferred findings, known gaps, improvements. Ask which ride along; the default for anything unselected is *stays deferred* — it remains in the old report, losing nothing.

Pacing follows the interview's rules: multi-round, at most 2–3 open questions per round, no topic-list batching, and **AskUserQuestion is banned for substantive discussion** — permitted only at the end for the doubt rule and breakdown checkpoint, and only if the user wants to change the inherited values. Depth is proportional to what is open: a run that blocked on a purely mechanical failure with a recorded fix and no escalated decisions needs one confirming round; a run with real decisions needs the rounds they take.

**New scope stays exceptional.** If the user adds work beyond completing the run and its recorded follow-ups, that is interview territory: spawn one `orca:research` agent for the touched area (as `/orca:feature`'s interview does) and fold the findings into the discussion — or, when the new scope dwarfs the continuation, say so and suggest a separate `/orca:feature` interview so the follow-up brief stays a follow-up.

**Nothing open at all** — everything shipped, no escalated decisions, no follow-ups worth a run: say exactly that, congratulate the run, and stop. No brief.

## Step 3: Early pre-flight (optional, never blocking)

Same as the interview's: run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh` from the project root. A `FAIL` is something to fix before the run, at leisure — it never blocks writing the brief; point at `/orca:init` for the layout gate and `/orca:doctor` for machine gates, then continue. If the brief runs now, the run's own pre-flight reuses this output.

## Step 4: Write the brief

The brief uses the standard sections and only the standard sections — `/orca:feature`'s Step 1 restates them by name and its Step 2 passes them to the spec agent by name, so a custom section would silently drop. Continuation content has two natural homes: **Direction** carries the settled continuation decisions, **Constraints** carries the artifact pointers. Write to:

```text
<repo-root>/.orca/feat-briefs/<YYYYMMDD-HHMM>-followup-<slug>.md
```

Generate the timestamp with `date +%Y%m%d-%H%M`; derive `<slug>` from the original run's slug. The format is the interview's:

```markdown
# Brief: <title — "complete <original title>" plus any selected follow-ups>

**Created:** <YYYY-MM-DD HH:MM>

## Outcome

<What exists when this is done: the unfinished items completed, the selected
follow-ups landed, each escalated decision resolved the way the user chose.
Name the prior run directory — it is this brief's provenance.>

## Features

- <Each unfinished item's feature, by its original name>
- <Each selected follow-up>

## Non-goals

- <Everything deliberately left deferred, so the run cannot re-adopt it>
- <Non-goals inherited from the original brief that still bind>

## Direction

- <Continue on the existing integration branch `feature/<slug>` — or, when the
  audit found the deliverable already landed, build on the trunk; state which
  and why.>
- <The prior run's spec at <run-dir>/spec.md is a binding input: its Interfaces
  and its ## Decisions log carry forward; the new spec builds on them rather
  than re-deriving.>
- <Recorded corrections as settled decisions — e.g. "plans/W3.md is reusable
  once its resolveModel seam is async (report.md's Blocked section records
  the exact fix)".>
- <Each escalated decision, resolved: the user's choice and its why.>

## Inputs & Outputs

- **In:** <the prior run's artifacts by path — spec, reusable plans, kept
  worktrees/branches from the audit>
- **Out:** <the completed deliverable branch>

## Constraints

- <Kept item worktrees/branches, listed so the run's worktree reuse ladder
  picks them up rather than starting fresh>
- <Constraints inherited from the original brief that still bind>

## Doubt Rule

<inherited from <run-dir>/brief.md unless the user changed it>

## Breakdown Checkpoint

<inherited from <run-dir>/brief.md unless the user changed it>
```

Use `date +"%Y-%m-%d %H:%M"` for the `Created` line. Inherit the doubt rule and checkpoint from the consumed original brief at `<run-dir>/brief.md` (the audit reports them); state the inherited values when reading the brief back, and only ask — AskUserQuestion permitted here — if the user signals they want them changed. A missing original brief inherits the defaults instead: prefer-smaller-scope, straight-through.

**The quality bar is the interview's:** the spec agent must be able to act on the brief without guessing, and every open point from the discussion appears either resolved — in Direction, Constraints, or Non-goals — or explicitly delegated to the doubt rule. Reasoning included: a resolved decision without its why invites the next run to relitigate it.

Read the brief back to the user in summary and incorporate corrections until they approve it. Their approval is what makes the file authoritative. If the discussion needs another sitting, park it in `.orca/feat-briefs/drafts/` and tell the user moving it up one level readies it.

## Step 5: Run now, or leave it queued?

Ask once, the interview's own closing choice:

- **Run now:** invoke the `orca:feature` skill with no argument — its triage discovers the just-queued brief, and the full restatement and confirmation run there. The brief, not this conversation, is the authorized intent; nothing is skipped by having just written it.
- **Queue:** tell the user the brief is ready and where it lives, and that invoking `/orca:feature` in this repository when ready will find it. End cleanly.
