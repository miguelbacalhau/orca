---
name: orchestrify
description: Drive a feature from idea to committed code using dedicated subagents per stage. Use when Claude should interview the user for the desired outcome, then run fully autonomously, write a spec with a dependency-ordered work breakdown, and for each unblocked work item spawn agents to plan and implement, review with an independent cross-model Codex reviewer and a Claude fix agent, and commit in its own git worktree branched off a shared bare repository, with a merge agent integrating completed items into an integration worktree. Requires a bare-repo-with-worktrees layout (validated up front); there is no privileged main checkout, and the run's deliverable is a branch the user lands themselves. After the interview — plus one optional breakdown checkpoint the user opts into during it — nothing else asks the user anything; undecidable issues are reported at the end. Do not use for small single-file changes or when the user only wants a spec or a plan.
args: <idea>
user-invocable: true
---

# Orchestrify

Coordinate a full implementation through isolated subagents. The main conversation acts as the orchestrator: it owns the spec, the work state, and all user interaction. All heavy context — codebase exploration, diffs, test output — lives and dies inside subagents. The orchestrator only reads artifact files and agent summaries.

Isolation is double: each subagent has its own context window, and each work item has its own git worktree. The repository is a bare repo, and every working copy — the user's, the run's integration tree, and each item — is a peer worktree off that one shared object store. There is no privileged main checkout: the orchestrator never reads or writes the user's worktree, and the run's deliverable is a branch the user lands themselves. Parallel items can never corrupt each other's files — overlap surfaces as an explicit merge conflict, resolved by a dedicated merge agent with both items' plans in hand.

The interview is where the user sets intent. They may also opt into a single checkpoint there: a one-time review of the spec and work breakdown before any code is written. Apart from that opt-in checkpoint, never ask the user anything — no mid-run clarifications, no approval gates, no AskUserQuestion. Status updates are one-way reports. Anything the orchestrator cannot decide within the interview's stated intent becomes a `blocked` item surfaced in the final report.

## Input

The user provides a rough idea, usually by invoking `$orchestrify` with a short objective.

If no idea is provided, ask what they want built.

## Step 1: Elicit requirements

Interview the user before writing anything. This is the only chance to capture intent — once it ends, the run is autonomous and every later ambiguity gets resolved against what was said here. Ask about, in one or two compact rounds:

- The desired outcome: what exists when this is done that does not exist now.
- The features it must have, and explicitly which it must not.
- Inputs and outputs: what data, events, or user actions go in; what results, side effects, or artifacts come out.
- Constraints: existing code it must integrate with, performance or compatibility expectations, deadlines on scope.
- The doubt rule: when the run hits an ambiguity, should it prefer the smaller interpretation and cut scope, or the more complete one? Default to smaller if the user has no preference.
- The breakdown checkpoint: after the spec and work breakdown are written — but before any worktree or code — do they want to review and approve it once, or go straight through autonomously? The decomposition (interfaces, work split, dependency order) is where parallel-agent mistakes originate, so this is the highest-value moment to catch a wrong assumption, and it is the only optional pause in the run. Default to going straight through if the user has no preference.

Close the interview by restating the understood outcome, features, non-goals, doubt rule, and breakdown-checkpoint choice, and confirming them. That confirmation authorizes the run. If the user opted into the breakdown checkpoint, the only remaining interaction is that one approval in Step 3; otherwise there is no later gate at all. From this point on, never ask the user anything else; proceed on recorded assumptions.

### Environment pre-flight (script)

Three of the run's prerequisites are mechanical and validated by one bundled script — the bare-repo layout, the Codex reviewer, and the installed subagent definitions. Run it during the interview, before the closing confirmation, from the project root:

```bash
bash ~/.claude/skills/orchestrify/scripts/preflight.sh
```

That is the default install path; if the skill is installed elsewhere, run `preflight.sh` from this skill's own `scripts/` directory. The script is read-only and prints one line per gate plus a final result:

- `BARE_REPO: PASS|FAIL` — the project is a bare repository with worktrees.
- `TRUNK_CANDIDATE: <branch>` — informational, not a gate: the bare repo's default branch, the run's likely trunk. Confirm the trunk with the user; the integration branch is created from its tip.
- `CODEX: PASS|FAIL` — the Codex CLI is installed and authenticated.
- `AGENTS: PASS|FAIL` — all seven subagent definitions are installed.
- `RESULT: PASS|FAIL` — mirrored by the exit code, which is 0 iff every gate passed.

On `RESULT: PASS`, proceed. On any `FAIL`, do not start — relay the failing gate's remediation below and stop. These are pre-flight gates, not mid-run questions.

**Why each gate, and how to fix a `FAIL`:**

- **Bare repo** is the substrate the entire run depends on: every working copy — the user's, the integration tree, each item — is a peer worktree off one shared bare object store, so there is no privileged main checkout to corrupt. A `FAIL` means the repo is a conventional checkout. Converting it is the user's decision — surface the steps, do not do it autonomously: move the existing `.git` into a `.bare/` directory, add a top-level `.git` file containing `gitdir: ./.bare`, run `git --git-dir=.bare config core.bare true`, then recreate working copies as worktrees (`git --git-dir=.bare worktree add <branch>`).
- **Codex** is the independent, cross-model reviewer in stage 4c — a different model family from the Claude implementer, so it does not share the implementer's blind spots. A missing or unauthenticated `codex` would fail every item at review time, deep into an autonomous run. Fix: install with `npm i -g @openai/codex`, or authenticate with `codex login` (or `codex login --with-api-key`). Installing or authenticating is the user's action — surface the command, do not do it autonomously.
- **Subagent definitions** — every Claude stage is a dedicated subagent type (`orchestrify-spec`, `-plan`, `-implement`, `-fix`, `-commit`, `-merge`, `-integrate`) whose instructions load as its system prompt; the orchestrator spawns by type and passes only per-item values. They ship with the skill and are installed into the Claude agents directory by `install-claude-skills.sh`, which the harness loads at session start. A `FAIL` means the skill is not fully installed — re-run `install-claude-skills.sh` from the skills repo. If they were only just installed this session, the harness may not have picked them up yet; a fresh session loads them.

### Permissions pre-flight

The run only stays autonomous if the harness will not raise permission prompts: subagents inherit this session's permission mode, and the skill's own frontmatter does not propagate to them. A single foreground prompt mid-run breaks autonomy, and an auto-denied call makes an agent fail confusingly instead.

**This requires `bypassPermissions` mode — an allow-list is not sufficient.** The subagents are themselves models that decide commands at runtime (dependency installs, build and test variants, git invocations with assorted flags, `find`, `sed`, and so on), so the command set is open-ended and no static `permissions.allow` list can anticipate it. Beyond that, the harness matches Bash rules as prefix globs against the literal command string, so even listed commands slip through when they contain `$(…)` substitutions, lead with flags like `git --git-dir=…`, or are compound (`cd foo && …`). A leaked prompt is therefore a question of *when*, not *whether* — which is why the fix is the session mode, not the rules.

The skill cannot flip the mode itself, so confirm it during the interview before the closing confirmation: the session must be in `bypassPermissions` mode for the run. Enable it one of three ways:

- **In-session toggle** — press Shift+Tab to cycle the permission mode until the footer shows "bypass permissions". Easiest; do it right before the run.
- **Launch flag** — start the CLI with `claude --dangerously-skip-permissions`.
- **Settings** — `"permissions": { "defaultMode": "bypassPermissions" }` in `.claude/settings.local.json`, for a repo where runs are always unattended.

Make the tradeoff explicit to the user: bypass mode disables the approval gate for the *whole* session, not just orchestrify's commands. That is the point — the run is designed to be unattended — but any other work in the same session loses the gate too, so a dedicated session for the run is the clean choice. If the user will not enable bypass mode, do not start: the run cannot be autonomous, and an allow-list will only let it pause partway.

## Step 2: Write the spec and work breakdown

Create the run directory at the project root — the directory that holds the bare repo and its worktrees. It holds only run metadata. Every worktree lives at the **top level of the repo**, as a sibling of the bare repo and the user's own worktrees — never inside `.orchestrify/`:

```text
<repo-root>/
├── .bare/                              # the bare repository (shared object store)
├── <user worktrees…>                   # e.g. main/ — untouched by the run
├── orchestrify-<slug>/                 # integration worktree (branch orchestrify/<slug>)
├── orchestrify-<slug>-<ID>/            # one worktree per in-flight item (e.g. orchestrify-<slug>-W1)
└── .orchestrify/YYYYMMDD-HHMMSS-<slug>/
    ├── spec.md     # requirements, interfaces, work breakdown
    ├── state.md    # live work-item status, owned by the orchestrator
    ├── report.md   # final run report, written by the orchestrator at the end
    ├── plans/      # one plan file per work item, written by plan agents
    └── reviews/    # one Codex review artifact per item, written by the review stage
```

- `<repo-root>` is the directory containing the bare repo — resolve it as the parent of `git rev-parse --path-format=absolute --git-common-dir`.
- Generate the timestamp by running `date +%Y%m%d-%H%M%S`.
- Make `<slug>` a short kebab-case description of the idea, 3-5 words max.
- Worktree directories sit at `<repo-root>` and are named after their branches: `orchestrify-<slug>` for integration, `orchestrify-<slug>-<ID>` for each item. The `.orchestrify/` metadata is scratch space on disk, outside every worktree, so nothing in it can be committed by accident.

With the run directory scaffolded, **delegate the spec — do not explore the codebase in the orchestrator context.** This is the same rule as every other stage: heavy exploration lives and dies in a subagent, and the orchestrator only reads the artifact that comes back. Spawn one `orchestrify-spec` subagent, passing only:

- the run directory
- the repository root (`<repo-root>`)
- the **interview brief**: the outcome, features, non-goals, inputs/outputs, constraints, and doubt rule exactly as you restated and confirmed them at the close of the interview

That confirmed restatement *is* the brief — pass it faithfully, because it is the whole of the user's intent and every later autonomous decision cites the spec it produces. The agent explores the codebase, defines the shared **Interfaces Between Work Items**, and writes the full spec — outcome, features, non-goals, inputs/outputs, interfaces, a 2-8 item dependency-ordered **Work Breakdown** with file ownership, assumptions, the doubt rule, and risks — to `<run-dir>/spec.md`, returning a short summary. Its exploration dies with its context; only `spec.md` and the summary return, so the orchestrator stays lean for the long autonomous loop ahead. If the agent reports that the requested scope cannot be split cleanly against the codebase — a feature the existing code fights, an interface it forces — resolve it under **Escalation** before proceeding.

The spec agent authors `spec.md` **once**. From here on the orchestrator owns and maintains it: the Decisions log, interface revisions, and breakdown amendments during the run are all orchestrator edits (Step 4's Escalation), never a re-spawn — the sole exception is a structural revision requested at the Step 3 checkpoint, which re-spawns the spec agent (see Step 3).

Read the returned `spec.md` — an artifact, not source — and initialize `state.md` from its Work Breakdown:

```markdown
# State: <idea summary>

| ID  | Item    | Status  | Branch | Commit |
| --- | ------- | ------- | ------ | ------ |
| W1  | <title> | pending | —      | —      |
```

Statuses: `pending` → `planning` → `planned` → `implementing` → `reviewing` → `committed` → `merged`. Failures become `blocked` with a note. An item is only complete — and only unblocks its dependents — when `merged`.

## Step 3: Announce and proceed

Report the spec to the user — outcome, work items, dependency order, what will run in parallel, key assumptions. How this lands depends on the breakdown-checkpoint choice made in the interview:

- **Opted out (the default):** this is a one-way status update. Proceed immediately; do not wait for or request approval — the interview's closing confirmation already authorized the run. If the user interjects on their own, incorporate it; never solicit it.
- **Opted in:** this is the one authorized pause. Present the spec and breakdown and ask once for approval. Incorporate any changes they request: a **structural** revision — re-splitting items, reordering dependencies, reworking an interface — re-spawns the `orchestrify-spec` agent with the current `spec.md` plus the requested changes, because it may need fresh codebase exploration; a **trivial** revision — wording, a renamed item, a tweaked assumption — the orchestrator edits inline. Then proceed. This is the final interactive moment of the run; after it, the run is autonomous and never waits on the user again.

Set the spec status to `approved`. Create the integration worktree at the repo root, on a fresh branch based on the trunk tip:

```bash
git worktree add <repo-root>/orchestrify-<slug> -b orchestrify/<slug> <trunk-branch>
```

Completed items are merged into this branch, and `orchestrify/<slug>` is the run's deliverable — the user lands it onto trunk themselves at the end. The orchestrator never checks out or writes the user's own worktree.

The spec must also record the **doubt rule** from the interview — every later autonomous decision cites it.

## Step 4: Run the work loop

Each work item gets its own git worktree and branch off the shared bare repo, so independent items run fully in parallel — even when they touch overlapping files. As many worktrees as there are unblocked items can be live at once; create one per item and let them run concurrently. Collisions cannot corrupt anyone's work; they surface later as explicit merge conflicts, which the merge agent resolves.

Repeat until every item is `merged` or `blocked`:

1. Collect items whose dependencies are all `merged`.
2. Spawn plan agents for all of them **in parallel** (planning is read-only and safe to parallelize).
3. **Reconcile the plans before any code is written.** When all of this batch's plans are written, read them together — against each other and against the spec's Interfaces — for what no single plan agent could see, since each one explored only its own item: a dependency one plan reveals that the breakdown never declared (an item that actually needs another's output), two plans assuming different shapes for the same shared contract, or heavy real overlap in files both will edit. This is the only moment cross-item knowledge exists before implementation. On a clean pass, proceed unchanged. On a missed dependency or contract mismatch, handle it under **Escalation** (amend: re-order, re-split, or revise the interface, then regenerate the affected plans) before spawning any implementer — catching it here is a re-order; catching it at merge is a semantic conflict.
4. Create each item's worktree at the repo root, branched off the integration branch tip:

   ```bash
   git worktree add <repo-root>/orchestrify-<slug>-<ID> -b orchestrify/<slug>-<ID> orchestrify/<slug>
   ```

   The item branch is `orchestrify/<slug>-<ID>`, not `orchestrify/<slug>/<ID>`: git stores refs as files, so a branch `orchestrify/<slug>` and a branch `orchestrify/<slug>/<ID>` cannot coexist — the first occupies the path the second would need as a directory, and the worktree add fails with `cannot lock ref … exists; cannot create`. Keeping `<slug>-<ID>` as a single leaf segment sidesteps the directory/file conflict.

   Branching off the integration branch only after dependencies are merged guarantees each item builds on its dependencies' actual code.
5. Run implement → review → commit for each item **inside its worktree**, in parallel across items. The implement, fix, and commit stages are Claude subagents; the review stage runs Codex in the same worktree (4c). Every stage for one item shares that one persistent worktree — each Claude agent gets a fresh context, but they must all see the same files, so pass the worktree path explicitly in every prompt and run Codex from inside the worktree.
6. As items reach `committed`, run the merge agent — merges are **serialized**, in dependency order, completion order for siblings.
7. Update `state.md` after every transition. A merge may unblock dependents — re-run step 1.

### 4a. Plan agent (read-only)

Spawn one `orchestrify-plan` subagent per unblocked item, in parallel — planning is read-only and safe to parallelize. The agent's instructions are its definition; the spawn prompt carries only the per-item values:

- the run directory
- the item's ID and title
- the files it owns

The agent reads `spec.md` itself, explores the codebase, and writes its plan to `<run-dir>/plans/<ID>.md`. If the agent reports a spec conflict or infeasibility, go to **Escalation**.

### 4b. Implement agent

Spawn one `orchestrify-implement` subagent for the item, inside its worktree. The spawn prompt carries only the per-item values:

- the worktree path (`<repo-root>/orchestrify-<slug>-<ID>`)
- the run directory
- the item's ID and title
- the files it owns

The agent reads `spec.md` and the plan itself, implements the steps in the worktree, records deviations in the plan file, and runs the plan's Verification commands without committing. If the agent could not complete the item or deviations undermine the spec, go to **Escalation**.

### 4c. Review (independent Codex reviewer) + fix loop

The reviewer is **Codex, not Claude** — a different model family from the implementer. This is the strongest form of the "fresh eyes" this stage needs: the implementer was Claude, so a Claude reviewer still shares its training distribution, priors, and blind spots; Codex does not, so it catches a class of defects a same-family reviewer is systematically blind to. Codex reviews **read-only** and writes its findings to an artifact file; a separate Claude **fix agent** applies the fixes. Reviewer-reports / fixer-fixes stays a hard separation, now across two model families.

**Codex review (read-only, external).** The orchestrator runs this directly — it is a deterministic command like the `git worktree` calls, and Codex's heavy context lives and dies in its own process; only the findings file comes back, so nothing loads into the orchestrator's context. The fragile mechanics — `codex exec review` has no `--cd` so it must run from inside the worktree, the mandatory `< /dev/null`, the GNU timeout bound, retry-once-on-failure, and the guarantee that a non-empty artifact exists before the fix agent reads it — are all captured in this skill's `scripts/codex-review.sh`. The orchestrator's only jobs are to assemble the per-item prompt and act on the script's result.

Write the adversarial review prompt to `<run-dir>/reviews/<ID>-prompt.md`, substituting the per-item values:

```text
You are reviewing the uncommitted changes for ONE work item of a
larger feature, adversarially: assume at least one real defect and
that the tests are weaker than they look. An approval that finds
nothing is the failure mode. Distrust exactly the parts that look
obviously fine.

Hard contract — the Interfaces section of <run-dir>/spec.md:
<paste the Interfaces text relevant to this item>.
Intent and recorded Deviations: <run-dir>/plans/<ID>.md.
This item owns: <paths>.

Hunt for: bugs, broken edge cases, violations of the spec interfaces,
regressions to surrounding code, missing or weak tests, recorded
deviations that are actually wrong calls, and files changed outside
the item's ownership that the plan does not justify. Attack the tests
specifically — the same model wrote the code and the tests, so a green
run proves little; name the edge cases, error paths, and interface
boundaries the suite does NOT exercise.

For each finding give: severity (Critical/High/Medium/Low), file:line,
what is wrong, and where the fix belongs — local code, the plan's
approach, the spec interfaces, or another work item. Do not modify
files; report only.
```

Then call the script (the default install path; if the skill is installed elsewhere, run it from this skill's own `scripts/` directory), passing the worktree, the findings path, and the prompt file:

```bash
~/.claude/skills/orchestrify/scripts/codex-review.sh \
  <repo-root>/orchestrify-<slug>-<ID> \
  <run-dir>/reviews/<ID>-codex.md \
  <run-dir>/reviews/<ID>-prompt.md
```

The script retries once internally and prints one machine-readable line last: `CODEX_REVIEW: COMPLETED <file>` (exit 0, artifact written and non-empty) or `CODEX_REVIEW: FAILED <reason>` (non-zero). It guards the two traps that otherwise read as "no findings": the codex 0.120.0+ stdin hang (caught by `< /dev/null` and the timeout), and a clean exit over an empty `-o` file (treated as failure, not a clean pass) — so you never reconstruct the `codex exec` flags yourself. **On `FAILED`, do not proceed on the empty or partial findings file** — mark the item `blocked` per **Escalation** with the reason the script reports ("Codex review did not complete (timeout/error after one retry)") and keep its worktree for a follow-up run. Never treat a missing or truncated review artifact as a clean pass.

**Throttle review concurrency.** Plan and implement stages parallelize freely, but the Codex reviews contend for one Codex auth — on a ChatGPT-subscription auth, firing several at once triggers 429 rate-limit backoff that turns every concurrent review slow (the parallel-review case is exactly where the multi-minute stalls cluster). Cap **concurrent invocations of the review script at 2-3** even when more items are ready to review; let the rest queue. This bounds wall-clock without serializing the whole run.

Findings land in `<run-dir>/reviews/<ID>-codex.md`. The orchestrator reads only that artifact, never the diff itself — the same file-handoff rule as every other stage.

**Fix agent (Claude).** Spawn one `orchestrify-fix` subagent to apply the fixes, inside the item's worktree. The spawn prompt carries only the per-item values:

- the worktree path (`<repo-root>/orchestrify-<slug>-<ID>`)
- the run directory
- the item's ID and title

The agent reads `spec.md`, the plan, and the Codex findings at `<run-dir>/reviews/<ID>-codex.md` itself; it fixes code-rooted findings, adds missing tests, re-runs Verification, and reports findings it cannot resolve inside the worktree (rooted in the plan, the spec interfaces, or another item).

The fix loop: after the fix agent finishes, **re-run `scripts/codex-review.sh` once** (reusing the same `<ID>-prompt.md`) over the new state. If it returns no Critical or High findings, proceed to commit. If code-rooted Critical/High findings remain, run one more fix round — **maximum 2 fix rounds** — then go to **Escalation**. Any finding the reviewer roots in the plan, the spec's interfaces, or another work item goes to **Escalation** immediately: the fix agent cannot resolve it inside this one worktree.

### 4d. Commit agent

Spawn one `orchestrify-commit` subagent for the item, inside its worktree. The spawn prompt carries only the per-item values:

- the worktree path (`<repo-root>/orchestrify-<slug>-<ID>`)
- the run directory
- the item's ID and title

The agent inspects the worktree, stages only this item's files by name (plus its plan file), writes a Conventional Commits message that never attributes the work to Claude or this process, and returns the commit hash and message.

Before recording the hash, check the returned message: if it mentions
Claude, AI, agents, the orchestration process, or the user anywhere —
subject, body, or trailers — treat the step as failed, run
`git reset --soft HEAD~1` in the worktree, and re-run the commit agent
with the violation quoted in its prompt.

Record the hash in `state.md` and mark the item `committed`.

### 4e. Merge agent (serialized)

Run merges one at a time, in dependency order — completion order for siblings. Merging is where deferred collisions become visible, and where they get resolved with full context.

Spawn one `orchestrify-merge` subagent, inside the integration worktree. The spawn prompt carries only the per-item values:

- the integration worktree path (`<repo-root>/orchestrify-<slug>`)
- the run directory
- the item's ID and title
- the item branch (`orchestrify/<slug>-<ID>`) and the integration branch (`orchestrify/<slug>`)

The agent runs `git merge --no-ff`, resolves conflicts using the spec Interfaces and both sides' plan files, verifies the merged result (build, affected tests, the item's Verification commands), and reports whether it merged or aborted on a semantic conflict.

After a successful merge, remove the worktree and branch
(`git worktree remove <repo-root>/orchestrify-<slug>-<ID>` and
`git branch -d orchestrify/<slug>-<ID>`), mark the item `merged` in
`state.md`, and re-check for newly unblocked items.

If the merge agent aborts on a semantic conflict, go to **Escalation** — two work items that cannot coexist mean the spec's interfaces or the breakdown need revision, which is a user decision.

### Escalation

When an agent reports that the problem is structural — the spec is wrong, the breakdown missed a dependency, an interface does not survive contact with the codebase, or the fix loop is exhausted — the orchestrator decides autonomously. Never ask the user. Apply this decision rule:

**Amend and continue** when a fix exists that preserves the interview's stated outcome, features, and non-goals — the change only touches *how*, not *what*. Examples: re-split an item, reorder dependencies, revise an interface both sides can adopt, accept an implementation deviation. Then:

1. Update `spec.md` (interfaces, breakdown) and regenerate plans for affected unstarted items.
2. Record the decision in a `## Decisions` log in `spec.md`: what broke, what was changed, and why it preserves the interview's intent, citing the doubt rule where it applied.
3. Resume the loop. Report the amendment to the user as a one-way status line.

**Block and route around** when every fix would alter *what* was agreed — dropping or changing a promised feature, violating a stated constraint, expanding scope past a non-goal. Guessing here would silently ship something the user did not ask for. Then:

1. Mark the item `blocked` in `state.md` with a one-line reason and the options the user will need to choose between. Items depending on it stay `pending`. Keep the item's worktree and branch — partial work resumes there in a follow-up run.
2. Continue all unaffected work to completion. A blocked item never stalls the rest of the run.
3. Surface the blocked item, its reason, and its options in the final report — that is where the user's decision happens, asynchronously.

When the doubt rule is prefer-smaller-scope and a feature can be cleanly cut rather than blocked, cutting it is an amendment: record it in Decisions and in the final report's deviations.

## Step 5: Integration verification

Per-item review catches local bugs; only this phase catches pieces that do not compose. After the loop drains, spawn one `orchestrify-integrate` subagent. The spawn prompt carries only:

- the integration worktree path (`<repo-root>/orchestrify-<slug>`)
- the run directory

The agent reads `spec.md`, runs the full build and test suite, exercises each spec feature end to end, fixes small integration bugs, and reports per-feature pass/fail plus any larger mismatches.

If it applied fixes, run the review stage (4c) — Codex review plus the Claude fix agent — over them in the integration worktree, then the commit agent. If it found larger mismatches, treat them under **Escalation**.

## Step 6: Report

Write the run report to `<run-dir>/report.md` **first**, then relay its highlights to the user. The file is the durable record of the run: it outlives the conversation, so anyone resuming, auditing, or picking up a follow-up run reads it instead of scrolling back. The orchestrator already holds everything it needs — pull each section from `state.md`, the spec's `## Decisions` log, and the integration agent's report; do not re-explore. Generate the completion timestamp with `date +"%Y-%m-%d %H:%M"`.

```markdown
# Report: <idea summary>

**Run:** <run-dir>
**Completed:** <YYYY-MM-DD HH:MM>
**Deliverable:** `orchestrify/<slug>`

## Shipped

| ID  | Item    | Commit | Status |
| --- | ------- | ------ | ------ |
| W1  | <title> | <hash> | merged |

## Deviations

- <What changed from the original spec and why, citing the doubt rule where it applied. Mirrors the spec's Decisions log. "None" if the run matched the spec.>

## Blocked

- <Item, the one-line reason, and the decision the user must make between the recorded options. "None" if nothing is blocked.>

## Integration verification

- <Feature>: pass | fail — <detail, per spec feature>

## Follow-ups

- <Deferred work, known gaps, weak spots the reviews flagged but did not block, and any follow-up run needed for blocked items — each with the worktree/branch that still holds its partial work.>

## Landing

The deliverable is the `orchestrify/<slug>` branch, built in the integration worktree. Land it from your own worktree with `git merge --no-ff orchestrify/<slug>`, then optionally push.
```

After writing the file, give the user a short spoken summary — what shipped with commit hashes, anything `blocked` and the decision it waits on, the integration result feature by feature, and the path to the full `report.md` — then the landing command. The report file is the authoritative version; the spoken summary just points at it.

## Guidelines

- Never attribute commits to Claude. No commit produced by any agent in the run — commit agent, merge agent, escalation fixes — may mention Claude, AI, agents, this orchestration process, or the user anywhere in the message: not the subject, not the body, not the footers. No `Co-Authored-By: Claude` and no `Generated with` trailers. Commit messages describe only the change itself.
- The orchestrator never implements, reviews, or explores deeply itself. If you catch yourself reading source files at length in the main context, delegate.
- Each Claude stage is a dedicated subagent type (`orchestrify-spec`, `orchestrify-plan`, `orchestrify-implement`, `orchestrify-fix`, `orchestrify-commit`, `orchestrify-merge`, `orchestrify-integrate`) whose instructions are its definition, loaded as its system prompt. The orchestrator spawns by type and passes only the per-item values — run directory, worktree path, ID and title, owned files, branch names; the spec agent instead gets the interview brief and repo root. The heavy stage instructions never enter the orchestrator's context. Codex review (4c) is the exception: it is an external CLI the orchestrator runs directly, not a subagent.
- State lives in files, not in conversation memory. After any interruption, `state.md` plus the plan files are sufficient to resume.
- Pass context between stages through artifact files, never by relaying summaries — the implement agent reads the plan file itself, the Codex reviewer reads the plan and diff itself and writes findings to its review file, and the fix agent reads that review file itself.
- One worktree per work item, created by the orchestrator at the repo root off the shared bare repo, shared by that item's implement, Codex review, fix, and commit stages, removed only after merge. All worktrees — the user's, the integration tree, and each item — are peers off the bare repo; the run never reads or writes the user's worktree. Only the serialized merge agent writes the integration branch, inside the integration worktree.
- If a run is abandoned, clean up with `git worktree list` and remove any `orchestrify/` worktrees and branches left behind.
- After the interview closes — and the optional breakdown checkpoint in Step 3, if the user opted into it — the run never waits on the user: no approval requests, no clarifying questions, no AskUserQuestion. Ambiguity resolves against the spec and the doubt rule; what cannot be resolved that way becomes a `blocked` item in the final report.
- Keep the user informed at phase transitions with one or two one-way status lines: items started, items merged, amendments made, anything blocked. Inform, never ask.
