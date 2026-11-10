---
description: Start an orca objective — a long-lived, iterable unit of work under `.orca/objectives/` — from an idea. Creates the objective's files with the idea and its `feature/<slug>` branch at once (a provisional `objective-<h4>` slug when the idea is too vague to name), claims it and arrives in its worktree (`<repo-root>/orca-<slug>`), checks the config and the reviewer, then provisions the worktree (secrets, `.orca/setup`) in a background `orca:provision` agent — none of the setup output in the session's context — while a background `orca:research` agent researches the touched code at the objective's base — the current checkout when it is clean at that base, else the new worktree. Once research returns, it discusses the idea with the user — informed reflection, scope pushback, the shapes the idea could take — writing the outcome, non-goals, and constraints into `objective.md` and every settled question into `decisions.md` as it goes, unsettled ones as open decisions. When no decision is open and the user says go, it plans the work into reviewed sequential phases and runs them; a user who stops first leaves the objective discussing, and `/orca:open` picks it up. Requires the bare-repo-with-worktrees layout; needs no bypass mode.
args: <idea>
user-invocable: true
disable-model-invocation: true
---

# Orca: new

An objective is work that expects to be iterated on: discussed into decisions, planned into phases, built phase by phase, then re-opened for more. Every piece of it is a file under `<repo-root>/.orca/objectives/<YYYYMMDD-HHMMSS>-<slug>/`, so any session can pick it up later with `/orca:open`. This skill starts one: it creates the objective and opens its workspace, provisions it and researches the idea in parallel, then opens the discussion.

You — this session — keep only what needs the conversation: the discussion, writing the objective's and decisions' entries, asking the user, the fast objective verbs and the reviewer check, and sequencing agents. Everything slow or noisy runs in an agent that returns a compact result: provisioning in `orca:provision`, research in `orca:research`. Every spawn runs in the background: wait for its notification, and never fabricate a result. Shell calls go through `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh` with your own Bash tool — the work loop's verb hook plays no part, so this skill needs no bypass mode.

## Input

The idea is the `<idea>` argument. Without one, ask what the user wants to build — the one question that may come before Step 1, since there is nothing to create without an idea.

## Step 1: Create the objective, first

Nothing comes before this: no question, no research.

**The slug** comes from the idea: short lowercase kebab-case, 3–5 words, at most 60 characters. When the idea is too vague to name, never ask for a name — take a provisional `objective-<h4>`, where `<h4>` is `printf '%04x' "$RANDOM"`. The slug names the worktree and the branch for the objective's whole life, so a provisional one simply stays.

**The base** is the branch the user named as the starting point, else the trunk — the bare repository's default branch. Look around and create the objective in one Bash call from the session's working directory, writing the idea through a quoted heredoc so not one character of it is expanded or changed (set `base` to the named branch instead of the `symbolic-ref` when the user gave one):

```bash
common="$(git rev-parse --path-format=absolute --git-common-dir)" && root="$(dirname "$common")" \
  && echo "decisions=$([ -f "$root/.orca/decisions.md" ] && echo yes || echo no)" \
  && { top="$(git rev-parse --show-toplevel 2>/dev/null)" && echo "top=$top" \
       && echo "head=$(git -C "$top" rev-parse HEAD)" \
       && echo "dirty=$(git -C "$top" status --porcelain --untracked-files=all | head -1)"; true; }
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config show | grep -E '^(OVERRIDE:.research.|FAIL:)'
base="$(git --git-dir="$common" symbolic-ref --short HEAD)"; echo "base=$base"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective new "$PWD" <slug> "$base" --idea - <<'ORCA_IDEA_EOF'
<the idea, exactly as given>
ORCA_IDEA_EOF
```

Pick another delimiter if a line of the idea is `ORCA_IDEA_EOF`.

- `OVERRIDE:` lines (stage `research`) are the research tuning. A `FAIL:` from `config show` means the config is mangled — research takes its defaults; mention once that `/orca:config` repairs it.
- `decisions=yes` means the decision log exists — never read it here.

`objective new` prints one frame: `dir`, `worktree`, `branch`, and `base` — the base commit, where `new` has just created the branch. Hold `dir` as `<dir>`, and `base`. Its files hold the idea under `## Idea`. A typed `FAIL:` from `new` writes nothing; re-run only the `objective new` call, with the printed `base` (or the branch the user now names) and the same idea:

- `NOT_BARE` → objectives need the bare-with-worktrees layout: point at `/orca:init`, and stop.
- `BRANCH_EXISTS` / `WORKTREE_EXISTS` → the slug is taken by a run or a leftover: append `-<h4>` to the slug and run `new` once more, then say which slug the objective got. A second failure goes to the user.
- `OBJECTIVE_EXISTS` → an objective with this slug exists already, likely this same idea: ask whether to continue it (`/orca:open <slug>`) or start a new one under a `-<h4>`-suffixed slug.
- `BAD_SLUG` → fix the slug to the rule above and run `new` again.
- `BAD_REF`, or a trunk that does not resolve (a bare repository with a detached or unset `HEAD`) → ask the user which branch the objective builds on, then run `new` with it.
- `NOT_GIT` / `OLD_GIT` / anything else → relay the detail and stop.

**Where research explores** — the code the objective starts from, never anything else. `top` printed, its `head` equal to the frame's `base`, and `dirty` empty → research explores `top`. Otherwise — another branch or commit, local changes, or the bare repository root with no checkout — it explores the objective's `worktree`, which the open below creates at the base; without one, the discussion runs intent-only.

## Step 2: Open, provision, and research

Read `${CLAUDE_PLUGIN_ROOT}/skills/new/provision.md` and run its open — `objective open <dir>` — with your own Bash tool. The objective is brand new, so of its stopping causes only one can come: `NO_SESSION_ID` → this session has no id to claim with: relay it — the objective exists, and `/orca:open <slug>` from another session picks it up — and stop. Any other `FAIL:` follows that file's rule. On its frame, run that file's reviewer check.

Then spawn both in the background — **in one message**:

- **`orca:provision`**, as that file's Provisioning says, on the open's frame — the warm-up, so a cold install overlaps the discussion. Skip it when the open failed.
- **Research** — one `orca:research` agent through its bundled one-agent workflow: the Workflow tool with `scriptPath: "${CLAUDE_PLUGIN_ROOT}/scripts/research.workflow.js"` (the substituted, absolute value) and `args: { prompt, model?, effort? }` — `model`/`effort` from the `research` OVERRIDE lines, each only when set. The `prompt`: the repository to explore — the checkout chosen above, holding exactly the code at the base — the idea verbatim, and, when the decision log exists, a `Project context:` line naming `<root>/.orca/decisions.md` (generated from trunk commit history). It returns `{ report, died }`; the runId is throwaway — never persist or resume it. Research that would explore the worktree is skipped when the open failed.

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

- `objective new` is the first thing this skill does with an idea in hand — the objective exists before anything is asked or researched.
- The research report is disposable: never persisted, never pasted to the user, never written into the objective's files. Whatever matters from it lands through the conversation.
- You never edit code and never touch the worktree. The objective's files under `<dir>` are the only ones this skill writes, and only through the verbs and the discussion.
- Never read `.orca/config`, `.orca/setup`, or a setup log into the conversation; the provision agent reports them, and `/orca:doctor` owns fixing them.
