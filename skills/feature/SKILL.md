---
description: Drive a feature from idea to committed code using a deterministic workflow over dedicated subagents — an autonomous orca feature run. A dispatcher over `.orca` state: triage offers to resume an interrupted run, to run a queued brief from `.orca/feat-briefs/`, or — with nothing waiting — interviews the idea into a durable brief (researching the touched subsystems through a subagent first, so the questions come from real friction with the code), then offers to run it now or leave it queued. The run restates the brief and confirms it once, writes a spec with a dependency-ordered work breakdown, then executes the work loop as a single Workflow-tool run that, per unblocked item, plans and implements in its own git worktree branched off a shared bare repository, reviews with an independent reviewer — cross-model Codex where it is installed or pinned, a dedicated fresh-context Claude reviewer otherwise — plus a Claude fix agent, commits, and serially merges into an integration worktree. Requires a bare-repo-with-worktrees layout (validated up front) and a harness with the Workflow tool; there is no privileged main checkout, and the run's deliverable is a branch the user lands themselves. After the opening confirmation — plus one optional breakdown checkpoint the brief opts into — nothing else asks the user anything; undecidable issues are reported at the end. Do not use for small single-file changes or when the user only wants a spec or a plan.
args: <idea>
user-invocable: true
disable-model-invocation: true
---

# Orca: feature

Coordinate a full implementation through isolated subagents. The main conversation handles everything interactive and cheap — the triage, the interview, the pre-flights, the spec, the checkpoint, and the final report — and delegates the long autonomous middle to **one deterministic workflow**: a bundled script, run through the Workflow tool, that spawns every stage agent with code-enforced control flow. All heavy context — codebase exploration, diffs, test output — lives and dies inside subagents; the main conversation only reads artifact files and the workflow's structured result.

Isolation is double: each subagent has its own context window, and each work item has its own git worktree. The repository is a bare repo, and every working copy — the user's, the run's integration tree, and each item — is a peer worktree off that one shared object store. There is no privileged main checkout: the run never reads or writes the user's worktree, and the deliverable is a branch the user lands themselves. Parallel items can never corrupt each other's files — overlap surfaces as an explicit merge conflict, resolved by a dedicated merge agent with both items' plans in hand.

The brief is where the user sets intent — written in this skill's interview or queued by an earlier one, discovered on disk, and confirmed once at the start of the run. It may also opt into a single checkpoint: a one-time review of the spec and work breakdown before any code is written. Apart from the opening confirmation and that opt-in checkpoint, never ask the user anything — no mid-run clarifications, no approval gates, no AskUserQuestion. The workflow runs autonomously in the background and could not pause for a question even if one arose; anything it cannot decide within the brief's stated intent becomes a `blocked` item surfaced in the final report.

## Step 0: Triage

This skill is a dispatcher over `.orca` state: what is on disk decides whether this invocation resumes, runs, or interviews. Work the ordered checks below at the repo root — resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir` — discovering by listing, never by reading files to decide. Present the first hit, but never force it: every offer includes starting something new instead.

### 1. An interrupted run

Discover everything waiting with one read-only script call:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/triage.sh discover
```

Each `RUN:` line is a feature run directory with no `report.md` yet, tagged `interrupted` — its workflow launched, and the `RUNID:`/`ARGS:` lines that follow carry the resume handle persisted in its `spec.md`, extracted byte-exact (plus legacy `REVIEWER:`/`AGENTS:` lines for runs recorded before the args line existed) — or `unlaunched` — it died before its workflow launched; not resumable, leave it alone. The same call emits check 2's `BRIEF:` lines, plus `CASE:` lines that belong to orca:debug's triage and `DONE:` lines (finished runs, each tagged `clean`, `leftovers`, or `unknown`) that belong to the recovery skills — when one shows `leftovers` (or `unknown`), mention that `/orca:retry` finishes its unmet items; when `clean`, that `/orca:followup` handles any follow-ups. A mention only — they are not offering branches here; this skill dispatches on `RUN:` and `BRIEF:` lines alone. Empty output means nothing is waiting; nothing is read into context.

The on-disk predicate cannot tell an interrupted run from one still executing — `report.md` only appears at the end — so before offering, check the run is not live: if this session's task list or background tasks show its workflow still running, it is in flight, not interrupted — report that and fall through to the next check. If another session could plausibly be driving it (the user would know), ask rather than assume.

Offer to resume. Several candidates → list the run directories by name and ask which. If the user declines in favor of new work, fall through to the next check.

To resume — never by re-running stages conversationally: take the `RUNID:` and `ARGS:` values the discovery emitted (the `**Workflow run:**`/`**Workflow args:**` lines persisted at the end of `spec.md`, extracted byte-exact), then re-invoke the Workflow tool exactly as Step 4 specifies — same `scriptPath`, the emitted args **verbatim**, plus `resumeFromRunId: "<RUNID>"`. Verbatim matters: any drift — item order, title wording, a `files` array, a substituted `taskId` — changes agent prompts and makes completed stages re-run instead of replaying from the journal; a stale `taskId` pointing at a dead session's task list is harmless (status updates are fail-soft, and agents skip a failed TaskUpdate). An `ARGS:` of `absent` marks a run recorded before the args line existed — fall back to rebuilding `args` from the spec's Work Breakdown, with the same `taskId`s the original launch used, the reviewer from the discovery's `REVIEWER:` line (`absent` → `codex`, the only reviewer that existed when reviewer-less specs were written), and the agents block from its `AGENTS:` line (`absent` → omit the key) — never from `.orca/config.json`, which may have changed since launch. Completed agent calls replay instantly from the journal; only in-flight and remaining work runs live. The status-line text embedded in stage prompts is part of the journal key too: a run launched under a plugin version with different status-line wording (e.g. before the stage suffix moved onto the subject) re-runs its taskId-carrying stages instead of replaying them. Before resuming, reconcile leftover git state (`git worktree list`) only if the journal and the worktrees disagree. Step 1's permissions pre-flight applies to a resume too — live stages will spawn agents. Its graceful decline applies with one correction: on a resume there is no queued brief to report — the brief was consumed into the run directory at launch — so report instead that the run stays resumable from its journal, and that enabling bypass (Shift+Tab) and re-invoking `/orca:feature` will rediscover it in triage. When the resumed workflow completes, continue at Step 5.

One hard boundary: a run started before this skill became the orca plugin **cannot resume** under it — agent types, worktree names, and journal keys all changed. Treat such a run as abandoned: clean up its leftovers per the Guidelines and start fresh.

### 2. A queued brief

The discovery's `BRIEF:` lines list `.orca/feat-briefs/*.md` — top level only (the `drafts/` subdirectory does not count); the top level holds only unconsumed briefs, so presence is status, and the timestamped names identify them.

- **Briefs waiting:** present the filenames and offer to run one — or to interview a new idea instead. Read only the chosen brief and proceed to Step 1 with it.
- **An `<idea>` argument alongside existing briefs:** if it names the same work as a queued brief, fold it into that brief as an amendment at the Step 1 confirmation; if it is unrelated, ask whether to run the queued brief anyway or interview the new idea into its own brief first.

### 3. Nothing waiting

Interview. Read `${CLAUDE_PLUGIN_ROOT}/skills/feature/interview.md` and follow it — it covers the research, the discussion, the early pre-flight, and writing the brief file. It is loaded only now, so a pure run or resume invocation never carries the interview instructions. The `<idea>` argument, if any, seeds the interview.

When the interview has written and approved its brief, ask once: **run it now, or leave it queued?**

- **Run now:** proceed to Step 1 with the just-written brief. The Step 1 restatement and confirmation run in full — the brief was written seconds ago in this very conversation, but the file, not the conversation, is the authorized intent, and the confirmation is what authorizes the run.
- **Queue:** tell the user the brief is ready and where it lives, and that invoking `/orca:feature` in this repository when ready will find it — no path or link needed; it will be restated, age-checked, and confirmed once before running. End cleanly.

## Step 1: Confirm the brief

The brief is the only place intent was captured — once this step ends, the run is autonomous and every later ambiguity gets resolved against what the brief says. Restate it to the user: outcome, features, non-goals, direction decisions (when the brief has a Direction section), inputs/outputs, constraints, doubt rule, and breakdown-checkpoint choice, plus any amendments folded in from an idea argument. Note the brief's age from its `Created` line and warn when it is more than a few days old — the codebase and the user's intent may have moved since it was written.

If the brief is missing the doubt rule or the checkpoint choice (the interview always writes them; a hand-written brief may not), apply the defaults — prefer-smaller-scope, straight-through — and state them in the restatement rather than asking. The breakdown checkpoint, when the brief opts in, is a one-time review of the spec and work breakdown before any worktree or code: the decomposition is where parallel-agent mistakes originate, and it is the only optional pause in the run.

The user's confirmation of the restated brief authorizes the run. If the brief opted into the breakdown checkpoint, the only remaining interaction is that one approval in Step 3; otherwise there is no later gate at all. From this point on, never ask the user anything else; proceed on recorded assumptions.

### Environment pre-flight (script)

The run's mechanical prerequisites — the bare-repo layout and, when the reviewer is codex, the Codex tooling — are validated by one bundled script, which also resolves **which independent reviewer this run uses**. If the interview's early pre-flight already ran the script in this same invocation, reuse its output — gates and reviewer line alike — instead of re-running it; re-run only when it reported a `FAIL` the user has since fixed. Otherwise run it during this step, before the confirmation, from the project root:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh
```

`${CLAUDE_PLUGIN_ROOT}` substitutes to this plugin's installed root, so the resulting path is already absolute. The script is read-only and prints one line per gate plus a final result:

- `BARE_REPO: PASS|FAIL` — the project is a bare repository with worktrees.
- `TRUNK_CANDIDATE: <branch>` — informational, not a gate: the bare repo's default branch, the run's likely trunk. Confirm the trunk with the user; the integration branch is created from its tip.
- `REVIEWER: codex|claude (pinned|detected)` — informational, but load-bearing for this run: the resolved reviewer. `pinned` means the `reviewer` key in `.orca/config.json` chose it; `detected` means the key is absent and the machine decided (codex binary on PATH at the minimum version → codex, else claude). A `REVIEWER: FAIL` line means the config key is invalid — point the user at orca:config and stop.
- `CODEX: PASS|FAIL|SKIPPED` — checked only when the resolved reviewer is codex: the global `codex` binary is on PATH at or above the minimum version, authenticated, and `MCP_TOOL_TIMEOUT` is set in a settings env block. With reviewer claude it prints `SKIPPED` — not checked, deliberately.
- `RESULT: PASS|FAIL` — mirrored by the exit code, which is 0 iff every gate passed.

There is no agents gate and no MCP-registration gate: the stage agents and the codex MCP server registration ship inside this plugin, so a session that can run this skill has them by construction.

On `RESULT: PASS`, proceed. On any `FAIL`, do not start — relay the failing gate's remediation below and stop. These are pre-flight gates, not mid-run questions. In particular, a pinned or detected codex whose auth or timeout check fails is a `FAIL` to fix via orca:doctor — never a reason to silently run with the claude reviewer instead.

One gate the script cannot check: the harness must expose the **Workflow tool** (Step 4 runs through it). If this session has no Workflow tool, stop and tell the user this skill requires a Claude Code harness with workflows.

A second gate only the session can check, **and only when the resolved reviewer is codex** — the **live MCP gate**: MCP servers load at session start, so the plugin's bundled registration is only useful if this session actually loaded it (a plugin installed or enabled minutes ago has not). Before launching the workflow, confirm the tool actually resolves: call ToolSearch with `select:mcp__plugin_orca_orca-codex__codex`. If it does not resolve, diagnose which of the two causes this is before stopping. A known harness bug (present as of Claude Code 2.1.202) loads none of a plugin's bundled MCP servers when the project carries any MCP config of its own — a `.mcp.json` at the repo root, or local-scope servers (`claude mcp list` shows both, or read the file). If such config exists, that is the cause: a leftover `codex` registration is redundant — the plugin bundles the server — and the user should remove it; a project that genuinely needs its own MCP servers can pin `reviewer=claude` via orca:config until the harness bug is fixed, with the cross-model trade-off stated. If no such config exists, the session simply predates the plugin's install or enablement. Either way, the user fixes the cause and starts a fresh session in this project — the brief is untouched — and you stop. With reviewer claude there is no MCP dependency and this check is skipped.

**Why each gate, and how to fix a `FAIL`:**

- **Bare repo** is the substrate the entire run depends on: every working copy — the user's, the integration tree, each item — is a peer worktree off one shared bare object store, so there is no privileged main checkout to corrupt. A `FAIL` means the repo is a conventional checkout. Converting it is the user's decision — never convert autonomously. Point them at the **orca:init skill**, which performs the conversion interactively with consent per step (and also sets up new repositories and bare clones); it preserves untracked files like `.env` that a naive re-checkout would lose.
- **Reviewer** is the work loop's independent review. **Codex** — the default wherever the binary is installed — is the cross-model choice: a different model family from the Claude implementer, so it does not share the implementer's blind spots. **Claude** (the `orca:review-claude` agent) keeps fresh-context independence — a separate agent seeing only the artifacts and the diff, with an adversarial contract — but is same-model; it is the detected fallback where codex is not installed, and a legitimate pin either way via orca:config.
- **Codex**, when it is the reviewer: a missing, stale, or unauthenticated reviewer would fail every item at review time, deep into an autonomous run. The reviewer is the **global codex binary's MCP server** (`codex mcp-server`), registered by this plugin's bundled `.mcp.json` wherever the plugin is active — codex is **never installed via npm**: the only supported install is the system one on PATH, from the official non-npm distribution (e.g. `brew install codex`, or the release binaries). Whatever the failing check — install, upgrade, `codex login`, or the `MCP_TOOL_TIMEOUT` settings write — point the user at the **orca:doctor skill**, which walks the machine gates interactively (a plugin cannot set the session env that governs MCP tool-call timeouts, so that knob stays a per-repo or per-user settings write). Installing, authenticating, and settings writes are the user's actions — surface the fix, do not do it autonomously.

### Permissions pre-flight

The run only stays autonomous if the harness will not raise permission prompts: subagents — including every agent the workflow spawns — inherit this session's permission mode, and the skill's own frontmatter does not propagate to them. A single foreground prompt mid-run breaks autonomy, and an auto-denied call makes an agent fail confusingly instead.

**This requires `bypassPermissions` mode — an allow-list is not sufficient.** The subagents are themselves models that decide commands at runtime (dependency installs, build and test variants, git invocations with assorted flags, `find`, `sed`, and so on), so the command set is open-ended and no static `permissions.allow` list can anticipate it. Beyond that, the harness matches Bash rules as prefix globs against the literal command string, so even listed commands slip through when they contain `$(…)` substitutions, lead with flags like `git --git-dir=…`, or are compound (`cd foo && …`). A leaked prompt is therefore a question of *when*, not *whether* — which is why the fix is the session mode, not the rules.

The skill cannot flip the mode itself, so confirm it during this step, before the confirmation: the session must be in `bypassPermissions` mode for the run. Enable it one of three ways:

- **In-session toggle** — press Shift+Tab to cycle the permission mode until the footer shows "bypass permissions". Easiest; do it right before the run.
- **Launch flag** — start the CLI with `claude --dangerously-skip-permissions`.
- **Settings** — `"permissions": { "defaultMode": "bypassPermissions" }` in `.claude/settings.local.json`, for a repo where runs are always unattended.

Make the tradeoff explicit to the user: bypass mode disables the approval gate for the *whole* session, not just this run's commands. That is the point — the run is designed to be unattended — but any other work in the same session loses the gate too, so a dedicated session for the run is the clean choice. If the user will not enable bypass mode now, the run cannot start — it would not be autonomous, and an allow-list would only let it pause partway — but do not fail the invocation: the brief is already durable. Report that the brief is saved and queued, that enabling bypass (Shift+Tab) and re-invoking `/orca:feature` — ideally in a dedicated session — will find it and run it, and end cleanly.

## Step 2: Write the spec and work breakdown

Create the run directory at the project root — the directory that holds the bare repo and its worktrees. It holds only run metadata. Every worktree lives at the **top level of the repo**, as a sibling of the bare repo and the user's own worktrees — never inside `.orca/`:

```text
<repo-root>/
├── .bare/                              # the bare repository (shared object store)
├── <user worktrees…>                   # e.g. main/ — untouched by the run
├── orca-<slug>/                        # integration worktree (branch feature/<slug>)
├── orca-<slug>-<ID>/                   # one worktree per in-flight item (e.g. orca-<slug>-W1, branch feature/<slug>-W1)
└── .orca/YYYYMMDD-HHMMSS-feat-<slug>/
    ├── brief.md    # the consumed brief — the run's confirmed intent
    ├── spec.md     # requirements, interfaces, work breakdown, workflow runId
    ├── report.md   # final run report, written at the end
    ├── plans/      # one plan file per work item, written by plan agents; <ID>.round*.md are superseded plans archived at replan
    └── reviews/    # review findings artifacts (codex or claude), archived per round
```

- `<repo-root>` is the directory containing the bare repo — resolve it as the parent of `git rev-parse --path-format=absolute --git-common-dir`.
- Generate the timestamp by running `date +%Y%m%d-%H%M%S`.
- Make `<slug>` a short kebab-case description of the idea, 3-5 words max. The `feat-` marker in the run directory's name is fixed: it is what lets an `ls .orca/` tell feature runs from other verbs' runs at a glance.
- Worktree directories sit at `<repo-root>` and are named after the run — `orca-<slug>` for integration, `orca-<slug>-<ID>` for each item — while their branches use the neutral `feature/<slug>[-<ID>]` namespace. The difference is deliberate: the `orca-*` directory names are local scratch and the run's cleanup/discovery story (`git worktree list`), and never enter git; the `feature/*` branch names are what lands in git and shows on GitHub, so they carry no orca trace. The `.orca/` metadata is scratch space on disk, outside every worktree, so nothing in it can be committed by accident.

Consume the brief now: `mv` it to `<run-dir>/brief.md`. The move is what marks it used — the briefs directory only ever holds unconsumed briefs — and it archives the confirmed intent with the run that acted on it.

### Project context: refresh or seed

The run's judgment stages start from two machine-local hint files at the top level of `.orca/` — `map.md` (the codebase map: module boundaries, entry points, build/test commands, conventions, gotchas) and `decisions.md` (the decision log: `chose X over Y: <reason>` entries with date, run id, and carrying commit). Both are **caches over what git already shares** — the map over the code, the log over commit-message history — stamped `**As of:** <short-sha>` in their headers, never committed, and framed to every consumer as hints to verify, not ground truth. Before spawning the spec agent, make them current against the confirmed trunk's tip (`git rev-parse --short <trunk>`):

- **Both present, both stamps equal the tip** (grep each header): skip — back-to-back runs pay nothing.
- **Present but stale:** spawn one subagent (model haiku) to catch them up, passing the two paths, the trunk tip, and these instructions: amend and prune `map.md` from `git diff --stat <map-stamp>..<tip>` — delete invalidated claims, keep it under ~200 lines, architecture altitude only; reconstruct missed decisions into `decisions.md` from `git log <dec-stamp>..<tip>` — full history, never `--first-parent`: item-scoped bullets live in item commits on each merge's second parent, run-scoped ones in merge commits, all as `chose X over Y: <reason>` lines; append one dated entry per bullet (commit-message fidelity is fine — the gist is what cross-run consistency needs); advance both stamps to the tip. If git no longer knows a stamped sha, rebuild that file conservatively rather than trusting it.
- **`map.md` missing:** seed. Spawn one exploration subagent to write the initial map — the only full-project sweep the design ever performs — under the same format, cap, and stamp rules. Create `decisions.md` yourself with only a `# Decision log` header and the stamp.

Failure here is non-fatal: a run with stale or missing context files still runs — every consuming agent treats a missing file as skippable.

With the run directory scaffolded, **delegate the spec — do not explore the codebase in the main context.** Heavy exploration lives and dies in a subagent, and the main conversation only reads the artifact that comes back. Spawn one `orca:spec` subagent, passing only:

- the run directory
- the repository root (`<repo-root>`)
- the current timestamp, from `date +"%Y-%m-%d %H:%M"` — the agent has no shell, so it cannot generate one for the spec's `Created` line
- the **brief**: the outcome, features, non-goals, direction decisions (the Direction section, when present — settled decisions that bind the spec the same way constraints do), inputs/outputs, constraints, and doubt rule from the confirmed brief, plus any amendments confirmed with it
- a `Project context:` line naming `<repo-root>/.orca/map.md` (codebase map) and `<repo-root>/.orca/decisions.md` (decision log), framed as hints from a snapshot at the commit stamped in each header — verify anything relied on; a missing file is skipped, not an error

**Read the model config once, before the spec spawn.** Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh validate` now, while nothing has been spent — the same vocabulary the workflow script re-checks at launch, but a failure there would land only after the whole spec stage has run. On success it emits `VALID:` followed by one-line JSON carrying the pinned `reviewer` (when set) and the canonical `agents` block (when non-empty) — exactly the values the Workflow args take; an absent config file emits `VALID: {}`. Hold that JSON for the rest of the run: Step 4 passes the held values into the Workflow args, and no step re-reads the file — a config edited mid-run must not change a run already in flight. On a typed `FAIL:` line, stop before spawning anything, relay the field it names, and point the user at orca:config — never author or repair the file here.

**Hold the resolved reviewer alongside it.** The run's reviewer is the held JSON's `reviewer` when present (the pinned value), else the detected value from Step 1's `REVIEWER:` preflight line — that line is the source; do not probe the machine a second time. The held value goes into the Workflow args and the spec.md record below; like the agents block, it is fixed at launch.

If the held block sets `agents.spec.model`, spawn the spec agent with that model override — on every spec spawn, including a Step 3 checkpoint re-spawn; effort has no conversational override — the Agent tool has no effort parameter — so the spec agent's effort always comes from its own definition.

Pass the brief faithfully — it is the whole of the user's intent, and every later autonomous decision cites the spec it produces. The agent explores the codebase, defines the shared **Interfaces Between Work Items**, and writes the full spec — outcome, features, non-goals, inputs/outputs, interfaces, a 2-8 item dependency-ordered **Work Breakdown** with file ownership, assumptions, the doubt rule, and risks — to `<run-dir>/spec.md`, returning a short summary. Its exploration dies with its context; only `spec.md` and the summary return. If the agent reports that the requested scope cannot be split cleanly against the codebase — a feature the existing code fights, an interface it forces — surface that to the user and stop rather than launching a run against a spec known to be wrong.

The spec agent authors `spec.md` **once**. During the run, mid-loop amendments — interface revisions, breakdown changes, the `## Decisions` log — are made by the workflow's escalation agent (Step 4), never by a re-spawn; the sole exception is a structural revision requested at the Step 3 checkpoint, which re-spawns the spec agent (see Step 3).

Read the returned `spec.md` — an artifact, not source. Its Work Breakdown is the run's item list; there is no separate status file to maintain. Mid-run, the live status is the workflow's own progress display and journal — do not poll files during the run — and the final outcome lands in `report.md`.

## Step 3: Announce and proceed

Report the spec to the user — outcome, work items, dependency order, what will run in parallel, key assumptions. How this lands depends on the breakdown-checkpoint choice recorded in the brief:

- **Opted out (the default):** this is a one-way status update. Proceed immediately; do not wait for or request approval — the Step 1 confirmation already authorized the run. If the user interjects on their own, incorporate it; never solicit it.
- **Opted in:** this is the one authorized pause. Present the spec and breakdown and ask once for approval. Incorporate any changes they request: a **structural** revision — re-splitting items, reordering dependencies, reworking an interface — re-spawns the `orca:spec` agent with the current `spec.md` plus the requested changes (and the held `agents.spec.model` override from Step 2, when set), because it may need fresh codebase exploration; a **trivial** revision — wording, a renamed item, a tweaked assumption — edit inline. Then proceed. This is the final interactive moment of the run; after it, the run is autonomous and never waits on the user again.

Set the spec status to `approved`. Create the integration worktree at the repo root, on a fresh branch. The base is the trunk tip — unless the brief's Direction section carries a `**Base branch:**` field (followup briefs over an unlanded deliverable set it): then the run must build on that branch, so the worktree contains the feature being extended. Verify a named base exists first (`git rev-parse --verify refs/heads/<base-branch>` against the bare repo); a `**Base branch:**` that names a missing branch is a hard stop — report it and let the user decide, never silently fall back to the trunk (the run would build against code that lacks the feature it extends).

```bash
git worktree add <repo-root>/orca-<slug> -b feature/<slug> <base-branch, or the trunk when the brief names none>
bash ${CLAUDE_PLUGIN_ROOT}/scripts/secrets.sh place <repo-root>/orca-<slug>
```

The branch is `feature/<slug>` — a neutral namespace that reads as ordinary dev work on GitHub and leaves no orca trace in git history; the slug keeps it collision-unlikely. In the no-base case, `worktree add -b` fails loudly if `feature/<slug>` already exists, never silently reusing it — if it does, pick a different slug and retry rather than reusing the existing branch. (With a `**Base branch:**`, the new branch name must still be fresh — the same rule applies to it, not to the base.)

The `place` call links the user's secrets (`<repo-root>/.orca/secrets/`, the mirror-tree convention — the README documents it) into the fresh worktree as relative symlinks, so integration builds and tests find their `.env`s. It is idempotent and best-effort: a missing or empty secrets tree is a clean `OK` no-op, and per-file problems are typed skips, never a reason to stop the run — relay any `UNIGNORED:` or `SKIPPED_EXISTS:` lines to the user as one-way status.

Completed items are merged into this branch, and `feature/<slug>` is the run's deliverable — the user lands it onto trunk themselves at the end. The run never checks out or writes the user's own worktree.

The spec must also record the **doubt rule** from the brief — every later autonomous decision cites it.

## Step 4: Run the work loop (workflow)

The work loop runs as **one deterministic workflow**, not as conversational orchestration. The bundled script `scripts/work-loop.workflow.js` encodes the loop's every rule as code, so the guarantees the run depends on are structural, not model discipline that decays over a long context:

- **Completion-driven scheduling** — an item launches the moment its own dependencies merge and advances the moment its previous stage finishes; it never waits for an unrelated sibling. The only synchronization points are the ones that should exist: the per-wave plan-reconciliation barrier (items that become ready at the same moment plan together, and waves take the spec-editing reconcile/escalate section one at a time) and the serialized merge queue.
- **Bounded loops** — max 2 fix rounds gated on Critical/High findings; the commit-attribution check runs against the actual `git log` message (never the agent's self-report), with two attempts and then a deterministic message rewrite, and merge commits get the same read-back check; one amendment round per reconciliation failure, always re-reconciled before building; at most one escalation-backed replan-and-rebuild per item after a spec-rooted mid-build failure.
- **Review throttling** — Codex reviews contend for one Codex auth; the script holds them to 2 concurrent slots while everything else parallelizes freely. Codex-only: claude reviews have no shared auth and ride the workflow's normal concurrency cap.
- **Judgment stays in agents, now explicit** — reconciliation, escalation (amend-vs-block per the rules below), and review verdicts are schema'd agent calls whose reasons land in the result, not discretion buried in a long context.
- **Resume and budget for free** — every agent call is journaled; an interrupted run resumes from where it stopped, and a session token target becomes a hard ceiling the loop respects.

### Before invoking

Review prompts need no preparation: the reviewer agent — `orca:review-codex` (the Codex courier) or `orca:review-claude`, per the held reviewer — carries the adversarial review contract in its own definition and assembles each review itself, substituting only the run directory, the artifact paths, and the item's owned files from the Work Breakdown. The contract names `spec.md` and the plan by **path** — never pasting their text — because the workflow's escalation agents amend `spec.md` mid-run, and a pasted copy would freeze the pre-run contract while the code under review correctly follows the amended one.

**Pass the model config.** If the `agents` block held since Step 2 is non-empty, pass it verbatim into the Workflow args as `agents` — per-stage `{model, effort}` overrides that the script applies on top of each stage agent's own defaults. Otherwise omit the key entirely. Do not re-read `.orca/config.json` here: the held block is the run's config generation, validated in Step 2, and a file edited since then must not change this run. The script re-validates at launch as a backstop; a failure there means the block was not passed verbatim — fix this call, and point the user at orca:config only if the file itself was bad.

**Pass the reviewer — always.** The `reviewer` arg is required and carries the resolved value held since Step 2 (`"codex"` or `"claude"`), never absent: the script cannot run shell commands, so all detection happened in the preflight, and a resume must replay the launch-time reviewer rather than re-detect.

**Create the status tasks.** Once the breakdown is final, create one session task per work item — the live per-item surface the user watches during the run: `TaskCreate` with subject `Wn — <title>` for each item, then `TaskUpdate` with `addBlockedBy` mirroring each item's `deps` onto the created task ids. Put each item's task id into its `taskId` field in the Workflow args below; the script threads a `Status task:` line into every stage prompt, and the stage agents tick their own item's task as they run. A dependency-blocked item needs no updates from anyone — it truthfully sits `pending` with its blockers named on the task. This layer is display-only and fail-soft: if task creation fails, launch anyway — an item without a `taskId` simply gets no live row. The `integration` pseudo-item never gets a task.

**Invoke the Workflow tool** with the bundled script and the run's values (this skill instructing the call is the user's consent for workflow orchestration). The script lives at `${CLAUDE_PLUGIN_ROOT}/scripts/work-loop.workflow.js` — the substituted value is already absolute; never pass `~` or an unsubstituted variable. `runDir` and `repoRoot` must be absolute too — the script rejects relative paths at launch:

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/scripts/work-loop.workflow.js",
  args: {
    runDir: "<run-dir>",
    repoRoot: "<repo-root>",
    slug: "<slug>",
    integrationBranch: "feature/<slug>",
    items: [ { id: "W1", title: "…", deps: [], files: ["…"], taskId: "…" }, … ],  // verbatim from the spec's Work Breakdown, plus each item's status-task id
    reviewer: "<codex|claude>",  // the resolved reviewer held since Step 2 — always present
    agents: { … },  // only when the block held since Step 2 is non-empty — passed verbatim
    pluginRoot: "${CLAUDE_PLUGIN_ROOT}"  // the substituted absolute path — the loop runs secrets.sh place after every worktree add
  }
})
```

Pass `args` — and `items` inside it — as real JSON values, never stringified. The script recovers a stringified `args` or `items` by parsing it, and otherwise fails fast at launch naming the bad field; on such a failure, fix this Workflow call and relaunch — do not wrap the script in another workflow. Persist the resume handle from the tool result immediately: append a `**Workflow run:** <runId>` line to the end of `spec.md` and a `**Workflow args:** <the args object as one-line JSON, exactly as passed>` line beside it. The args line is what a resume replays **verbatim** — any rebuild drift (item order, title wording, a `files` array) would change agent prompts and silently re-run completed stages instead of replaying them, and after session death the original `taskId`s exist nowhere else on disk. That interruption — session death — also erases the conversation, the only other place the launch-time values exist, and `.orca/config.json` may have been edited or reset since launch, so the config file can never stand in for these lines.

### What the workflow does

Per readiness wave (the items whose dependencies have all merged at that moment): plan agents in parallel → an opus reconciliation agent reads all of the wave's plans against the spec Interfaces → on issues, an escalation agent applies the **amend-vs-block** rule (below), edits `spec.md` itself for amendments, the affected plans are regenerated once, and the wave is re-reconciled before anything builds. A dependency an amendment adds between items is reported structurally and applied to the scheduler itself — a wave item whose new dependency has not merged yet is deferred and relaunched when it has. Then each ready item pipelines independently: worktree off the integration tip (a worktree left by an interrupted run is resumed in place, and a blocked item's kept branch — salvaged WIP commit included — gets its worktree re-added, never a collision) → `orca:implement` → independent review (with reviewer codex, an `orca:review-codex` agent drives Codex through the plugin's bundled codex MCP server, read-only in the item's worktree, parses the result before writing, and writes the findings JSON verbatim; with reviewer claude, an `orca:review-claude` agent performs the review itself under the same adversarial contract and writes findings in the identical schema — either way the artifact plus a per-round archive land in `reviews/`, and a dead tool call, unparseable payload, or tripped self-check comes back as a failure the workflow retries, never as a clean pass) → `orca:fix` → re-review, gating commit on zero Critical/High (Medium/Low ride along only when recorded in the plan's Deviations; a first review with no findings at all skips the fix round) → `orca:commit` with the attribution check → serialized `orca:merge` in the integration worktree, self-healing any half-finished merge state first → best-effort worktree cleanup that can never demote a merged item. A mid-build failure that smells spec-rooted — an implementation reported infeasible, fix rounds exhausted on Critical/High findings, a semantically aborted merge — goes to the escalation agent once: an amendment replans and rebuilds the item once in its kept worktree; otherwise the item is cut (under prefer-smaller-scope) or blocked. After the loop drains, `orca:integrate` verifies the assembled feature; if it applied fixes, they pass the same bounded review → fix → re-review gate as items (zero Critical/High within two rounds) and are committed (attribution-checked) only on a clean pass — a failed or blocked review leaves them uncommitted in the integration worktree, records the gap, and marks the run's deliverable state `unverified` rather than shipping the one unreviewed edit of the run. Last, when anything shipped, an `orca:context` agent folds the run into the machine-local project context — amending and pruning `map.md` from the run's diff, appending the run's load-bearing decisions to `decisions.md`, and returning rule-shaped knowledge as promotion suggestions for the report; it distills the run's artifacts only, never re-explores, and its failure is non-fatal — the run still delivered its branch.

The escalation rule the workflow's agent applies is unchanged from the conversational design: **amend and continue** when a fix preserves the brief's outcome, features, and non-goals — the change touches only *how* — recording the decision in the spec's `## Decisions` log with the doubt rule cited; **block and route around** when every fix would change *what* was agreed, recording the reason and the options the user must choose between. A blocked item keeps its **branch** — whatever was in its worktree is salvaged into a WIP commit and the worktree removed — for a `/orca:retry` round, and never stalls unaffected work. When the doubt rule is prefer-smaller-scope and a feature can be cleanly cut rather than blocked, cutting it is an amendment.

### While it runs and after

The workflow runs in the background, but its `log()` lines (items merged, items blocked, amendments) are **not visible on any live surface while the run is in flight** ([anthropics/claude-code#74419](https://github.com/anthropics/claude-code/issues/74419)) — they land only in the `logs` array of the completion-time `workflows/<runId>.json`, where notable ones are read back for the report. The live mid-run surface is the **session task list** created above: stage agents advance each item's task through its stages by suffixing the stage onto the subject (`Wn — <title> · implementing`) — the collapsed task panel renders only subjects, so that suffix is what the user actually sees; `activeForm` is mirrored for surfaces that show it. Dependency-blocked items sit `pending` with their blockers named, and only the merge stage completes an item's task — every other stage's status line forbids it, so a task ticking done early is a stage agent violating its line, not the design. When it completes, it returns `{ shipped, cut, blocked, integration, deliverableState, promotions, tokensSpent }` — `deliverableState` is the run's terminal verdict on the branch: `verified` (the integrate agent completed and the branch tip is exactly the tree it verified), `unverified` (merged work exists but the verifier died or its fixes never landed reviewed — never describe such a branch as a completed deliverable), or `built` (nothing merged, verification never ran):

- Blocked items' branches were kept, each holding a salvaged WIP commit when partial work existed — list them for `/orca:retry`.
- Proceed to Step 5; the returned values feed the report directly, with no intermediate status file to update.

**If the run is interrupted** — session death, a kill, a harness restart — do not re-run stages conversationally: the run stays resumable from its journal, and a later `/orca:feature` invocation discovers it in triage and offers the resume (Step 0), replaying the `**Workflow args:**` line persisted beside the `**Workflow run:**` runId at the end of `spec.md`. If the interruption happened in this still-living session, resume the same way — Step 0's resume branch, from the spec's persisted lines, not from conversation memory.

## Step 5: Report

Reconcile the status tasks first, from the returned values — the stage agents' updates are best-effort, so the terminal states are set here: every `shipped` item's task → `status: "completed"` with the subject restored to the clean `Wn — <title>` (a backstop for a merge agent whose final update was skipped, which would also leave a stale ` · <stage>` suffix on the subject), every `cut` item's task → deleted, every `blocked` item's task → `status: "pending"` with the subject rewritten to `✗ blocked — Wn — <title> — <short reason>`, dropping any stage suffix (the task list has no failed state; a pending row with the marker beats a spinner that never stops). Items without a `taskId` have no task to touch.

Write the run report to `<run-dir>/report.md` **first**, then relay its highlights to the user. The file is the durable record of the run: it outlives the conversation, so anyone resuming, auditing, retrying, or picking up a follow-up reads it instead of scrolling back. Everything needed is at hand — the workflow's returned `shipped`, `cut`, `blocked`, `integration`, `deliverableState`, and `promotions` values, the spec's `## Decisions` log, and the `## Deviations` sections of the plan files under `<run-dir>/plans/` (skip `<ID>.round*.md` — superseded plans archived at replan), where the fix agents record the Medium/Low findings they deferred and the findings rooted outside their item — the Follow-ups section is sourced from those Deviations plus `integration.fixNotes` (the integration-fixes pass has no plan file, so its fixer's declines and escalations come back on the workflow result and are mirrored at `<run-dir>/integration-fixes.json`; declines belong in Deviations, escalations in Follow-ups), and Knowledge worth promoting from the returned `promotions`. Do not re-explore beyond these artifacts. Generate the completion timestamp with `date +"%Y-%m-%d %H:%M"`.

```markdown
# Report: <idea summary>

**Run:** <run-dir>
**Completed:** <YYYY-MM-DD HH:MM>
**Deliverable:** `feature/<slug>`
**Deliverable state:** <the returned `deliverableState`: verified | unverified | built — with `unverified`, one line naming why (verifier died, or fixes left uncommitted); the branch must never be described as verified or complete when the state says otherwise>

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

- <Deferred work, known gaps, and weak spots the reviews flagged but did not block — the optional next steps `/orca:followup` selects from. Blocked items belong in the Blocked section above, not here: `/orca:retry` owns them, and each keeps its branch (with any salvaged WIP commit) until then.>

## Knowledge worth promoting

- <From the workflow's returned `promotions`: rule-shaped knowledge or documentation the context agent flagged as belonging in CLAUDE.md or the repo's real docs. Orca proposes; the human commits it under their own name — no orca agent ever writes CLAUDE.md. "None" if empty.>

## Landing

The deliverable is the `feature/<slug>` branch, built in the integration worktree. Walk the diff in your own editor first with `/orca:review`, then land it from your own worktree with `git merge --no-ff feature/<slug>`, then optionally push. <When items are blocked: `/orca:retry` resolves the decisions recorded above with you and relaunches only the unmet items on the same branch.> <When Follow-ups list deferred work: `/orca:followup` turns the ones you select into the next run's brief.>
```

After writing the file, give the user a short spoken summary — what shipped with commit hashes, anything `blocked` and the decision it waits on, the integration result feature by feature, any knowledge worth promoting (theirs to commit, not orca's), tokens spent, and the path to the full `report.md` — then the landing command. When the run left blocked items, mention that `/orca:retry` resolves their recorded decisions and finishes them inside this same run; when it left follow-ups, that `/orca:followup` turns the selected ones into the next run's brief. The report file is the authoritative version; the spoken summary just points at it.

## Guidelines

- Never attribute commits to Claude. No commit produced by any agent in the run — commit agent, merge agent, integration fixes — may mention Claude, AI, agents, this orchestration process, or the user anywhere in the message: not the subject, not the body, not the footers. No `Co-Authored-By: Claude` and no `Generated with` trailers. Commit messages describe only the change itself. The workflow backstops this with a deterministic check of every commit message — including merge commits — read back from `git log`: unambiguous markers (Claude, Anthropic, `Co-Authored-By`, `Generated with`/`Generated by`, `orca`) trigger a rewrite. Keeping "AI" and "agent" out of ordinary prose is the agents' own instruction — those are legitimate domain vocabulary in many repos, so no regex can police them without mangling honest messages.
- The main conversation never implements, reviews, or explores deeply itself. If you catch yourself reading source files at length in the main context, delegate.
- Each stage is a dedicated subagent type (`orca:spec`, `orca:plan`, `orca:implement`, `orca:review-codex` or `orca:review-claude` per the run's reviewer, `orca:fix`, `orca:commit`, `orca:merge`, `orca:integrate`) whose instructions are its definition, loaded as its system prompt. The workflow spawns them by `agentType` and passes only the per-item values — run directory, worktree path, ID and title, owned files, branch names, artifact paths; the spec agent is spawned conversationally in Step 2 with the brief and repo root. The heavy stage instructions never enter the main context. Review runs through the same shape either way: with reviewer codex, the `orca:review-codex` agent carries the static adversarial template, drives Codex through the plugin's bundled codex MCP server (read-only sandbox, the item's worktree as cwd), and writes the findings JSON verbatim; with reviewer claude, the `orca:review-claude` agent performs the review itself under the same adversarial contract. Both write to `<run-dir>/reviews/<ID>-<reviewer>.json` plus a per-round archive in the identical schema and return the counts the merge gate branches on. There is no review script and no shell relay; the counts are the review agent's own count of the findings it wrote — a decided trade, chosen for a review path with no scripts in it.
- State lives in files and the workflow journal, not in conversation memory. `spec.md` holds the breakdown plus the persisted `**Workflow run:**` and `**Workflow args:**` lines, `report.md` holds the outcome; mid-run state is the journal, and an interrupted run resumes with `resumeFromRunId` — never by re-running stages conversationally.
- Pass context between stages through artifact files, never by relaying summaries — the implement agent reads the plan file itself, the reviewer reads the plan and diff itself and writes findings to its review file, and the fix agent reads that review file itself. Structured agent returns (verdicts, hashes, reconciliation results) exist for the workflow's control flow, not as a substitute for the artifacts.
- One worktree per work item, created by the workflow at the repo root off the shared bare repo, shared by that item's implement, review, fix, and commit stages, removed only after merge. All worktrees — the user's, the integration tree, and each item — are peers off the bare repo; the run never reads or writes the user's worktree. Only the serialized merge agent writes the integration branch, inside the integration worktree.
- If a run is abandoned, clean up with `git worktree list` and remove any leftover `orca-*` worktrees plus their `feature/<slug>*` branches — but prefer resuming via Step 0's resume branch over abandoning.
- After the Step 1 confirmation — and the optional breakdown checkpoint in Step 3, if the brief opted into it — the run never waits on the user: no approval requests, no clarifying questions, no AskUserQuestion. Ambiguity resolves against the spec and the doubt rule; what cannot be resolved that way becomes a `blocked` item in the final report.
- Keep the user informed at phase transitions with one or two one-way status lines relayed from the workflow's progress: items started, items merged, amendments made, anything blocked. Inform, never ask.
