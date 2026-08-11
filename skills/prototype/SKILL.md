---
description: Hack an idea into a running throwaway spike as fast as possible — one worktree, one branch, one agent with an explicitly inverted quality contract (fakes, hardcoding, and shortcuts welcome, each marked `TODO(proto)`), no review, no spec, no integration verification. The deliverable is evidence, not code — a learnings-first report saying whether the idea holds up, what was faked, and what a real implementation would need; the `proto/<slug>` branch is an appendix the user plays with and then discards, with the exact cleanup commands in the report. Fills the gap between "small single-file change, don't use orca" and the full orca:feature pipeline, whose review and verification machinery exists to make a branch landable — overhead when the question is only "does this idea hold up?". Requires the bare-repo-with-worktrees layout and a harness with the Workflow tool. One item, one question at most, then fully autonomous; never resumable, never landed by orca:pr, never seen by orca:retry or orca:followup. Do not use for work meant to land — that is orca:feature.
args: <idea>
user-invocable: true
disable-model-invocation: true
---

# Orca: prototype

Turn an idea into a running hack as fast as possible, in one isolated worktree, and report what building it revealed. The main conversation handles the micro-intent, the pre-flights, the scaffold, and the report; the build is one `orca:prototype` agent spawned through a bundled one-agent workflow. The deliverable is **evidence, not code**: the report leads with the verdict and learnings, and the branch is an appendix.

This verb is deliberately minimal. One item, one worktree, one branch, no review — ever. An idea that needs decomposition is a feature: point the user at `/orca:feature` rather than growing the scope here. `orca:retry` and `orca:followup` never see prototype runs, and orca:pr structurally refuses their reports.

## Step 1: Intent, micro

The `<idea>` argument is the intent. No research agent, no brief queue, no `.orca/feat-briefs/` interplay — a prototype's intent fits in two lines.

- **Missing argument:** ask for the idea in one question.
- **At most one more question**, and only when the idea itself doesn't answer it: *what do you need to see to call the idea validated?* — the success line the report's verdict is written against. When the idea already implies it, derive it and don't ask.

Restate the idea and the success line once. The user's confirmation authorizes the run; from then on the run asks nothing (the feature skill's autonomy rule, minus every optional pause).

## Step 2: Pre-flights

Run the environment pre-flight from the project root:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh preflight
```

Honor only two lines — this verb has no review path, so the review gates do not apply:

- `BARE_REPO: PASS|FAIL` — the one hard gate. On `FAIL`, stop and point the user at orca:init, exactly as the feature skill does.
- `TRUNK_CANDIDATE: <branch>` — the branch the spike branches off; confirm with the user only if it looks wrong.

Ignore `REVIEWER:`, `CODEX:`, and the combined `RESULT:` — they exist for the review path, and an unauthenticated codex must not block a prototype.

**Workflow tool gate:** the harness must expose the Workflow tool. Without it, stop and say this skill requires a Claude Code harness with workflows.

**Permissions pre-flight — verbatim from the feature skill:** the run only stays autonomous in `bypassPermissions` mode; an allow-list is not sufficient, because the agent decides commands at runtime and prefix-matched rules leak prompts. Confirm the session is in bypass mode (Shift+Tab, or `claude --dangerously-skip-permissions`), stating the whole-session trade-off. If the user won't enable it, report that the prototype can't run autonomously and stop — nothing is queued; the idea is two lines, cheap to re-type.

**Config read:** run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config validate` once. On `VALID:`, hold only the `agents.prototype` block (`{model, effort}`) for the launch; every other key is irrelevant here. On a typed `FAIL:`, stop and point the user at orca:config.

## Step 3: Scaffold

Resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir`. Make `<slug>` a short kebab-case description of the idea, 2-4 words.

Create the run directory `.orca/YYYYMMDD-HHMMSS-proto-<slug>/` (timestamp from `date +%Y%m%d-%H%M%S`) holding exactly one file for now — `brief.md`, the micro-brief:

```markdown
# Prototype brief: <idea summary>

**Created:** <YYYY-MM-DD HH:MM>

## Idea

<the idea, verbatim as confirmed>

## Success line

<what validated looks like>
```

`report.md` lands beside it at the end; nothing else, and never a `spec.md`. The `proto-` marker in the directory name is what keeps triage discovery away from this run — it is deliberately invisible to every resume/offer surface.

Create the worktree on a fresh branch off the trunk tip, then place secrets:

```bash
git worktree add <repo-root>/orca-proto-<slug> -b proto/<slug> <trunk>
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets place <repo-root>/orca-proto-<slug>
```

The `proto/` branch namespace (vs `feature/`) is half the "do not land this" stamp — the report's `**Deliverable state:** prototype` line is the other half. If `worktree add -b` fails because `proto/<slug>` already exists, pick a new slug and retry — never reuse an existing branch. The `place` call is idempotent and best-effort: relay any `UNIGNORED:`/`SKIPPED_EXISTS:` lines as one-way status, never stop for them.

## Step 4: Launch

Compose the agent's complete task message from:

- the repository root
- the worktree path `<repo-root>/orca-proto-<slug>` and branch `proto/<slug>`
- the run directory
- the micro-brief verbatim — idea and success line
- a `Project context:` line naming `<repo-root>/.orca/map.md` and `<repo-root>/.orca/decisions.md` as hints — read-only for this verb; a missing file is skipped, not an error

Invoke the Workflow tool with `scriptPath: "${CLAUDE_PLUGIN_ROOT}/scripts/prototype.workflow.js"` — the substituted value is already absolute; never pass `~` or an unsubstituted variable — and `args: { prompt, model?, effort? }`, where `model`/`effort` come from the held `agents.prototype` block, each passed only when set. The workflow runs in the background: wait for its task notification and never fabricate the result. It returns `{ summary, died }`: on `died: true`, relaunch once; if the second launch dies too, report the failure and stop. No lease is taken and no runId is persisted — an interrupted prototype is abandoned or relaunched fresh, by design.

## Step 5: Backstop and report

The agent leaves **one commit** on `proto/<slug>`. Read the message back — never trust the agent's self-report:

```bash
git -C <repo-root>/orca-proto-<slug> log -1 --format=%B
```

On any unambiguous marker — `Claude`, `Anthropic`, `Co-Authored-By`, `Generated with`/`Generated by`, `orca` — rewrite the message with `git commit --amend` in the proto worktree to describe only the change itself.

Then write `<run-dir>/report.md` from the agent's returned summary:

````markdown
# Prototype: <idea summary>

**Run:** <run-dir>
**Branch:** `proto/<slug>` (worktree `<repo-root>/orca-proto-<slug>`)
**Deliverable state:** prototype — unreviewed spike; do not land or cherry-pick without a real run

## Verdict

<Does the idea hold up, judged against the success line. One paragraph.>

## Learnings

- <What building it revealed — the run's actual product.>

## Faked or hardcoded

- <Every `TODO(proto)` shortcut, greppable in the branch.>

## What a real implementation needs

- <The seed material for a future feature interview — pasted by the user, never auto-consumed.>

## Try it / Discard

<How to run the spike in its worktree. Then the exact cleanup:>

```bash
git worktree remove <repo-root>/orca-proto-<slug>   # add --force if the spike left dirt
git branch -D proto/<slug>
```
````

`**Deliverable state:**` is always the constant `prototype` — never `verified` — so orca:pr's guard refuses it structurally.

Speak the report: verdict first, then learnings, the faked list, what a real implementation needs, how to try it, and the cleanup commands. When the learnings warrant a real build, say that pasting the "What a real implementation needs" section into an `/orca:feature` interview is the intended path — nothing consumes the report automatically.

## Guidelines

- Same no-attribution rule as run commits: no commit on `proto/<slug>` may mention Claude, AI, agents, orca, or this process; the Step 5 read-back is the deterministic backstop.
- The main conversation never implements or explores deeply itself — the build lives and dies in the agent.
- State lives in `brief.md` and `report.md`, not conversation memory. There is no resume: a run that dies mid-build is abandoned or relaunched fresh.
- Scope never grows past one item. Decomposition, review tiers, or "promote to feature branch" requests all mean the user wants `/orca:feature` — say so.
- Cleanup is manual and the report is its surface; `orca:status`'s git-footprint lines keep leftover `orca-proto-*` worktrees visible until the user discards them.
