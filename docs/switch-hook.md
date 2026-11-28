# The switch hook

An objective driven from a session started in a worktree — your default worktree, `<repo-root>/main` — moves that session into the objective's own `orca-<slug>` worktree with Claude Code's `EnterWorktree` tool (see [Where the session stands](objectives.md#where-the-session-stands)). Claude Code asks before each such move, and an allow rule does not pre-approve it. orca ships a function hook, `hooks/switch.ts`, that answers that one ask.

**In short: the session is not asked before it enters the worktree of the objective it has claimed. Every other move is still yours to answer.**

## What it approves

One call, `EnterWorktree` with a `path`, when all of these hold:

- it comes from the main session, not from a subagent;
- the path is absolute, has no `.` or `..` segment, and its last segment starts `orca-`;
- the session stands under the directory that holds that path — the repository root — but not at the root itself, and not under its `.orca/` or `.bare/`. A session started at the root never moves: every worktree is inside it already, and a root session that moved would lose `.orca/`;
- an objective under `<repo-root>/.orca/objectives/` is claimed by this session (its `owner` file names the session id), is neither archived nor being archived, and its `objective.md` header names that same path on its `**Worktree:**` line.

The claim is written by `objective open` before the session asks to enter.

## What it leaves alone

Everything else is passed on unanswered, so Claude Code asks you as it would without the hook:

- a worktree no objective of this session names — another session's objective, an archived one, a run's `orca-*` worktree (`/orca:review` entering a run's deliverable to address comments asks you once), your own worktrees;
- any other tool, and `EnterWorktree` without a path;
- a subagent's call.

The hook never denies. `ExitWorktree` raises no permission request and needs no answer. In `bypassPermissions` nothing is asked, so the hook is not consulted.

## Failures and limits

- **Fails open to the ask.** A file it cannot read, or a hook that errors, passes the request on: you are asked.
- **A session without orca's hooks module** is asked at each enter.
- **Another plugin's permission hook** may answer first, or deny; the order among plugins is not orca's.

Tests: `tests/switch.test.ts` (`claude plugin test .`) for the hook, `tests/work-loop.bats` for the tool names the skills spell.
