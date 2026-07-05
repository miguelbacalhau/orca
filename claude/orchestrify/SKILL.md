---
name: orchestrify
description: Drive a feature from idea to committed code using a deterministic workflow over dedicated subagents. Use when Claude should run fully autonomously from a confirmed brief — discover the brief file the briefify skill wrote in `.orchestrify/briefs/`, restate and confirm it once, write a spec with a dependency-ordered work breakdown, then execute the work loop as a single Workflow-tool run that, per unblocked item, plans and implements in its own git worktree branched off a shared bare repository, reviews with an independent cross-model Codex reviewer plus a Claude fix agent, commits, and serially merges into an integration worktree. Requires a brief (without one, the skill only points the user at briefify and stops), a bare-repo-with-worktrees layout (validated up front), and a harness with the Workflow tool; there is no privileged main checkout, and the run's deliverable is a branch the user lands themselves. After the opening confirmation — plus one optional breakdown checkpoint the brief opts into — nothing else asks the user anything; undecidable issues are reported at the end. Do not use for small single-file changes or when the user only wants a spec or a plan.
args: <idea>
user-invocable: true
---

# Orchestrify

Coordinate a full implementation through isolated subagents. The main conversation handles everything interactive and cheap — the brief, the pre-flights, the spec, the checkpoint, and the final report — and delegates the long autonomous middle to **one deterministic workflow**: a bundled script, run through the Workflow tool, that spawns every stage agent with code-enforced control flow. All heavy context — codebase exploration, diffs, test output — lives and dies inside subagents; the main conversation only reads artifact files and the workflow's structured result.

Isolation is double: each subagent has its own context window, and each work item has its own git worktree. The repository is a bare repo, and every working copy — the user's, the run's integration tree, and each item — is a peer worktree off that one shared object store. There is no privileged main checkout: the run never reads or writes the user's worktree, and the deliverable is a branch the user lands themselves. Parallel items can never corrupt each other's files — overlap surfaces as an explicit merge conflict, resolved by a dedicated merge agent with both items' plans in hand.

The brief is where the user sets intent — written earlier with the briefify skill, discovered on disk, and confirmed once at the start of the run. It may also opt into a single checkpoint: a one-time review of the spec and work breakdown before any code is written. Apart from the opening confirmation and that opt-in checkpoint, never ask the user anything — no mid-run clarifications, no approval gates, no AskUserQuestion. The workflow runs autonomously in the background and could not pause for a question even if one arose; anything it cannot decide within the brief's stated intent becomes a `blocked` item surfaced in the final report.

## Input

The run starts from a brief — a captured interview, written earlier by the briefify skill. Orchestrify does not interview: capturing intent well takes an unhurried conversation, and that conversation is briefify's whole job.

Check for a waiting brief: list `.orchestrify/briefs/*.md` at the repo root — one `ls`, filenames only, never reading files to decide. The directory's top level holds only unconsumed briefs (its `drafts/` subdirectory does not count), so presence is status.

- **Exactly one brief:** read it and proceed to Step 1.
- **Several briefs:** present the filenames — the timestamped names identify them — and ask which one this run is for. Read only the chosen one.
- **None:** stop. Tell the user orchestrify runs from a brief and to run `$briefify` first — suggesting it with any idea they gave, e.g. `$briefify <their idea>` — then invoke `$orchestrify` again. Do not interview as a substitute, and do not run briefify for them: the discussion is theirs to have.
- **An idea argument alongside a brief:** if it names the same work, fold it into the brief as an amendment at the Step 1 confirmation; if it is unrelated, ask whether to run the brief anyway or take the new idea to briefify first.

## Step 1: Confirm the brief

The brief is the only place intent was captured — once this step ends, the run is autonomous and every later ambiguity gets resolved against what the brief says. Restate it to the user: outcome, features, non-goals, inputs/outputs, constraints, doubt rule, and breakdown-checkpoint choice, plus any amendments folded in from an idea argument. Note the brief's age from its `Created` line and warn when it is more than a few days old — the codebase and the user's intent may have moved since it was written.

If the brief is missing the doubt rule or the checkpoint choice (briefify always writes them; a hand-written brief may not), apply the defaults — prefer-smaller-scope, straight-through — and state them in the restatement rather than asking. The breakdown checkpoint, when the brief opts in, is a one-time review of the spec and work breakdown before any worktree or code: the decomposition is where parallel-agent mistakes originate, and it is the only optional pause in the run.

The user's confirmation of the restated brief authorizes the run. If the brief opted into the breakdown checkpoint, the only remaining interaction is that one approval in Step 3; otherwise there is no later gate at all. From this point on, never ask the user anything else; proceed on recorded assumptions.

### Environment pre-flight (script)

Three of the run's prerequisites are mechanical and validated by one bundled script — the bare-repo layout, the registered Codex MCP reviewer, and the installed subagent definitions. Run it during this step, before the confirmation, from the project root:

```bash
bash ~/.claude/skills/orchestrify/scripts/preflight.sh
```

That is the default install path; if the skill is installed elsewhere, run `preflight.sh` from this skill's own `scripts/` directory. The script is read-only and prints one line per gate plus a final result:

- `BARE_REPO: PASS|FAIL` — the project is a bare repository with worktrees.
- `TRUNK_CANDIDATE: <branch>` — informational, not a gate: the bare repo's default branch, the run's likely trunk. Confirm the trunk with the user; the integration branch is created from its tip.
- `CODEX: PASS|FAIL` — the global `codex` binary is on PATH at or above the minimum version, authenticated, registered as an MCP server in the project's `.mcp.json`, enabled in `.claude/settings.local.json`, and `MCP_TOOL_TIMEOUT` is set in the settings env block.
- `AGENTS: PASS|FAIL` — all eight subagent definitions are installed.
- `RESULT: PASS|FAIL` — mirrored by the exit code, which is 0 iff every gate passed.

On `RESULT: PASS`, proceed. On any `FAIL`, do not start — relay the failing gate's remediation below and stop. These are pre-flight gates, not mid-run questions.

One gate the script cannot check: the harness must expose the **Workflow tool** (Step 4 runs through it). If this session has no Workflow tool, stop and tell the user this skill requires a Claude Code harness with workflows.

A second gate only the session can check — the **live MCP gate**: MCP servers and settings env load at session start, so a registration written minutes ago passes every file grep while this session still has no codex tool (and the first review would fail an hour into the run). Before launching the workflow, confirm the tool actually resolves: call ToolSearch with `select:mcp__codex__codex`. If it does not resolve, the registration is present but not loaded — tell the user to start a fresh session in this project and stop.

**Why each gate, and how to fix a `FAIL`:**

- **Bare repo** is the substrate the entire run depends on: every working copy — the user's, the integration tree, each item — is a peer worktree off one shared bare object store, so there is no privileged main checkout to corrupt. A `FAIL` means the repo is a conventional checkout. Converting it is the user's decision — never convert autonomously. Point them at the **initify skill**, which performs the conversion interactively with consent per step (and also sets up new repositories and bare clones); it preserves untracked files like `.env` that a naive re-checkout would lose.
- **Codex** is the independent, cross-model reviewer in the work loop — a different model family from the Claude implementer, so it does not share the implementer's blind spots. A missing, stale, unauthenticated, or unregistered reviewer would fail every item at review time, deep into an autonomous run. The reviewer is the **global codex binary's MCP server** (`codex mcp-server`), registered per project — codex is **never installed via npm**: the only supported install is the system one on PATH, from the official non-npm distribution (e.g. `brew install codex`, or the release binaries). Fix, depending on which check failed: install or upgrade codex (non-npm), authenticate with `codex login`, or — for the registration, enablement, and `MCP_TOOL_TIMEOUT` checks — point the user at the **initify skill**, which writes all three and knows the restart caveat. Installing, authenticating, and registering are the user's actions — surface the command, do not do it autonomously.
- **Subagent definitions** — every stage is a dedicated subagent type (`orchestrify-spec`, `-plan`, `-implement`, `-review`, `-fix`, `-commit`, `-merge`, `-integrate`) whose instructions load as its system prompt; the workflow spawns them by type and passes only per-item values. They ship with the skill and are installed into the Claude agents directory by `install-claude-skills.sh`, which the harness loads at session start. A `FAIL` means the skill is not fully installed — re-run `install-claude-skills.sh` from the skills repo. If they were only just installed this session, the harness may not have picked them up yet; a fresh session loads them.

### Permissions pre-flight

The run only stays autonomous if the harness will not raise permission prompts: subagents — including every agent the workflow spawns — inherit this session's permission mode, and the skill's own frontmatter does not propagate to them. A single foreground prompt mid-run breaks autonomy, and an auto-denied call makes an agent fail confusingly instead.

**This requires `bypassPermissions` mode — an allow-list is not sufficient.** The subagents are themselves models that decide commands at runtime (dependency installs, build and test variants, git invocations with assorted flags, `find`, `sed`, and so on), so the command set is open-ended and no static `permissions.allow` list can anticipate it. Beyond that, the harness matches Bash rules as prefix globs against the literal command string, so even listed commands slip through when they contain `$(…)` substitutions, lead with flags like `git --git-dir=…`, or are compound (`cd foo && …`). A leaked prompt is therefore a question of *when*, not *whether* — which is why the fix is the session mode, not the rules.

The skill cannot flip the mode itself, so confirm it during this step, before the confirmation: the session must be in `bypassPermissions` mode for the run. Enable it one of three ways:

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
    ├── brief.md    # the consumed brief — the run's confirmed intent
    ├── spec.md     # requirements, interfaces, work breakdown, workflow runId
    ├── report.md   # final run report, written at the end
    ├── plans/      # one plan file per work item, written by plan agents
    └── reviews/    # Codex findings artifacts, archived per review round
```

- `<repo-root>` is the directory containing the bare repo — resolve it as the parent of `git rev-parse --path-format=absolute --git-common-dir`.
- Generate the timestamp by running `date +%Y%m%d-%H%M%S`.
- Make `<slug>` a short kebab-case description of the idea, 3-5 words max.
- Worktree directories sit at `<repo-root>` and are named after their branches: `orchestrify-<slug>` for integration, `orchestrify-<slug>-<ID>` for each item. The `.orchestrify/` metadata is scratch space on disk, outside every worktree, so nothing in it can be committed by accident.

Consume the brief now: `mv` it to `<run-dir>/brief.md`. The move is what marks it used — the briefs directory only ever holds unconsumed briefs — and it archives the confirmed intent with the run that acted on it.

With the run directory scaffolded, **delegate the spec — do not explore the codebase in the main context.** Heavy exploration lives and dies in a subagent, and the main conversation only reads the artifact that comes back. Spawn one `orchestrify-spec` subagent, passing only:

- the run directory
- the repository root (`<repo-root>`)
- the current timestamp, from `date +"%Y-%m-%d %H:%M"` — the agent has no shell, so it cannot generate one for the spec's `Created` line
- the **brief**: the outcome, features, non-goals, inputs/outputs, constraints, and doubt rule from the confirmed brief, plus any amendments confirmed with it

Pass the brief faithfully — it is the whole of the user's intent, and every later autonomous decision cites the spec it produces. The agent explores the codebase, defines the shared **Interfaces Between Work Items**, and writes the full spec — outcome, features, non-goals, inputs/outputs, interfaces, a 2-8 item dependency-ordered **Work Breakdown** with file ownership, assumptions, the doubt rule, and risks — to `<run-dir>/spec.md`, returning a short summary. Its exploration dies with its context; only `spec.md` and the summary return. If the agent reports that the requested scope cannot be split cleanly against the codebase — a feature the existing code fights, an interface it forces — surface that to the user and stop rather than launching a run against a spec known to be wrong.

The spec agent authors `spec.md` **once**. During the run, mid-loop amendments — interface revisions, breakdown changes, the `## Decisions` log — are made by the workflow's escalation agent (Step 4), never by a re-spawn; the sole exception is a structural revision requested at the Step 3 checkpoint, which re-spawns the spec agent (see Step 3).

Read the returned `spec.md` — an artifact, not source. Its Work Breakdown is the run's item list; there is no separate status file to maintain. Mid-run, the live status is the workflow's own progress display and journal — do not poll files during the run — and the final outcome lands in `report.md`.

## Step 3: Announce and proceed

Report the spec to the user — outcome, work items, dependency order, what will run in parallel, key assumptions. How this lands depends on the breakdown-checkpoint choice recorded in the brief:

- **Opted out (the default):** this is a one-way status update. Proceed immediately; do not wait for or request approval — the Step 1 confirmation already authorized the run. If the user interjects on their own, incorporate it; never solicit it.
- **Opted in:** this is the one authorized pause. Present the spec and breakdown and ask once for approval. Incorporate any changes they request: a **structural** revision — re-splitting items, reordering dependencies, reworking an interface — re-spawns the `orchestrify-spec` agent with the current `spec.md` plus the requested changes, because it may need fresh codebase exploration; a **trivial** revision — wording, a renamed item, a tweaked assumption — edit inline. Then proceed. This is the final interactive moment of the run; after it, the run is autonomous and never waits on the user again.

Set the spec status to `approved`. Create the integration worktree at the repo root, on a fresh branch based on the trunk tip:

```bash
git worktree add <repo-root>/orchestrify-<slug> -b orchestrify/<slug> <trunk-branch>
```

Completed items are merged into this branch, and `orchestrify/<slug>` is the run's deliverable — the user lands it onto trunk themselves at the end. The run never checks out or writes the user's own worktree.

The spec must also record the **doubt rule** from the brief — every later autonomous decision cites it.

## Step 4: Run the work loop (workflow)

The work loop runs as **one deterministic workflow**, not as conversational orchestration. The bundled script `scripts/work-loop.workflow.js` encodes the loop's every rule as code, so the guarantees the run depends on are structural, not model discipline that decays over a long context:

- **Completion-driven scheduling** — an item launches the moment its own dependencies merge and advances the moment its previous stage finishes; it never waits for an unrelated sibling. The only synchronization points are the ones that should exist: the per-wave plan-reconciliation barrier (items that become ready at the same moment plan together, and waves take the spec-editing reconcile/escalate section one at a time) and the serialized merge queue.
- **Bounded loops** — max 2 fix rounds gated on Critical/High findings; the commit-attribution check runs against the actual `git log` message (never the agent's self-report), with two attempts and then a deterministic message rewrite, and merge commits get the same read-back check; one amendment round per reconciliation failure, always re-reconciled before building; at most one escalation-backed replan-and-rebuild per item after a spec-rooted mid-build failure.
- **Review throttling** — Codex reviews contend for one Codex auth; the script holds them to 2 concurrent slots while everything else parallelizes freely.
- **Judgment stays in agents, now explicit** — reconciliation, escalation (amend-vs-block per the rules below), and review verdicts are schema'd agent calls whose reasons land in the result, not discretion buried in a long context.
- **Resume and budget for free** — every agent call is journaled; an interrupted run resumes from where it stopped, and a session token target becomes a hard ceiling the loop respects.

### Before invoking

Review prompts need no preparation: the `orchestrify-review` agent carries the static adversarial template in its own definition and assembles each prompt itself, substituting only the run directory, the plan path, and the item's owned files from the Work Breakdown. The template names `spec.md` and the plan by **path** — never pasting their text — because the workflow's escalation agents amend `spec.md` mid-run, and a pasted copy would freeze the pre-run contract while the code under review correctly follows the amended one.

**Create the status tasks.** Once the breakdown is final, create one session task per work item — the live per-item surface the user watches during the run: `TaskCreate` with subject `Wn — <title>` for each item, then `TaskUpdate` with `addBlockedBy` mirroring each item's `deps` onto the created task ids. Put each item's task id into its `taskId` field in the Workflow args below; the script threads a `Status task:` line into every stage prompt, and the stage agents tick their own item's task as they run. A dependency-blocked item needs no updates from anyone — it truthfully sits `pending` with its blockers named on the task. This layer is display-only and fail-soft: if task creation fails, launch anyway — an item without a `taskId` simply gets no live row. The `integration` pseudo-item never gets a task.

**Invoke the Workflow tool** with the bundled script and the run's values (this skill instructing the call is the user's consent for workflow orchestration). Resolve the script path to absolute form first — `$HOME/.claude/skills/orchestrify/scripts/` at the default install location, this skill's own `scripts/` directory otherwise; do not pass `~` unexpanded. `runDir` and `repoRoot` must be absolute too — the script rejects relative paths at launch:

```
Workflow({
  scriptPath: "/abs/path/to/skills/orchestrify/scripts/work-loop.workflow.js",
  args: {
    runDir: "<run-dir>",
    repoRoot: "<repo-root>",
    slug: "<slug>",
    integrationBranch: "orchestrify/<slug>",
    items: [ { id: "W1", title: "…", deps: [], files: ["…"], taskId: "…" }, … ]   // verbatim from the spec's Work Breakdown, plus each item's status-task id
  }
})
```

Pass `args` — and `items` inside it — as real JSON values, never stringified. The script recovers a stringified `args` or `items` by parsing it, and otherwise fails fast at launch naming the bad field; on such a failure, fix this Workflow call and relaunch — do not wrap the script in another workflow. Persist the `runId` from the tool result immediately: append a `**Workflow run:** <runId>` line to the end of `spec.md`. It is the resume handle, and the interruption that needs it — session death — also erases the conversation, the only other place it would exist.

### What the workflow does

Per readiness wave (the items whose dependencies have all merged at that moment): plan agents in parallel → an opus reconciliation agent reads all of the wave's plans against the spec Interfaces → on issues, an escalation agent applies the **amend-vs-block** rule (below), edits `spec.md` itself for amendments, the affected plans are regenerated once, and the wave is re-reconciled before anything builds. A dependency an amendment adds between items is reported structurally and applied to the scheduler itself — a wave item whose new dependency has not merged yet is deferred and relaunched when it has. Then each ready item pipelines independently: worktree off the integration tip (a worktree left by a previous run's blocked item is resumed, not a collision) → `orchestrify-implement` → Codex review (an `orchestrify-review` agent drives Codex through the project's registered codex MCP server, read-only in the item's worktree; it parses the result before writing, writes the findings JSON verbatim as the artifact plus a per-round archive, and returns the counts — a dead tool call or unparseable payload comes back as a failure the workflow retries, never as a clean pass) → `orchestrify-fix` → re-review, gating commit on zero Critical/High (Medium/Low ride along only when recorded in the plan's Deviations; a first review with no findings at all skips the fix round) → `orchestrify-commit` with the attribution check → serialized `orchestrify-merge` in the integration worktree, self-healing any half-finished merge state first → best-effort worktree cleanup that can never demote a merged item. A mid-build failure that smells spec-rooted — an implementation reported infeasible, fix rounds exhausted on Critical/High findings, a semantically aborted merge — goes to the escalation agent once: an amendment replans and rebuilds the item once in its kept worktree; otherwise the item is cut (under prefer-smaller-scope) or blocked. After the loop drains, `orchestrify-integrate` verifies the assembled feature; if it applied fixes, they get one review-fix pass and are always committed (attribution-checked) — a failed review is recorded as a gap, never a reason to leave fixes uncommitted.

The escalation rule the workflow's agent applies is unchanged from the conversational design: **amend and continue** when a fix preserves the brief's outcome, features, and non-goals — the change touches only *how* — recording the decision in the spec's `## Decisions` log with the doubt rule cited; **block and route around** when every fix would change *what* was agreed, recording the reason and the options the user must choose between. A blocked item keeps its worktree and branch for a follow-up run, and never stalls unaffected work. When the doubt rule is prefer-smaller-scope and a feature can be cleanly cut rather than blocked, cutting it is an amendment.

### While it runs and after

The workflow runs in the background, but its `log()` lines (items merged, items blocked, amendments) are **not visible on any live surface while the run is in flight** ([anthropics/claude-code#74419](https://github.com/anthropics/claude-code/issues/74419)) — they land only in the `logs` array of the completion-time `workflows/<runId>.json`, where notable ones are read back for the report. The live mid-run surface is the **session task list** created above: stage agents advance each item's task through its stages via `activeForm`, dependency-blocked items sit `pending` with their blockers named, and merged items complete. When it completes, it returns `{ shipped, cut, blocked, integration, tokensSpent }`:

- Blocked items' worktrees and branches were kept — list them for the follow-up run.
- Proceed to Step 5; the returned values feed the report directly, with no intermediate status file to update.

**If the run is interrupted** — session death, a kill, a harness restart — do not re-run stages conversationally: re-invoke the Workflow tool with the same `scriptPath` and `args` plus `resumeFromRunId: "<runId>"`, reading the runId from the `**Workflow run:**` line at the end of `spec.md` (and rebuilding `args` from the spec's Work Breakdown). Completed agent calls replay instantly from the journal; only in-flight and remaining work runs live. Before resuming, reconcile leftover git state (`git worktree list`) only if the journal and the worktrees disagree. Migration note: a run started before the review stage moved to the `orchestrify-review` MCP agent cannot resume its review stages from the journal — the changed calls re-run live; everything before them still replays. Status tasks and resume: a `Status task:` line changes a stage call's journal key, but only when the item has a `taskId` — so resume a pre-taskId run **without** adding `taskId`s to the rebuilt args (the prompts stay byte-identical and everything replays; those items just get no live rows), and rebuild the args with the same `taskId`s for a run that already had them.

## Step 5: Report

Reconcile the status tasks first, from the returned values — the stage agents' updates are best-effort, so the terminal states are set here: every `shipped` item's task → `status: "completed"` (a backstop for a merge agent whose final update was skipped), every `cut` item's task → deleted, every `blocked` item's task → `status: "pending"` with the subject prefixed `✗ blocked — <short reason>` (the task list has no failed state; a pending row with the marker beats a spinner that never stops). Items without a `taskId` have no task to touch.

Write the run report to `<run-dir>/report.md` **first**, then relay its highlights to the user. The file is the durable record of the run: it outlives the conversation, so anyone resuming, auditing, or picking up a follow-up run reads it instead of scrolling back. Everything needed is at hand — the workflow's returned `shipped`, `cut`, `blocked`, and `integration` values, the spec's `## Decisions` log, and the `## Deviations` sections of the plan files under `<run-dir>/plans/`, where the fix agents record the Medium/Low findings they deferred and the findings rooted outside their item — the Follow-ups section is sourced from those Deviations. Do not re-explore beyond these artifacts. Generate the completion timestamp with `date +"%Y-%m-%d %H:%M"`.

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

After writing the file, give the user a short spoken summary — what shipped with commit hashes, anything `blocked` and the decision it waits on, the integration result feature by feature, tokens spent, and the path to the full `report.md` — then the landing command. The report file is the authoritative version; the spoken summary just points at it.

## Guidelines

- Never attribute commits to Claude. No commit produced by any agent in the run — commit agent, merge agent, integration fixes — may mention Claude, AI, agents, this orchestration process, or the user anywhere in the message: not the subject, not the body, not the footers. No `Co-Authored-By: Claude` and no `Generated with` trailers. Commit messages describe only the change itself. The workflow backstops this with a deterministic check of every commit message — including merge commits — read back from `git log`: unambiguous markers (Claude, Anthropic, `Co-Authored-By`, `Generated with`/`Generated by`) trigger a rewrite. Keeping "AI" and "agent" out of ordinary prose is the agents' own instruction — those are legitimate domain vocabulary in many repos, so no regex can police them without mangling honest messages.
- The main conversation never implements, reviews, or explores deeply itself. If you catch yourself reading source files at length in the main context, delegate.
- Each stage is a dedicated subagent type (`orchestrify-spec`, `orchestrify-plan`, `orchestrify-implement`, `orchestrify-review`, `orchestrify-fix`, `orchestrify-commit`, `orchestrify-merge`, `orchestrify-integrate`) whose instructions are its definition, loaded as its system prompt. The workflow spawns them by `agentType` and passes only the per-item values — run directory, worktree path, ID and title, owned files, branch names, artifact paths; the spec agent is spawned conversationally in Step 2 with the brief and repo root. The heavy stage instructions never enter the main context. Codex review runs cross-model but through the same shape: the `orchestrify-review` agent carries the static adversarial template, drives Codex through the project's registered codex MCP server (read-only sandbox, the item's worktree as cwd), writes the findings JSON verbatim to `<run-dir>/reviews/<ID>-codex.json` plus a per-round archive, and returns the counts the merge gate branches on. There is no review script and no shell relay; the counts are the review agent's own count of the findings it wrote — a decided trade, chosen for a review path with no scripts in it.
- State lives in files and the workflow journal, not in conversation memory. `spec.md` holds the breakdown and the `**Workflow run:**` runId line, `report.md` holds the outcome; mid-run state is the journal, and an interrupted run resumes with `resumeFromRunId` — never by re-running stages conversationally.
- Pass context between stages through artifact files, never by relaying summaries — the implement agent reads the plan file itself, the Codex reviewer reads the plan and diff itself and writes findings to its review file, and the fix agent reads that review file itself. Structured agent returns (verdicts, hashes, reconciliation results) exist for the workflow's control flow, not as a substitute for the artifacts.
- One worktree per work item, created by the workflow at the repo root off the shared bare repo, shared by that item's implement, Codex review, fix, and commit stages, removed only after merge. All worktrees — the user's, the integration tree, and each item — are peers off the bare repo; the run never reads or writes the user's worktree. Only the serialized merge agent writes the integration branch, inside the integration worktree.
- If a run is abandoned, clean up with `git worktree list` and remove any `orchestrify/` worktrees and branches left behind — but prefer resuming via `resumeFromRunId` over abandoning.
- After the Step 1 confirmation — and the optional breakdown checkpoint in Step 3, if the brief opted into it — the run never waits on the user: no approval requests, no clarifying questions, no AskUserQuestion. Ambiguity resolves against the spec and the doubt rule; what cannot be resolved that way becomes a `blocked` item in the final report.
- Keep the user informed at phase transitions with one or two one-way status lines relayed from the workflow's progress: items started, items merged, amendments made, anything blocked. Inform, never ask.
