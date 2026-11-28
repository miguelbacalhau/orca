# The pin hook

A stage agent's shell starts in the directory the session was started in. When that is your default worktree (`<repo-root>/main`), a relative `git commit` or file path from a stage agent would land in your checkout. orca ships a function hook, `hooks/pin.ts`, that starts each stage agent in the worktree its task message names.

**In short: stage agents work in their own `orca-*` worktree whichever directory the session is in, and may not edit your checkout. It is a guard against accidents, not a security boundary.**

## Which agents

Only orca's own agent types, each read by its own line at the top of its task message:

| Line | Agents |
|---|---|
| `Worktree:` | `implement`, `fix`, `commit`, `review-*` (runs); `objective-implement`, `objective-verify`, `objective-review-*`, `phases`, `phases-review-*`, `provision`, `address` |
| `Integration worktree:` | `merge`, `integrate`, `plan` |
| `Review worktree:` | `spec-review-*` |

The line counts only in the message's leading block of `Label: value` lines, so a label quoted further down — in your idea, a finding, a comment — pins nothing. Every other agent is left alone: `spec`, `research`, `council`, `audit`, `doctor`, `objective-open`, and the verb hook's calls.

The path on the line is checked before it is used: absolute, no `.` or `..` segment, a last segment that starts `orca-`, and a `.orca` directory beside it. A line that fails leaves the agent unpinned; the hook never refuses a spawn.

## What pinning does

- **Agents the session starts** (an objective's implementer, verifier, planner, reviewers, provisioner; the address agent) run with the worktree as their working directory.
- **A run's workflow agents** cannot be given a working directory, so the hook binds each by its agent id:
  - every Bash command starts with `cd '<worktree>' || exit 97` on a line of its own — a worktree that is gone fails the command with exit 97 instead of running it somewhere else. The agent's first shell result carries one note saying where its commands start;
  - Glob and Grep search the worktree when given no path, and resolve a relative path against it.
- **Either kind** is refused an `Edit`, `Write`, or `NotebookEdit` on a file under the repository root that is neither in its own worktree nor in `.orca/`: your default worktree, your other worktrees, other `orca-*` worktrees, `.bare/`, and files at the root itself. Reads are never refused, and nothing outside the repository is. The check is on the path as written, not on where a symbolic link leads: a placed secret in a worktree (`<worktree>/.env`) is a link through `.orca/secrets/` to your default worktree's file when the store entry is linked there, so an agent that edits it edits your file — as it always has with store entries you linked by hand.

A resumed agent keeps the directory of its first spawn.

## Restarted workflow agents

The Workflow host starts an agent again after a stall, a lost reply, or a rate-limit wait, under a new id the hook is never told about. Such an agent has no binding. The hook recognizes one when a pinned type's loop starts under an id no spawn answered, and blocks it: its `Bash`, `Edit`, `Write`, `NotebookEdit`, and `StructuredOutput` calls are refused. A stage with a schema'd result then fails as an agent error on the item's normal error path; a stage that returns text (commit, fix, merge) is caught by the checks after it — `commit-verify` finds no commit, the re-review finds the diff unchanged.

## Scope outside bypass mode

Pinning sets where an agent works. It does not widen what the session may touch. In a session that is not in `bypassPermissions` — objectives — an agent can read and write its worktree only when the repository root is one of the session's `permissions.additionalDirectories`. `/orca:doctor` reports this as `ROOT_IN_SCOPE` and offers the settings write. A session started at the repository root needs nothing: every worktree is inside it.

## Conventions

A pinned agent still starts with the session directory's `CLAUDE.md` in its context, and Claude Code does not load an `orca-*` worktree's `CLAUDE.md` or `.claude/rules/` for a session started elsewhere. The agents that edit code or run the checks read those files from their worktree themselves, and the worktree's win where they differ.

## What it does not cover

- A session without orca's hooks module: agents run as they always did, held by their own instructions and their `git -C <worktree>` calls.
- An agent that `cd`s elsewhere inside one command, or writes through an absolute path in Bash.
- A restarted agent whose type no event names.
- Another plugin that also rewrites an agent's directory or commands; the order among plugins is not orca's.

A commit that lands in your checkout through one of these is not detected: `commit-verify` inspects the item's own worktree, and reports only that the item's work is missing.

## Failures and limits

- **Fails open.** A hook that errors passes the spawn or the tool call on unchanged.
- **Version skew.** The hook is the loaded plugin's; a run's task messages are the launching version's. The three labels do not change between versions.
- **Reloads.** Bindings are kept in the session's hook state, so `/reload-plugins` mid-run keeps them.

Tests: `tests/pin.test.ts` (`claude plugin test .`) for the hook, `tests/work-loop.bats` for the labels and the work loop's side.
