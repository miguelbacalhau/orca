# Orca: objective — the open, the reviewer check, provisioning, and the hand-off

This file is read by `/orca:new` and `/orca:open` when they open the objective, and again when the user says go; planning and the phase loop come back to its reviewer check and to where the session stands. The causes and timing that differ between the skills stay in each skill.

## The open

The open runs in **`orca:objective-open`**, never in this session. It is fast, but `objective new` and `objective open` write git refs, worktree internals, and the objective's files, and Claude Code shows every file a Bash call changed. Spawn it in the background (Agent tool) and wait for its notification. `/orca:new` gives it a `Mode: new` task (that skill gives the message). Every other open, `/orca:open`'s and every re-open below, gives it this one:

```text
Mode: open
Plugin root: ${CLAUDE_PLUGIN_ROOT}
Repository: <the session's working directory>
Objective: <dir>
```

(the plugin root substituted, absolute: nothing in a subagent's shell carries it). `Repository:` is the directory the session stands in when the agent is spawned — the one it was started in, or the objective's worktree once the session has moved there (below). The agent claims the objective for this session, arrives in its worktree (creating it off the base commit the first time, re-adding it when it is gone), and runs the reviewer check from the session's directory. It returns one object. For the rest of the session, hold its `worktree`, `branch`, and `arrival` (planning and the loop need the first two, `orca:provision` the first and last), its `session` (Standing in the worktree, below), and the reviewer values below.

`status: open_failed`: the skill names the causes (`reason`) that stop it first. Any other reason (`WORKTREE_FAILED`, `WORKTREE_MISMATCH`, `BRANCH_FOREIGN`, `CLAIM_BUSY`, …) means the worktree is not there. Relay the reason and detail in one line. The claim stands. The discussion still runs, since it needs only the objective's files. Planning and the loop need the worktree, though: before either runs, re-open (it continues where it stopped). A second failure goes to the user.

## Standing in the worktree

A session started in a worktree — the default worktree, usually — drives its objective from inside the objective's own worktree. It moves there with Claude Code's `EnterWorktree` tool and back with `ExitWorktree`. Both are deferred tools: load them with one `ToolSearch` (`select:EnterWorktree,ExitWorktree`) the first time either is needed.

**When.** After every open that returns `status: ok`, before anything else is spawned. And again at the start of planning, at the start of each phase, and before the final verification, whenever the session's directory is no longer `<worktree>` — a `/orca:doctor` in between, a manual exit. The session's directory is the primary working directory its environment names (it is updated on every move), or `pwd`.

**By the open's `session` value:**

- `root` (or `conventional`) → **never move**, and say nothing: every worktree is inside the session already, and a root session that moved would lose `.orca/`.
- `worktree`, and the session already stands in `<worktree>` → nothing.
- `worktree`, anywhere else →
  1. when the session stands in another `orca-*` worktree: `ExitWorktree({action: "keep"})`. An answer of `No-op: there is no active EnterWorktree session` is fine: the session was started in that worktree, and the enter works from it;
  2. `EnterWorktree({path: "<worktree>"})`, the path exactly as the open returned it.

  Then one line to the user: the session now works in `<worktree>`, and the checkout it was started in is closed to it until it leaves.

A re-open from inside the worktree reads `session: worktree` again; the session already stands in `<worktree>`, so nothing moves.

**When the move fails or is declined, the flow stops.** Relay the tool's text in one line and say why it matters: outside `bypassPermissions` the objective's agents can touch its worktree only from a session standing in it. The objective exists and is claimed; `/orca:open <slug>` continues it. Go on without the move only on the user's explicit word, naming what that needs: `bypassPermissions`, or the repository root in the session's `permissions.additionalDirectories`.

**While the session stands there** it stays until an archive, `/orca:doctor`, a run, or another objective takes it out — never at the end of a pass. The checkout it was started in is closed to it meanwhile: Claude Code refuses writes there, and shell commands that point git at it (`git -C <that checkout>`, `cd <that checkout> && git …`, `git --git-dir=<repo-root>/.bare`). `orca.sh` verbs are unaffected.

**Leaving before another objective.** `/orca:new`, and `/orca:open` of an objective this session does not already own (its `owner:` is not `mine`), start with `ExitWorktree({action: "keep"})` when the session stands in an `orca-*` worktree — before `orca:objective-open` is spawned, so the open and its reviewer check run from the directory the session was started in. A `No-op` answer is fine.

## The reviewer check

It comes back in the open's object, so there is no call of your own to make. Hold three values for the rest of the session, because planning and the loop need them:

- **`reviewer`**: `codex`, `claude`, or `fail` (the config or the reviewer check failed).
- **`codex`**: `ok`, `skipped`, or `fail`.
- **`codex_fix`**: the remediation when `codex` is `fail`, else empty.

The object carries one more value from the same check, held with them: **`orca_in_scope`** — `yes`, `no`, `n/a`, or `-` — whether `<repo-root>/.orca/`, where the objective's own files live, is inside what this session may touch. `no` means the session was started in a worktree whose settings do not list `<repo-root>/.orca` (or a directory above it) in `permissions.additionalDirectories`. Say it in one line when the object lands, and again before the first phase starts: outside `bypassPermissions` the session and its agents will be asked for every write under `.orca/` — decisions, rounds, reviews; `/orca:doctor` writes the setting, and a fresh session picks it up. Never write the setting yourself, and never stop over it — a session in bypass mode works without it. `n/a` and `-` (asked from inside the objective's worktree, where it cannot be known) say nothing.

Mention them in a line only when something is wrong, and never pause the discussion over them. `codex: fail` → relay `codex_fix` (`/orca:doctor` walks every remediation). `reviewer: fail` → one line pointing at `/orca:config`. The reviewer is first needed at plan review, and planning and the loop say what they need. Never switch reviewers on the user's behalf.

**Re-checking** is a re-open: spawn `orca:objective-open` with the `Mode: open` task again. Do it after the user ran `/orca:doctor` or `/orca:config`, or when you no longer hold the values or the worktree (a compaction, say). It keeps this session's claim, returns the worktree, and checks the reviewer again. It runs from wherever the session stands: no leave is needed first, since the check answers for the session from inside the objective's worktree too. It never re-spawns `orca:provision`.

## Provisioning

When the skill calls for it, spawn **`orca:provision`** in the background (Agent tool) on the open's `worktree` and `arrival`. Its task message:

```text
Worktree: <worktree>
Arrival: <arrival>
Plugin root: ${CLAUDE_PLUGIN_ROOT}
```

(the plugin root substituted, absolute; nothing in a subagent's shell carries it). It places the secrets and runs `.orca/setup`; the setup output never passes through this session. At the open it is a warm-up, so a cold install overlaps the discussion or planning instead of holding up the first phase — the phase loop provisions again at every phase start, since phases change dependencies. **One provisioning at a time in a worktree:** while a spawn is in flight, nothing spawns another — the phase loop waits for its result first.

## The provision result

It returns one object: `{status, setup, cause, log}`. Report it when it lands, in a line or two, whatever the discussion is doing — never as a reason to pause it:

- `status: ok` with `setup` `current` or `ok` → one line: the worktree is ready.
- `setup: absent` → one line: the repo has no `.orca/setup`, so the worktree has no dependencies installed; offer `/orca:doctor`, which derives one.
- `setup: drifted` → one line: `.orca/setup` changed since it was last approved; offer `/orca:doctor`.
- `status: setup_failed` / `setup_timeout` / `failed` → one line with `cause`, the `log` path when there is one, and an offer of `/orca:doctor` while the user is here. The worktree exists; provisioning is advisory.

## The hand-off

When the user says go, plan it, starting in that same turn. Give no recap, and ask no second question: the plan's confirmation is the only one before the loop. First confirm no decision is open, from the files rather than memory: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective list "$PWD"` and this objective's `OBJECTIVE:` line (the one whose dir is `<dir>`) reading `open:0`. An open one goes back to the discussion: settle it, or mark it `deferred` when the user wants to leave it out of this pass. The go then stands, so planning starts once it is settled. The open, or a re-open, must have returned a worktree with its reviewer check; re-open without asking when it has not. The session stands where Standing in the worktree says before the planner is spawned. A warm-up `orca:provision` still in flight does not hold the planner up. Then read `${CLAUDE_PLUGIN_ROOT}/skills/new/planning.md` and follow it — the planner, the plan review, and the one confirmation. On its confirmation, read `${CLAUDE_PLUGIN_ROOT}/skills/new/loop.md` and follow it to run the phases. A decision that blocked a phase is settled this way too: the pending and blocked phases are replanned and confirmed before the loop runs again.
