---
description: Start an orca objective — a long-lived, iterable unit of work under `.orca/objectives/` — from an idea. Creates the objective's files and its `feature/<slug>` branch at once (a provisional `objective-<h4>` slug when the idea is too vague to name), then sets up its worktree (`<repo-root>/orca-<slug>`, secrets, `.orca/setup`, the reviewer check) in a background `orca:worktree` agent and researches the touched code at the objective's base in a background `orca:research` agent — in the same turn when the current checkout is clean at that base, else in the new worktree. Once research returns, it discusses the idea with the user — informed reflection, scope pushback, the shapes the idea could take — writing the outcome, non-goals, and constraints into `objective.md` and every settled question into `decisions.md` as it goes, unsettled ones as open decisions. When no decision is open and the user says go, it plans the work into reviewed sequential phases and runs them; a user who stops first leaves the objective discussing, and `/orca:open` picks it up. Requires the bare-repo-with-worktrees layout; needs no bypass mode.
args: <idea>
user-invocable: true
disable-model-invocation: true
---

# Orca: new

An objective is work that expects to be iterated on: discussed into decisions, planned into phases, built phase by phase, then re-opened for more. Every piece of it is a file under `<repo-root>/.orca/objectives/<YYYYMMDD-HHMMSS>-<slug>/`, so any session can pick it up later with `/orca:open`. This skill starts one: it creates the objective, sets up its workspace and researches the idea in parallel, and opens the discussion.

You — this session — keep only what needs the conversation: the discussion, writing the objective's and decisions' entries, asking the user, and sequencing agents. Everything slow or noisy runs in an agent that returns a compact result: workspace setup in `orca:worktree`, research in `orca:research`. Every spawn runs in the background: wait for its notification, and never fabricate a result. Shell calls go through `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh` with your own Bash tool — the work loop's verb hook plays no part, so this skill needs no bypass mode.

## Input

The idea is the `<idea>` argument. Without one, ask what the user wants to build — the one question that may come before Step 1, since there is nothing to create without an idea.

## Step 1: Create the objective, first

Nothing comes before this: no question, no research, no pre-flight.

**The slug** comes from the idea: short lowercase kebab-case, 3–5 words, at most 60 characters. When the idea is too vague to name, never ask for a name — take a provisional `objective-<h4>`, where `<h4>` is `printf '%04x' "$RANDOM"`. The slug names the worktree and the branch for the objective's whole life, so a provisional one simply stays.

**The base** is the branch the user named as the starting point, else the trunk — the bare repository's default branch. Resolve it and create the objective in one Bash call, from the session's working directory:

```bash
base="$(git --git-dir="$(git rev-parse --path-format=absolute --git-common-dir)" symbolic-ref --short HEAD)" \
  && bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective new "$PWD" <slug> "$base"
```

(Use the named branch for `$base` instead when the user gave one.) One frame: `dir`, `worktree`, `branch`, and `base` — the base commit, where `new` has just created the branch. Hold all four. A typed `FAIL:` from `new` writes nothing:

- `NOT_BARE` → objectives need the bare-with-worktrees layout: point at `/orca:init`, and stop.
- `BRANCH_EXISTS` / `WORKTREE_EXISTS` → the slug is taken by a run or a leftover; append `-<h4>` to the slug and run `new` once more, then say which slug the objective got.
- `OBJECTIVE_EXISTS` → an objective with this slug exists already, likely this same idea: ask whether to continue it (`/orca:open <slug>`) or start a new one under a `-<h4>`-suffixed slug.
- `BAD_SLUG` → fix the slug to the rule above and run `new` again.
- `BAD_REF`, or a trunk that does not resolve (a bare repository with a detached or unset `HEAD`) → ask the user which branch the objective builds on, then run `new` with it.
- `NOT_GIT` / `OLD_GIT` / anything else → relay the detail and stop.

## Step 2: Set up and research

Read the research tuning first, in one Bash call: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config show`, taking only the `OVERRIDE:` lines whose stage is `research` (a typed `FAIL:` there means the config is mangled — proceed with the agent's defaults and mention once that `/orca:config` repairs it), and check whether `<repo-root>/.orca/decisions.md` exists — check only; never read it here. `<repo-root>` is the parent of `git rev-parse --path-format=absolute --git-common-dir`.

**Where research explores** — the code the objective starts from, never anything else. In the same Bash call, check the current checkout: `git rev-parse --show-toplevel` succeeds, `git rev-parse HEAD` there is the held `base`, and `git status --porcelain --untracked-files=all` there is empty. All three hold → research explores that top level, and starts now. Any fails — another branch or commit, local changes, or the bare repository root with no checkout → research explores the objective's `worktree`, which `orca:worktree` creates at `base`: spawn it once the worktree result lands with a worktree (any `status` but `failed`); without one, the discussion runs intent-only.

Then spawn the agents, both in the background — **in one message** when research starts now:

- **`orca:worktree`, `open` mode** (Agent tool). Its task message: `open <dir>`, and the plugin root — `${CLAUDE_PLUGIN_ROOT}`, substituted; nothing in a subagent's shell carries it. It claims the objective for this session, creates and provisions the worktree, then checks the config and the reviewer.
- **Research** — one `orca:research` agent through its bundled one-agent workflow: the Workflow tool with `scriptPath: "${CLAUDE_PLUGIN_ROOT}/scripts/research.workflow.js"` (the substituted, absolute value) and `args: { prompt, model?, effort? }` — `model`/`effort` from the `research` OVERRIDE lines, each only when set. The `prompt`: the repository to explore — the checkout chosen above, holding exactly the code at `base` — the idea verbatim, and, when the decision log exists, a `Project context:` line naming `<repo-root>/.orca/decisions.md` (generated from trunk commit history). It returns `{ report, died }`; the runId is throwaway — never persist or resume it.

While they run, write the idea verbatim under `## Idea` in `<dir>/objective.md` — the discussion's other sections wait for the discussion.

### The worktree result

Read `${CLAUDE_PLUGIN_ROOT}/skills/new/worktree.md` when it lands, and follow its worktree result. Research that waits on the worktree (above) spawns only now, and only when the result carries one.

### The research result

Wait for it before the discussion opens — its report is what the opening reflection is built from. `died: true` → retry once; a second death, or a repository with nothing to explore, is non-fatal: the discussion runs intent-only.

## Step 3: Discuss

Read `${CLAUDE_PLUGIN_ROOT}/skills/new/discussion.md` and follow it, with the research report in hand. It covers the reflection, the pacing, and how `objective.md` and `decisions.md` are written — entry by entry as the discussion settles them, never as one document at the end.

## Step 4: Hand off

The discussion ends one of two ways:

- **The user says go** — hand off as `${CLAUDE_PLUGIN_ROOT}/skills/new/worktree.md` says: confirm no decision is open, then planning, then the loop.
- **The user stops** — nothing to do: the files already say where the discussion is. Tell them the objective stays `discussing` and `/orca:open <slug>` picks it up from any session.

## Guidelines

- `objective new` is the first thing this skill does with an idea in hand — the objective exists before anything is asked or researched.
- The research report is disposable: never persisted, never pasted to the user, never written into the objective's files. Whatever matters from it lands through the conversation.
- You never edit code and never touch the worktree. The objective's files under `<dir>` are the only ones this skill writes.
- Never read `.orca/config`, `.orca/setup`, or a setup log into the conversation; the worktree agent reports them, and `/orca:doctor` owns fixing them.
