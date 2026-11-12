---
description: Start an orca objective — a long-lived, iterable unit of work under `.orca/objectives/` — from an idea. Creates the objective's files with the idea and its `feature/<slug>` branch at once (a provisional `objective-<h4>` slug when the idea is too vague to name), claims it and arrives in its worktree (`<repo-root>/orca-<slug>`), checks the config and the reviewer — all of it in a background `orca:objective-open` agent, so none of those verbs' output enters the session — then provisions the worktree (secrets, `.orca/setup`) in a background `orca:provision` agent, none of the setup output in the session's context either, while a background `orca:research` agent researches the touched code at the objective's base — the current checkout when it is clean at that base, else the new worktree. Once research returns, it discusses the idea with the user — informed reflection, scope pushback, the shapes the idea could take — writing the outcome, non-goals, and constraints into `objective.md` and every settled question into `decisions.md` as it goes, unsettled ones as open decisions. When no decision is open and the user says go, it plans the work into reviewed sequential phases, runs them, and verifies the finished branch as a whole — a regression becoming one more phase; a user who stops first leaves the objective discussing, and `/orca:open` picks it up. Requires the bare-repo-with-worktrees layout; needs no bypass mode.
args: <idea>
user-invocable: true
disable-model-invocation: true
---

# Orca: new

An objective is work that expects to be iterated on: discussed into decisions, planned into phases, built phase by phase, then re-opened for more. Every piece of it is a file under `<repo-root>/.orca/objectives/<YYYYMMDD-HHMMSS>-<slug>/`, so any session can pick it up later with `/orca:open`. This skill starts one: it creates the objective and opens its workspace, provisions it and researches the idea in parallel, then opens the discussion.

You (this session) keep only what needs the conversation: the discussion, writing the objective's and decisions' entries, asking the user, and sequencing agents. Everything slow or noisy runs in an agent that returns a compact result: creating and opening the objective and the reviewer check in `orca:objective-open`, provisioning in `orca:provision`, research in `orca:research`. Every spawn runs in the background: wait for its notification, and never fabricate a result. Your own shell calls go through `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh` with your own Bash tool. The work loop's verb hook plays no part, so this skill needs no bypass mode.

## Input

The idea is the `<idea>` argument. Without one, ask what the user wants to build — the one question that may come before Step 1, since there is nothing to create without an idea.

## Step 1: Create the objective, first

Nothing comes before this: no question, no research. The one exception is reading the idea itself.

**A reference is not an idea.** When the idea is, or leans on, a pointer to a tracked issue — a Linear or Jira key like `ENG-1234`, a GitHub `#123`, an issue URL — resolve it before naming anything: one lookup through whatever this session has for that tracker (a Linear or Jira MCP tool, `gh issue view`), for the issue's title and description. That lookup is reading the idea, not researching it, so it stays a single call. When nothing can resolve it, use what the reference itself carries: a Linear URL ends in the issue's title slug (`…/issue/ENG-1234/fix-login-redirect-loop`). Never name the objective after the identifier alone.

**The slug** comes from what the idea asks for — for a reference, the issue's title, not its key: short lowercase kebab-case, 3–5 words, at most 60 characters, naming the change (`ENG-1234` titled "Login redirects loop after SSO timeout" → `fix-sso-login-redirect-loop`). If the idea is too vague to name, or a reference resolved to nothing, don't ask for a name. Use a provisional `objective-<h4>`, where `<h4>` is four random hex digits. The slug names the worktree and the branch for the objective's whole life, so a provisional one simply stays.

**The base** is the branch the user named as the starting point, else the trunk (the bare repository's default branch).

Read `${CLAUDE_PLUGIN_ROOT}/skills/new/provision.md`. Creating the objective is its open, run with a `Mode: new` task. Spawn **`orca:objective-open`** in the background with this task message:

```text
Mode: new
Plugin root: ${CLAUDE_PLUGIN_ROOT}
Repository: <the session's working directory>
Slug: <slug>
Base: <the branch the user named, or empty>
Idea:
<<<ORCA_IDEA
<the idea, exactly as given; for a resolved reference, followed by the issue's title and description>
ORCA_IDEA>>>
```

(the plugin root substituted, absolute). The agent looks around, creates the objective (its files, with the idea verbatim under `## Idea`, and `feature/<slug>` at the base commit), opens it, and runs the reviewer check. None of those verbs' output or the files they write enter this session. Wait for its one object. Hold `dir` as `<dir>`, `slug`, and `base`, plus what that file's open says to hold. When `slug` differs from yours, a taken branch or worktree got it a `-<h4>` suffix: say which slug the objective got.

- `research_model` / `research_effort` are the research tuning. `config_fail: true` means the config is mangled, so research takes its defaults. Mention once that `/orca:config` repairs it.
- `decisions_log` is the decision log's path when it exists. Never read it here.

**`status: new_failed`**: nothing was written. By `reason`:

- `NOT_BARE` → objectives need the bare-with-worktrees layout. Point at `/orca:init` and stop.
- `OBJECTIVE_EXISTS` → an objective with this slug exists already, likely this same idea. Ask whether to continue it (`/orca:open <slug>`) or start a new one under a `-<h4>`-suffixed slug, then spawn again with that slug.
- `BAD_REF`, or a trunk that does not resolve (a bare repository with a detached or unset `HEAD`) → ask the user which branch the objective builds on, then spawn again with it as `Base:`.
- `BRANCH_EXISTS` / `WORKTREE_EXISTS` / `BAD_SLUG` (the agent's one retry failed too), `NOT_GIT`, `OLD_GIT`, or anything else → relay the detail and stop.

**`status: open_failed`**: the objective exists, but the open failed. The objective is brand new, so of the causes that stop the skill only one can come: `NO_SESSION_ID` → this session has no id to claim with. Relay it (the objective exists, and `/orca:open <slug>` from another session picks it up) and stop. Any other reason follows that file's rule.

**Where research explores** is the agent's `research_root`: the current checkout when it is clean at the base commit, else the objective's worktree. When it is empty (the open failed and there is no clean checkout at the base), research is skipped and the discussion runs intent-only.

## Step 2: Provision and research

With the open's object in hand, spawn both in the background, **in one message**:

- **`orca:provision`**, as that file's Provisioning says, on the object's `worktree` and `arrival`. It is the warm-up, so a cold install overlaps the discussion. Skip it when the open failed.
- **Research**: one `orca:research` agent through its bundled one-agent workflow. Use the Workflow tool with `scriptPath: "${CLAUDE_PLUGIN_ROOT}/scripts/research.workflow.js"` (the substituted, absolute value) and `args: { prompt, model?, effort? }`. Set `model` / `effort` from `research_model` / `research_effort`, each only when set. The `prompt` carries the repository to explore (`research_root`, which holds exactly the code at the base), the idea verbatim, and, when `decisions_log` is set, a `Project context:` line naming it (it is generated from trunk commit history). Research returns `{ report, died }`. The runId is throwaway: never persist or resume it.

### The provision result

Follow that file's provision result when it lands.

### The research result

Wait for it before the discussion opens — its report is what the opening reflection is built from. `died: true` → retry once; a second death, or a repository with nothing to explore, is non-fatal: the discussion runs intent-only.

## Step 3: Discuss

Once research has returned, read `${CLAUDE_PLUGIN_ROOT}/skills/new/discussion.md` and follow it, with the research report in hand. It covers the reflection, the pacing, and how `objective.md` and `decisions.md` are written — entry by entry as the discussion settles them, never as one document at the end.

## Step 4: Hand off

The discussion ends one of two ways:

- **The user says go** — hand off as `${CLAUDE_PLUGIN_ROOT}/skills/new/provision.md` says: confirm no decision is open, then planning, then the loop.
- **The user stops** — nothing to do: the files already say where the discussion is. Tell them the objective stays `discussing` and `/orca:open <slug>` picks it up from any session.

## Guidelines

- Creating the objective (the `orca:objective-open` spawn) is the first thing this skill does with an idea in hand. The objective exists before anything is asked or researched.
- The research report is disposable: never persisted, never pasted to the user, never written into the objective's files. Whatever matters from it lands through the conversation.
- You never edit code and never touch the worktree. The objective's files under `<dir>` are the only ones this skill writes, and only through the discussion (the verbs run in agents).
- Never read `.orca/config`, `.orca/setup`, or a setup log into the conversation; the provision agent reports them, and `/orca:doctor` owns fixing them.
