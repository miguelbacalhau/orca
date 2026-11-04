# Orca: objective — the worktree result and the hand-off

This file is read by `/orca:new` and `/orca:open` when their `orca:worktree` `open` spawn returns, and again when the user says go. The causes and timing that differ between them stay in each skill.

## The worktree result

It returns one object: `{status, reviewer, codex, codex_fix, worktree, branch, arrival, setup, base, cause, log}`. Hold `reviewer`, `worktree`, and `branch` for the rest of the session — planning and the loop need them. Report it when it lands, in a line or two, whatever the discussion is doing — never as a reason to pause it:

- `status: ok` with `setup` `current` or `ok` → one line: the worktree is ready.
- `setup: absent` → one line: the repo has no `.orca/setup`, so the worktree has no dependencies installed; offer `/orca:doctor`, which derives one.
- `setup: drifted` → one line: `.orca/setup` changed since it was last approved; offer `/orca:doctor`.
- `status: setup_failed` / `setup_timeout` (`setup` `failed` / `timeout`) → one line with `cause`, the `log` path, and an offer of `/orca:doctor` while the user is here. The worktree exists; provisioning is advisory.
- `codex: fail` → relay `codex_fix` (`/orca:doctor` walks every remediation). `reviewer: fail` → the config or the reviewer check failed: one line pointing at `/orca:config`. The reviewer is first needed at plan review, so neither blocks the discussion; planning and the loop say what they need. Never switch reviewers on the user's behalf.
- `status: failed` → the worktree is not set up; the skill names the causes that stop it first. Otherwise relay `cause` in one line. The discussion still runs — it needs only the objective's files — but planning and the loop need the worktree: before either runs, spawn `orca:worktree` in `open` mode once more (it continues where it stopped); a second failure goes to the user.

## The hand-off

When the user says go, plan it. First confirm no decision is open, from the files rather than memory: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective list "$PWD"` and this objective's `OBJECTIVE:` line (the one whose dir is `<dir>`) reading `open:0`. An open one goes back to the discussion: settle it, or mark it `deferred` when the user wants to leave it out of this pass. The worktree result, or its retry, must have landed with a worktree (`status` other than `failed`). Then read `${CLAUDE_PLUGIN_ROOT}/skills/new/planning.md` and follow it — the planner, the plan review, and the one confirmation. On its confirmation, read `${CLAUDE_PLUGIN_ROOT}/skills/new/loop.md` and follow it to run the phases. A decision that blocked a phase is settled this way too: the pending and blocked phases are replanned and confirmed before the loop runs again.
