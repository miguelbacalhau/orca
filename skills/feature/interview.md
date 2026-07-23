# Orca: feature — the interview

This file is read by the orca:feature skill when its triage finds no interrupted run and no queued brief: the idea at hand has no captured intent yet, so capture it as a durable brief file. Every run starts from a brief, discovered on disk and confirmed once. The interview is where intent gets captured — unhurried, adversarial about scope, and free to span as many rounds as the idea needs. The product is a brief in exactly the shape the run's opening confirmation (Step 1 of `SKILL.md`) restates, so the run starts with a single yes.

The brief is *what and why* — human intent, including the direction decisions the discussion settles. It is not *how it maps onto the codebase*: interfaces, work breakdown, and file ownership belong to the run's spec stage, which grounds them in real codebase exploration. A breakdown written here would be a guess, and a guessed decomposition is where parallel-agent runs go wrong. The interviewer, however, is not forbidden from knowing the system — the opposite: good questions come from friction between the idea and the code as it exists, so the interview researches first and asks from that picture.

## Input

The user provides a rough idea, usually as the `<idea>` argument to `/orca:feature`. If no idea was provided, ask what they want to build.

## Step 1: Research

Before asking the user anything substantive, build a picture of the part of the system the idea touches. All of it stays out of the main context — the same rule the run itself lives by: heavy exploration lives and dies in subagents.

Spawn **one `orca:research` subagent**, passing: the repository root, the idea verbatim, and — when `<repo-root>/.orca/map.md` or `.orca/decisions.md` exists — a `Project context:` line naming whichever of the two exist. Only check that the files exist; do not read them in the main context — the agent scopes its own exploration from the idea plus the map, and its definition owns the report's shape: current behavior, decisions touched, tensions, unknowns.

The report is context for you, the interviewer — never shown raw to the user, never persisted. Whatever matters from it lands in the brief through the conversation; the safety valve for researcher error is the opening reflection below, which states the picture of the current system explicitly enough that a wrong picture is visible and correctable in one exchange.

If the `orca:research` agent fails or the repository offers nothing to explore, this step is non-fatal: fall back to the intent-only interview — the discussion below still applies, minus the research-grounded reflection.

Research always runs, even when the `<idea>` argument is rich and detailed — a detailed idea still benefits from the tension list, and the cost is one subagent. What a rich idea changes is the *discussion's* depth, not the research (see pacing).

A side benefit worth acting on: if the research shows the codebase fights the idea — an approach the architecture resists, a feature that would force an interface the code refuses — say so now, in conversation, where changing course is cheap. Discovered here, it shapes the brief; discovered at the spec stage, it kills a run after confirmation and spec spend.

## Step 2: Discuss

**Open with an informed reflection, not a batch of questions.** The first message reflects the idea back against the research:

- what the system does *today* in the touched area, stated explicitly — this is the correctability valve: if the research got it wrong, the user sees it here and fixes it in one reply;
- the two or three shapes the idea could take against that reality, and what each implies ("the current middleware has no user identity at that layer — extend it, or hang this elsewhere?");
- the tensions the research found, named plainly.

Then ask about the single most load-bearing unknown. The research output is the question generator, and it yields three kinds of questions:

- **Direction questions** — which of the possible shapes the user actually wants, and why.
- **Decision questions** — "the decision log says X was chosen deliberately — does this idea overturn that?" A decision the user overturns here becomes brief content, never an edit to the log.
- **Unknown questions** — the things neither the idea nor the code decides; every one resolved here is one the autonomous run will not have to guess at against the doubt rule.

**Pacing — hard form constraints, not suggestions:**

- At most 2–3 open-ended questions per round, each grounded in the previous answer. The interview is multi-round by design; it ends when you can restate the intent with no gaps and the user has nothing to add, not when a topic list is exhausted.
- Never batch the coverage topics into one round. The list below is coverage to have reached *by the end of the discussion*; administering it as a form is exactly the failure this interview is designed against.
- **AskUserQuestion is banned for substantive discussion.** Its 2–4 canned options convert an open interview into multiple choice. It is permitted only at the end, for the two genuinely multiple-choice items — the doubt rule and the breakdown checkpoint — once the substantive discussion is done.
- Depth proportional to what's missing: a rich `<idea>` argument gets the reflection plus a couple of sharp questions; a one-liner gets the full multi-round interview. Never re-ask what the idea already answers.

Coverage to reach by the end — through conversation, not as a checklist:

- The desired outcome: what exists when this is done that does not exist now.
- The features it must have, and explicitly which it must not.
- Direction: which shape the idea takes against the current system, where the discussion had shapes to choose between — with the *why* behind each choice.
- Inputs and outputs: what data, events, or user actions go in; what results, side effects, or artifacts come out.
- Constraints: existing code it must integrate with, performance or compatibility expectations, deadlines on scope.
- The doubt rule: when the run hits an ambiguity, should it prefer the smaller interpretation and cut scope, or the more complete one? Default to smaller if the user has no preference.
- The breakdown checkpoint: when the run's spec and work breakdown are written — before any code — do they want to review it once, or go straight through autonomously? Default to straight through.

Push back throughout. Play devil's advocate on scope, hunt for unstated non-goals, and use the research to make ambiguities concrete: a named tension the user must resolve beats a generic "any non-goals?" every time.

Stay at intent level in what you *write down*: direction decisions with their rationale are brief content; interfaces, work items, and file ownership are not — grounding the decomposition in code is the spec stage's job, with fresh context and real exploration. If the conversation turns into walking the user through source at length, it has drifted from *what* into *how*; steer it back.

## Step 3: Early pre-flight (optional, never blocking)

Run the run's environment pre-flight now, from the project root — it ships in this plugin:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh preflight
```

This is an early warning, not a gate: a `FAIL` here is something to fix before the *run*, at leisure — it never blocks writing the brief. It also spares a second run: if the brief runs now, the run's own environment pre-flight reuses this output rather than re-running the script. Report any failing gate and point at the right fixer — orca:init for the layout gate (`BARE_REPO`), orca:doctor for the machine gates (`CODEX`, an invalid `REVIEWER`) — then continue. A `CODEX: SKIPPED` line just means the run will use the Claude reviewer; nothing to fix.

## Step 4: Write the brief

Resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir`, create `.orca/feat-briefs/` there if needed, and write the brief to:

```text
<repo-root>/.orca/feat-briefs/<YYYYMMDD-HHMM>-<slug>-<h4>.md
```

Generate the timestamp with `date +%Y%m%d-%H%M`; make `<slug>` a short kebab-case description, 3-5 words max; `<h4>` is a 4-hex disambiguator (`printf '%04x' "$RANDOM"`), because minute precision alone collides when two briefs on the same idea land in the same minute — a collision would silently overwrite a queued brief. The timestamped filename is what triage lists during discovery, so the name alone must identify the brief.

```markdown
# Brief: <title>

**Created:** <YYYY-MM-DD HH:MM>

## Outcome

<What exists when this is done. One to three paragraphs.>

## Features

- <Required capability>

## Non-goals

- <Explicitly excluded scope — with the why, where one was discussed>

## Direction

- <Direction decision the interview settled, with its rationale — e.g.
  "extend the existing export path rather than adding a parallel one —
  keeps one auth surface". Omit the section if the discussion settled
  no direction decisions.>

## Inputs & Outputs

- **In:** <data, events, or actions>
- **Out:** <results, side effects, or artifacts>

## Constraints

- <Integration point, compatibility expectation, or scope bound — with
  the why, where one was discussed>

## Doubt Rule

<prefer-smaller-scope or prefer-complete>

## Breakdown Checkpoint

<review-once or straight-through>
```

Use `date +"%Y-%m-%d %H:%M"` for the `Created` line — it survives the file's later move into a run directory, and the run uses it to warn when a brief has gone stale.

**The quality bar:** the spec agent must be able to act on the brief without guessing. Every tension and unknown the research surfaced appears either *resolved* — in Direction, Constraints, or Non-goals — or *explicitly delegated* to the doubt rule. The brief carries reasoning, not just conclusions: a non-goal with its why survives contact with an autonomous run; a bare bullet invites reinterpretation.

Read the written brief back to the user in summary and incorporate corrections until they approve it. Their approval is what makes the file authoritative — a later orca run treats it as the whole of their intent.

There is no status field. Location is status: everything at the top level of `.orca/feat-briefs/` is ready and unconsumed, and the run moves a brief into its run directory when it starts from it. If the discussion needs another sitting, park the file in `.orca/feat-briefs/drafts/` instead and move it up one level when it is done — triage only discovers the top level.

## Step 5: Hand back

The brief is written and approved. Return to `SKILL.md`'s run-now-or-queue question (the end of Step 0) — whether this brief starts its run now or waits queued is the user's call, made there. The run's own pre-flight and confirmation gates run in the same skill, so there is nothing to hand off.

## Guidelines

- One brief is one run's scope. If the discussion uncovers two independent efforts, write two briefs.
- Never write Interfaces, a Work Breakdown, or file ownership into a brief — that is the spec stage's job, grounded in its own fresh exploration. The interview's research informs the *questions*, never a decomposition: it is scoped by the idea, not by decomposition needs, and a breakdown from it would still be a guess.
- The research report is disposable. It is never persisted (it would rot immediately and tempt the spec agent to trust it instead of re-exploring) and never pasted to the user; whatever mattered lands in the brief.
- Briefs may pile up; that is the point. Each is consumed by the run it starts and archived in that run's directory.
