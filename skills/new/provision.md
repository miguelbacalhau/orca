# Orca: objective — the open, the reviewer check, provisioning, and the hand-off

This file is read by `/orca:new` and `/orca:open` when they open the objective, and again when the user says go; planning and the phase loop come back to its reviewer check. The causes and timing that differ between the skills stay in each skill.

## The open

The open runs in **`orca:objective-open`**, never in this session. It is fast, but `objective new` and `objective open` write git refs, worktree internals, and the objective's files, and Claude Code shows every file a Bash call changed. Spawn it in the background (Agent tool) and wait for its notification. `/orca:new` gives it a `Mode: new` task (that skill gives the message). Every other open, `/orca:open`'s and every re-open below, gives it this one:

```text
Mode: open
Plugin root: ${CLAUDE_PLUGIN_ROOT}
Repository: <the session's working directory>
Objective: <dir>
Steal: no
```

(the plugin root substituted, absolute: nothing in a subagent's shell carries it; `Steal: yes` only when the skill says so). The agent claims the objective for this session, arrives in its worktree (creating it off the base commit the first time, re-adding it when it is gone), and runs the reviewer check there. It returns one object. For the rest of the session, hold its `worktree`, `branch`, and `arrival` (planning and the loop need the first two, `orca:provision` the first and last) and the reviewer values below.

`status: open_failed`: the skill names the causes (`reason`) that stop it first. Any other reason (`WORKTREE_FAILED`, `WORKTREE_MISMATCH`, `BRANCH_FOREIGN`, `CLAIM_BUSY`, …) means the worktree is not there. Relay the reason and detail in one line. The claim stands. The discussion still runs, since it needs only the objective's files. Planning and the loop need the worktree, though: before either runs, re-open (it continues where it stopped). A second failure goes to the user.

## The reviewer check

It comes back in the open's object, so there is no call of your own to make. Hold three values for the rest of the session, because planning and the loop need them:

- **`reviewer`**: `codex`, `claude`, or `fail` (the config or the reviewer check failed).
- **`codex`**: `ok`, `skipped`, or `fail`.
- **`codex_fix`**: the remediation when `codex` is `fail`, else empty.

Mention them in a line only when something is wrong, and never pause the discussion over them. `codex: fail` → relay `codex_fix` (`/orca:doctor` walks every remediation). `reviewer: fail` → one line pointing at `/orca:config`. The reviewer is first needed at plan review, and planning and the loop say what they need. Never switch reviewers on the user's behalf.

**Re-checking** is a re-open: spawn `orca:objective-open` with the `Mode: open` task again. Do it after the user ran `/orca:doctor` or `/orca:config`, or when you no longer hold the values or the worktree (a compaction, say). It keeps this session's claim, returns the worktree, and checks the reviewer again. It never re-spawns `orca:provision`.

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

When the user says go, plan it. First confirm no decision is open, from the files rather than memory: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective list "$PWD"` and this objective's `OBJECTIVE:` line (the one whose dir is `<dir>`) reading `open:0`. An open one goes back to the discussion: settle it, or mark it `deferred` when the user wants to leave it out of this pass. The open, or a re-open, must have returned a worktree with its reviewer check. Then read `${CLAUDE_PLUGIN_ROOT}/skills/new/planning.md` and follow it — the planner, the plan review, and the one confirmation. On its confirmation, read `${CLAUDE_PLUGIN_ROOT}/skills/new/loop.md` and follow it to run the phases. A decision that blocked a phase is settled this way too: the pending and blocked phases are replanned and confirmed before the loop runs again.
