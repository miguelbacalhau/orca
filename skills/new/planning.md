# Orca: objective — the planning gate

This file is read by `/orca:new` and `/orca:open` when an objective with no open decision is ready to plan: the user said go, or a decision that blocked the loop has been settled — then the blocked phase goes back through planning with the pending ones, rewritten as pending under its own id. It turns the objective's decided work into reviewed sequential phases and ends at **the one confirmation before the loop**. Every step is delegated: a planner writes the proposal, a verb validates it, an independent reviewer attacks it. You sequence them, never read the proposal or the findings yourself, and never edit `phases.md` — only `objective plan-accept` installs a plan.

You hold, from the skill that loaded this file: the objective directory `<dir>`, the `worktree` from this session's `objective open` frame, and the `reviewer` (with `codex`, `codex_fix`) from its reviewer check (`${CLAUDE_PLUGIN_ROOT}/skills/new/provision.md`). When you no longer hold them, run that check again as it says. Every spawn runs in the background: wait for its notification, and never fabricate a result. Shell calls go through `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh` with your own Bash tool.

**The reviewer** is the held `reviewer`. When it is `fail`, or `codex` with the result's `codex: fail`, the review cannot run: say so, and ask the user to fix it (`/orca:doctor` walks every remediation, `/orca:config` picks a reviewer) and then run that file's reviewer check again, or to go on with the plan unreviewed. Never switch reviewers on the user's behalf.

**The pass number** `<n>` names this pass's review artifact, `<dir>/plan/review-<n>.json`: one more than the highest `n` already in `<dir>/plan/` (`ls`), 1 when there is none. Hold it for the whole pass; a revise round is part of the same pass.

**Where to start.** When `<dir>/plan/proposed.md` already exists — a pass that stopped before the confirmation — and neither `<dir>/decisions.md` nor `<dir>/objective.md` is newer than it (`[ <dir>/decisions.md -nt <dir>/plan/proposed.md ] || [ <dir>/objective.md -nt <dir>/plan/proposed.md ]` fails), the proposal still reflects the objective and its decisions: skip the planner and start at the check in Step 1, reviewing it as a new pass. Otherwise — a decision, the outcome, a non-goal, or a constraint changed since — start at Step 1.

## Step 1: Plan

Spawn one `orca:phases` agent. Its task message — hold it, every re-spawn below starts from it:

```text
Objective directory: <dir>
Objective: <dir>/objective.md
Decisions: <dir>/decisions.md
Phases: <dir>/phases.md
Worktree: <worktree>
Output path: <dir>/plan/proposed.md
```

It returns `{written, phases, reason}`. Hold `reason` for the confirmation. `written: false` → relay the reason: one that names an open decision, or a decided direction the code cannot support, goes back to the discussion — the user settles it, and this file runs again. Any other cause: spawn it once more; a second failure goes to the user.

**The check.** Validate the proposal without installing it:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective plan-accept <dir> --check
```

On success its frame lists the proposed phases: `phases`, and for each `i`, `phase.<i>.id`, `phase.<i>.title.b64`, and `phase.<i>.acceptance` (the acceptance-line count). Hold it for the confirmation. A typed `FAIL:`:

- `PLAN_REWRITES_DONE`, `PLAN_BAD_ID`, `PLAN_BAD_PHASE`, `PLAN_UNDECIDED`, `PLAN_DROPS_WORK`, `PLAN_BAD_ORDER` — the proposal broke a rule. Spawn `orca:phases` once more, the held task message plus one line, `Check failure: <reason> — <detail>`, then check again. A second failure goes to the user with the reason and detail: back to the discussion, or stop.
- `DECISION_OPEN` — a decision is open: back to the discussion. `PHASE_ACTIVE` — a phase is mid-loop: planning waits until it is done or blocked; tell the user. Anything else (`NO_PLAN`, `ARCHIVED`, `BAD_DIR`, …) — relay it and stop.

## Step 2: Review

1. `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets remove <worktree>` — the reviewer reads adversarial content and needs no credentials.
2. Spawn a fresh `orca:phases-review-<reviewer>`. Its task message: the worktree, the objective directory `<dir>`, the artifact path `<dir>/plan/review-<n>.json`, and — for codex — the plugin root, `${CLAUDE_PLUGIN_ROOT}` substituted.
3. `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets place <worktree>` — on every path out of the review, the reviewer's failure included.

`secrets` failing `OUTSIDE_ROOT` means orca never placed secrets in that checkout — carry on. Any other typed `FAIL:` from `secrets remove` stops the review before the reviewer spawns: tell the user, and stop.

The reviewer returns `{written, total, criticalHigh, reason}`. `written: false`, or an impossible count (`criticalHigh` above `total`) → run the review once more, **all three steps again**: `secrets remove`, a fresh reviewer, `secrets place` — never a reviewer spawned while secrets are placed. A second failure **fails open**: the plan goes to the confirmation unreviewed, with both reasons as one status line — a dead reviewer never bricks planning, and the user's confirmation and every phase's own review rounds still stand.

**`criticalHigh > 0`** → exactly one revise round: spawn `orca:phases` with the held task message plus:

```text
Revise round: an independent review of the proposal found <criticalHigh> Critical/High finding(s).
Findings: <dir>/plan/review-<n>.json
```

Then the check again, with Step 1's handling. There is no re-review — the revision is final, and the user confirms it next. A revise spawn that returns `written: false` leaves the earlier proposal and its findings standing: say so at the confirmation. Medium/Low findings never trigger a revise round.

## Step 3: Confirm

The remaining findings, by title, from the verb — never from the file:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh rounds summary <dir>/plan/review-<n>.json
```

Its frame: `total`, `shown`, `more`, and per finding `finding.<i>.severity` and `finding.<i>.title.b64`. Skip it when the review failed open.

Show the user, in a few lines:

- **The phases** from the held check frame, in order: id, title, acceptance-line count. Done phases, and blocked ones whose decision is still not decided, are not listed; the frame's `kept` counts them. A phase that was blocked on a decision since decided is listed with the rest, rewritten — the frame's `unblocked` counts those; name them as unblocked.
- **The planner's `reason`** when it is not empty — pending work it dropped and why, a finding it rebutted, the next step it stopped at.
- **The review:** the reviewer, `total` and `criticalHigh`, whether the revise round ran, and the summary's severities and titles (`more` counted) — or that it failed open, with the reason, or that the revision died and the findings stand.
- The full proposal is at `<dir>/plan/proposed.md`. Read one phase entry from it only when the user asks about that phase (`sed` on its heading), never the whole file.

Ask once: **run this plan?**

- **Yes** → install it:

  ```bash
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective plan-accept <dir>
  ```

  Success → return to the skill that loaded this file; the loop runs next. The verb also rewrites `report.md`'s `## Blocked` to the phases still blocked. A typed `FAIL:` here means something changed since the check: handle it as Step 1's check failure does.
- **Changes** → back to the discussion. Every change the user wants — a phase split, a dropped piece, a different order, a new direction — is written as a decision in `decisions.md` (new, or a revised one), because the planner reads files, not the conversation. Then this file runs again from Step 1, as a new pass.
- **Not now** → stop. The proposal stays; the objective lists as `planning`, and `/orca:open` returns here.

## Guidelines

- You never read `plan/proposed.md` whole, never read `plan/review-<n>.json`, and never edit `phases.md` or the proposal. Titles come from `rounds summary` and the check frame.
- The confirmation is the only place the user approves a plan. Nothing is installed before their yes, and nothing runs before `plan-accept` succeeds.
- A Critical/High finding is never declined on the user's behalf: the revise round addresses or rebuts it, and whatever stands is shown at the confirmation for the user to weigh.
