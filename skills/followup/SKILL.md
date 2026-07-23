---
description: Turn a finished orca:feature run's optional follow-ups — deferred findings, known gaps, improvements the reviews flagged but did not block on — into the next run's brief. Picks a finished run (newest by default, or the one named), audits it through a subagent — reconciling the report's claims against the spec's work breakdown and git ground truth — then discusses only the selection, which follow-ups ride along, and queues a standard brief in `.orca/feat-briefs/` that `/orca:feature` discovers, restates, and runs; this skill never launches a run itself. New intent, not recovery — unfinished work items and escalated decisions are `/orca:retry`'s job (it finishes them inside the same run, on the same branch), and interrupted runs are redirected to `/orca:feature`'s resume, never duplicated. Do not use for debug runs, or for new ideas unrelated to a past run — that is `/orca:feature`'s interview.
args: <optional run directory or slug fragment>
user-invocable: true
disable-model-invocation: true
---

# Orca: followup

A finished run's report carries **optional follow-ups**: deferred findings, known gaps, improvements the reviews flagged but did not block on. This skill converts the ones the user selects into the one artifact the rest of orca already knows how to consume — a brief at the top level of `.orca/feat-briefs/`, discovered and run by `/orca:feature` like any other. Nothing else in the machinery changes or is bypassed: the brief is standard, feature's triage owns confirmation and launch, and location is status.

This is **new intent, not recovery**. A run that finished with unmet work items — blocked items, escalated decisions — belongs to `/orca:retry`, which resolves the recorded decisions with the user and relaunches only the unmet items inside the same run; an interrupted run (no report yet) belongs to `/orca:feature`'s resume. Both are enforced in Step 0. What this skill owns is the run's *aftermath by choice*: work the run never promised, riding on a delivered feature.

Two rules shape everything here. First, **the report is a claim, not ground truth** — the audit reconciles it against the spec's work breakdown and against git before anything is discussed, so the brief builds on what actually landed. Second, **interview only over what is genuinely open** — the original brief, spec, and Decisions log already settled intent; what is open here is exactly the selection among optional follow-ups, and any new scope the user volunteers.

## Step 0: Pick the run

Discovery runs through the shared triage spine:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/triage.sh discover
```

Read the `DONE:` lines — finished feature runs, oldest first, each tagged `clean`, `leftovers`, or `unknown` from its report's `## Blocked` section — plus the `RUN:` and `BRIEF:` lines for the triage below. (`FAIL: NOT_GIT` means there is nothing here to follow up; say so and stop.)

- **No `DONE:` lines** — nothing has finished. If a `RUN: <dir> interrupted` line exists, the user's real move is the resume: say the run is interrupted, not finished-partial, and point at `/orca:feature`, which discovers it in triage — never build a brief that duplicates a resumable run. Otherwise point at `/orca:feature` to run something first. Stop either way.
- **An argument** — match it against the `DONE:` run directories (name or slug fragment). One match → that run. No match → a loud miss: list the finished runs, never guess.
- **No argument** — default to the newest (last `DONE:` line). When several runs finished, name the chosen one and list the others in one line — the audit reflection in Step 2 restates the choice, so a wrong default is visible and cheap to correct.

**The chosen run has `leftovers`** — or the Step 1 audit finds unmet items regardless of the tag: say the run has unmet work and point at `/orca:retry`, which finishes it inside the same run. If the user insists on a follow-up brief anyway, continue with **only** the optional follow-ups — the two surfaces are independent, and a follow-up brief must never adopt unmet items or resolve escalated decisions; those stay `/orca:retry`'s.

**Already consumed?** Before auditing, grep the chosen run directory's basename across `.orca/feat-briefs/*.md` and `.orca/feat-briefs/drafts/*.md`. A hit means a follow-up brief for this run already exists: surface it — queued briefs are run by `/orca:feature`, drafts are finished by moving them up a level — and ask whether to continue with it or deliberately write another (a second follow-up on the same run is legitimate when the first one's scope was a subset). Report follow-ups have no location-is-status of their own; this scan is the dedup.

## Step 1: Audit

Spawn **one `orca:audit` subagent**, passing the repository root (the parent of `git rev-parse --path-format=absolute --git-common-dir`), the run directory, and that **orca:followup** is asking. The agent reads the run's artifacts, verifies the report's claims against the work breakdown and git, and returns a compact reconciliation as its final message: the verified completion picture, discrepancies, unfinished items, optional follow-ups, and the reusable artifacts — including whether the deliverable branch was already landed, which decides what the brief builds on. All heavy reading lives and dies there — the main conversation consumes only the returned report.

The audit is context for you, never shown raw to the user. If the agent fails, fall back to reading `<run-dir>/report.md` and `<run-dir>/spec.md` directly and say plainly that the git verification was skipped — a degraded but honest basis beats a dead end.

## Step 2: Discuss

**Open with the verification verdict, then the selection.** The first message states: which run this is and what it set out to do; what verifiably landed (from the audit, with any report-vs-git discrepancies named plainly — this is the correctability valve, same as the interview's reflection); and the **optional follow-ups** laid out for selection — deferred findings, known gaps, improvements. Ask which ride along; the default for anything unselected is *stays deferred* — it remains in the old report, losing nothing. A selection, not an obligation.

Pacing follows the interview's rules: multi-round, at most 2–3 open questions per round, no topic-list batching, and **AskUserQuestion is banned for substantive discussion** — permitted only at the end for the doubt rule and breakdown checkpoint, and only if the user wants to change the inherited values. Depth is proportional to what is open: a short follow-up list needs one confirming round.

**New scope stays exceptional.** If the user adds work beyond the recorded follow-ups, that is interview territory: spawn one `orca:research` agent for the touched area (as `/orca:feature`'s interview does) and fold the findings into the discussion — or, when the new scope dwarfs the follow-ups, say so and suggest a separate `/orca:feature` interview so the follow-up brief stays a follow-up.

**Nothing open at all** — no follow-ups worth a run, nothing selected: say exactly that, congratulate the run, and stop. No brief.

## Step 3: Early pre-flight (optional, never blocking)

Same as the interview's: run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh preflight` from the project root. A `FAIL` is something to fix before the run, at leisure — it never blocks writing the brief; point at `/orca:init` for the layout gate and `/orca:doctor` for machine gates, then continue. If the brief runs now, the run's own pre-flight reuses this output.

## Step 4: Write the brief

The brief uses the standard sections and only the standard sections — `/orca:feature`'s Step 1 restates them by name and its Step 2 passes them to the spec agent by name, so a custom section would silently drop. What remains legitimately continuation-shaped for new scope building on a delivered feature: where to build (the existing integration branch or the trunk, per the audit's landed-ness check) and the prior spec's Interfaces and Decisions as binding inputs — those land in **Direction**. Write to:

```text
<repo-root>/.orca/feat-briefs/<YYYYMMDD-HHMM>-followup-<slug>.md
```

Generate the timestamp with `date +%Y%m%d-%H%M`; derive `<slug>` from the original run's slug. The format is the interview's:

```markdown
# Brief: <title — the selected follow-ups, in one line>

**Created:** <YYYY-MM-DD HH:MM>

## Outcome

<What exists when this is done: the selected follow-ups landed. Name the
prior run directory — it is this brief's provenance.>

## Features

- <Each selected follow-up>

## Non-goals

- <Everything deliberately left deferred, so the run cannot re-adopt it>
- <Non-goals inherited from the original brief that still bind>

## Direction

- <When the audit found the deliverable still an open integration branch,
  set the exact field feature Step 3 reads — `**Base branch:** feature/<slug>`
  — so the new run's integration worktree is based on its tip and contains
  the feature being extended. When the deliverable already landed, omit the
  field (the run bases on the trunk as usual). State which case applies and
  why.>
- <The prior run's spec at <run-dir>/spec.md is a binding input: its
  Interfaces and its ## Decisions log carry forward; the new spec builds on
  them rather than re-deriving.>

## Inputs & Outputs

- **In:** <the prior run's artifacts by path — spec, report, the plans a
  follow-up builds on>
- **Out:** <the deliverable branch>

## Constraints

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
