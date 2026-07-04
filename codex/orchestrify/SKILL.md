---
name: orchestrify
description: Drive a substantial feature from idea to a verified integration branch using isolated Codex subagents, independent Claude Code reviews, and one git worktree per work item. Use when Codex should run fully autonomously from a confirmed brief — discover the brief file the briefify skill wrote in `.orchestrify/briefs/`, restate and confirm it once, write a spec and dependency-ordered work breakdown, plan and implement unblocked items in parallel, review each item with Claude and run a Codex fixer loop, commit each item, merge them into an integration worktree, and verify the assembled feature. Requires a brief (without one, the skill only points the user at briefify and stops), Codex multi-agent tools, an authenticated Claude CLI, and a bare-repository-with-worktrees layout. Do not use for small changes or when the user only wants a spec, plan, review, or commit.
---

# Orchestrify

Coordinate a feature through isolated subagents and git worktrees. Keep the main conversation focused on intent, state, and artifact summaries. Delegate deep exploration, implementation, review, conflict resolution, and integration verification.

The run produces an `orchestrify/<slug>` branch for the user to land. Never modify the user's worktree.

## Resolve bundled resources

Resolve this skill's installed directory before starting. Use:

- `scripts/preflight.sh` for the mechanical environment checks.
- `scripts/claude-review.sh` for independent review execution.
- `references/spec-agent.md`, `plan-agent.md`, `implement-agent.md`, `claude-review.md`, `fix-agent.md`, `commit-agent.md`, `merge-agent.md`, and `integrate-agent.md` as stage prompts.

Read a stage reference before spawning that stage. Include its complete instructions in the subagent prompt, followed by the per-item values. Do not assume subagents inherit this skill.

## 1. Confirm the brief and preflight

The run starts from a brief — a captured interview, written earlier by the briefify skill. Orchestrify does not interview: capturing intent well takes an unhurried conversation, and that conversation is briefify's whole job.

Check for a waiting brief: list `.orchestrify/briefs/*.md` at the repo root — one `ls`, filenames only, never reading files to decide. The directory's top level holds only unconsumed briefs (its `drafts/` subdirectory does not count), so presence is status.

- Exactly one brief: read it and continue below.
- Several briefs: present the filenames — the timestamped names identify them — and ask which one this run is for. Read only the chosen one.
- None: stop. Tell the user orchestrify runs from a brief and to run briefify first — suggesting it with any idea they gave — then invoke orchestrify again. Do not interview as a substitute, and do not run briefify for them.
- An idea alongside a brief: if it names the same work, fold it into the brief as an amendment at the confirmation; if unrelated, ask whether to run the brief anyway or take the new idea to briefify first.

Restate the brief to the user: outcome, features, non-goals, inputs/outputs, constraints, doubt rule, and checkpoint choice, plus any amendments. Note its age from the `Created` line and warn when it is more than a few days old — the codebase and the user's intent may have moved. If the doubt rule or checkpoint choice is missing (briefify always writes them; a hand-written brief may not), apply the defaults — smaller scope, no checkpoint — and state them in the restatement rather than asking. Confirm the trunk branch reported by preflight.

Run the preflight script from the project root before the confirmation:

```bash
bash <skill-dir>/scripts/preflight.sh
```

It checks:

- `BARE_REPO`: the repository uses a shared bare object store with peer worktrees.
- `TRUNK_CANDIDATE`: the bare repository's default branch; confirm it with the user.
- `GIT`: required git features are available.
- `CLAUDE`: the Claude CLI is installed and authenticated.
- `TIMEOUT`: GNU `timeout` or `gtimeout` is available for bounded reviews.
- `RESULT`: success only when all gates pass.

On failure, stop and report the remediation. Do not convert the repository autonomously — for the layout and tooling gates, point the user at the initify skill, which fixes them interactively with consent per step.

Confirm that this Codex session exposes the multi-agent spawn, wait, message, and close tools. If they are not currently loaded, discover them through the tool-discovery mechanism. If unavailable, stop.

The run must not depend on mid-run approval prompts. Before the confirmation, tell the user it requires a dedicated Codex session with filesystem and command permissions broad enough for worktree creation, dependency installation, builds, tests, and local git commits. If the active policy would prompt for routine operations, stop so the user can reconfigure the session. Never weaken platform security controls yourself.

Close by confirming the restated brief — outcome, features, non-goals, doubt rule, trunk, and checkpoint choice. The user's confirmation authorizes the run. After that, only pause for the opted-in checkpoint or a platform-enforced permission request.

## 2. Write the run artifacts

Resolve `<repo-root>` as the parent of:

```bash
git rev-parse --path-format=absolute --git-common-dir
```

Create:

```text
<repo-root>/
├── .bare/
├── <user worktrees...>
├── orchestrify-<slug>/                 # integration worktree
├── orchestrify-<slug>-<ID>/            # item worktrees
└── .orchestrify/YYYYMMDD-HHMMSS-<slug>/
    ├── spec.md
    ├── state.md
    ├── report.md
    ├── plans/
    └── reviews/
```

Keep all worktrees at `<repo-root>`, never inside `.orchestrify/`. Make `<slug>` a short kebab-case phrase.

Consume the brief now: `mv` it to `<run-dir>/brief.md`. The move is what marks it used — the briefs directory only ever holds unconsumed briefs — and it archives the confirmed intent with the run that acted on it.

Do not explore the codebase in the orchestrator context. Read `references/spec-agent.md` and spawn one spec worker, passing:

- the run directory
- the repository root
- the current timestamp, from `date +"%Y-%m-%d %H:%M"`, for the spec's `Created` line
- the **brief**: the outcome, features, non-goals, inputs/outputs, constraints, and doubt rule from the confirmed brief, plus any amendments confirmed with it

Pass the brief faithfully; it is the whole of the user's intent, and every later decision cites the spec it produces. The worker explores the repository, defines the shared interfaces, and writes `<run-dir>/spec.md` (outcome, features, non-goals, inputs/outputs, interfaces, a 2-8 item dependency-ordered work breakdown with file ownership, assumptions, doubt rule, risks), returning a short summary. Its exploration stays in its own context; only the spec and summary return. If it reports that the requested scope cannot split cleanly against the codebase, treat that as a structural problem (section 5) before proceeding.

The spec worker authors `spec.md` once; the orchestrator maintains it thereafter — Decisions log, interface revisions, and amendments are orchestrator edits, not a re-spawn. The exception is a structural revision requested at the section 3 checkpoint, which re-spawns the spec worker with the current spec plus the requested changes.

Read the returned `spec.md` and initialize `state.md` with one row per item and these states:

`pending → planning → planned → implementing → reviewing → committed → merged`

Use `blocked` with a reason for failures. Only `merged` unblocks dependents.

## 3. Checkpoint and integration worktree

Report the outcome, work items, dependency order, expected parallelism, and assumptions.

- If the brief declined the checkpoint, proceed immediately.
- If it opted in, ask once for approval and revise as requested: a structural revision (re-splitting items, reordering dependencies, reworking an interface) re-spawns the spec worker with the current spec plus the changes; a trivial revision (wording, a renamed item) the orchestrator edits inline.

Set the spec status to `approved`, then create the integration worktree:

```bash
git worktree add <repo-root>/orchestrify-<slug> \
  -b orchestrify/<slug> <trunk>
```

## 4. Run the dependency loop

Repeat until every item is `merged` or `blocked`:

1. Select all `pending` items whose dependencies are `merged`.
2. Spawn their plan agents in parallel.
3. Reconcile all plans in the batch against each other and the spec interfaces.
4. Amend missed dependencies or contracts before implementation and regenerate affected plans.
5. Create one worktree per planned item from the current integration tip:

   ```bash
   git worktree add <repo-root>/orchestrify-<slug>-<ID> \
     -b orchestrify/<slug>-<ID> orchestrify/<slug>
   ```

6. Run implement, review/fix, and commit stages in parallel across independent items.
7. Serialize merges into the integration branch in dependency order, then completion order.
8. Update `state.md` after every transition and close completed subagents promptly.

Use `orchestrify/<slug>-<ID>`, not `orchestrify/<slug>/<ID>`; git cannot store the integration branch as both a ref file and a parent directory.

### Spawn discipline

Use fresh subagents for independent Codex stages. Claude review runs as a separate external process, so implementation and review contexts and model families remain separate.

- Use an explorer or default agent for planning.
- Use a worker agent for implementation, fixes, commits, merges, and integration.
- Assign exact worktree and file ownership in every worker prompt.
- State that other agents are working concurrently and that the agent must not revert their changes.
- Start independent agents before waiting. Wait only when their results are required for the next transition.
- Treat artifact files as authoritative. Agent summaries are status signals, not the handoff itself.
- Tier the stages explicitly instead of inheriting the session default: spec and plan workers on the strongest reasoning tier (decomposition and planning errors propagate into every downstream worker), the implement worker on a mid tier (its plan is deliberately written for a more modest executor), and the fix, merge, and integration workers back on a higher tier — they act on adversarial findings, resolve semantic conflicts, and judge feature composition. The commit worker stays on the lightest tier (see Commit).

### Plan

Read `references/plan-agent.md`, then spawn one planner per ready item with:

- run directory
- item ID and title
- owned files
- the integration worktree path (`<repo-root>/orchestrify-<slug>`) — the tree to explore: it holds the integration branch, including every merged dependency the item builds on

The planner writes `<run-dir>/plans/<ID>.md`. Reconcile the whole ready batch before creating item worktrees.

### Implement

Read `references/implement-agent.md`, then spawn one worker per item with:

- item worktree
- run directory
- item ID and title
- owned files

The worker implements and verifies without committing.

### Review and fix

Read `references/claude-review.md` and assemble its prompt with the item values. Write the prompt to `<run-dir>/reviews/<ID>-prompt.md`, then run:

```bash
<skill-dir>/scripts/claude-review.sh \
  <worktree> \
  <run-dir>/reviews/<ID>-claude.md \
  <run-dir>/reviews/<ID>-prompt.md
```

The wrapper runs Claude Code read-only, retries with exponential backoff (up to 4 attempts — auth rate-limit bursts pass between spaced retries), and requires a non-empty artifact. On `CLAUDE_REVIEW: FAILED`, mark the item blocked; never interpret missing output as approval.

Read the Claude review artifact. If there are code-rooted Critical or High findings, read `references/fix-agent.md` and spawn a Codex fixer in the same worktree. Re-run Claude review over the new state. Allow at most two fix rounds.

Escalate immediately when a finding is rooted in the spec, plan, shared interface, or another item. Medium and Low findings may proceed only when explicitly recorded in the plan's Deviations section with a concrete reason.

Throttle concurrent Claude reviews to 2-3 to avoid auth and rate-limit contention.

### Commit

Read `references/commit-agent.md` and spawn a commit worker on a lighter Codex model tier (a smaller model or reduced reasoning effort) — writing the message is mechanical and does not need the reasoning tier the build stages use. Validate its returned commit message. If it mentions Codex, AI, agents, orchestration, or the user, soft-reset the commit and retry with the violation quoted — at most twice. If the message still violates after the second retry, do not reset again: rewrite it yourself with `git commit --amend -m` in the worktree, a compliant Conventional Commits message describing only the change.

Record the commit hash and mark the item `committed`.

### Merge

Read `references/merge-agent.md` and spawn one merge worker at a time in the integration worktree.

After a successful merge:

```bash
git worktree remove <repo-root>/orchestrify-<slug>-<ID>
git branch -d orchestrify/<slug>-<ID>
```

Mark the item `merged`. Preserve a failed item's worktree and branch.

## 5. Handle structural problems

Never silently change the agreed product intent.

Amend and continue when the change preserves the confirmed outcome, features, and non-goals. Update the spec and affected plans, and add a `## Decisions` entry explaining the change and the doubt rule applied.

Block and route around when every solution would change what the user authorized. Mark the item `blocked`, record the decision options, keep its worktree, and continue unaffected items. Ask for the decision only in the final report.

If the doubt rule is smaller scope and an optional feature can be cleanly removed without violating the confirmed requirements, record that cut as an amendment.

## 6. Verify integration

After the loop drains, read `references/integrate-agent.md` and spawn an integration worker in the integration worktree. It must run the full build and tests and exercise every feature against the spec.

If it makes small fixes, run Claude review and the Codex fix loop over the integration diff, then use the commit stage. Treat larger mismatches as structural problems.

## 7. Report

Write the run report to `<run-dir>/report.md` first, then relay its highlights to the user. The file is the durable record of the run — it outlives the conversation, so anyone resuming, auditing, or picking up a follow-up run reads it instead of scrolling back. Pull each section from `state.md`, the spec's `## Decisions` log, and the integration worker's report; do not re-explore. Generate the completion timestamp with `date +"%Y-%m-%d %H:%M"`.

```markdown
# Report: <summary>

**Run:** <run-dir>
**Completed:** <YYYY-MM-DD HH:MM>
**Deliverable:** `orchestrify/<slug>`

## Shipped
| ID | Item | Commit | Status |
| --- | --- | --- | --- |
| W1 | <title> | <hash> | merged |

## Deviations
- <What changed from the spec and why, citing the doubt rule. Mirrors the spec's Decisions log. "None" if the run matched the spec.>

## Blocked
- <Item, the reason, and the choice the user must make. "None" if nothing is blocked.>

## Integration verification
- <Feature>: pass | fail — <detail>

## Follow-ups
- <Deferred work, gaps reviews flagged but did not block, and any follow-up run for blocked items, each with the worktree/branch that still holds its partial work.>

## Landing
Land the deliverable from your own worktree: `git merge --no-ff orchestrify/<slug>`.
```

After writing the file, give the user a concise spoken summary — shipped items and commit hashes, blocked items and the choices required, feature-by-feature integration results, the deliverable branch `orchestrify/<slug>`, the landing command `git merge --no-ff orchestrify/<slug>`, and the path to the full `report.md`. The report file is authoritative; the spoken summary points at it.

## Invariants

- Never write to the user's worktree.
- Never let two agents write the same worktree concurrently.
- Never attribute commits to Codex, AI, agents, the orchestration process, or the user.
- Never relay large diffs or test logs through the orchestrator context; use artifacts and concise summaries.
- Never mark an item complete before its merge succeeds.
- Never treat an absent review artifact as approval.
- Keep one item worktree through implementation, review, fix, and commit; remove it only after merge.
- Keep the user informed at phase transitions with concise one-way updates.
