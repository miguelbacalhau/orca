# Orca: objective — the open, the reviewer check, provisioning, and the hand-off

This file is read by `/orca:new` and `/orca:open` when they open the objective, and again when the user says go; planning and the phase loop come back to its reviewer check. The causes and timing that differ between the skills stay in each skill.

## The open

The session runs it itself — it is fast and quiet, and nothing is provisioned in it:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective open <dir>
```

(plus `--steal` when the skill says so). It claims the objective for this session and arrives in its worktree — created off the base commit the first time, re-added when it is gone. Ignore its typed lines; from its frame hold `worktree`, `branch`, and `arrival` for the rest of the session — planning and the loop need the first two, and `orca:provision` needs the first and last. Then run the reviewer check (below) at once.

A typed `FAIL:` → the skill names the causes that stop it first. Any other (`WORKTREE_FAILED`, `WORKTREE_MISMATCH`, `BRANCH_FOREIGN`, `CLAIM_BUSY`, …) means the worktree is not there: relay the reason and detail in one line. The claim stands. The discussion still runs — it needs only the objective's files — but planning and the loop need the worktree: before either runs, run `objective open <dir>` once more (it continues where it stopped) and the reviewer check on its frame; a second failure goes to the user.

## The reviewer check

One Bash call, in the worktree — it takes seconds and prints a few lines:

```bash
cd "<worktree>" && { bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config validate; bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh preflight | grep -E '^(REVIEWER|CODEX):'; }
```

The preflight's exit status is not yours to act on: the bare layout was checked when the objective was created. Derive and hold three values for the rest of the session — planning and the loop need them:

- **`reviewer`** — `config validate`'s `reviewer` when its `VALID:` JSON carries one, else the `REVIEWER:` value (`codex` or `claude`, before the parenthesis). A typed `FAIL:` from `config validate`, or `REVIEWER: FAIL`, makes it `fail`.
- **`codex`** — `CODEX: PASS` → `ok`, `CODEX: SKIPPED` → `skipped`, `CODEX: FAIL: <remediation>` → `fail`.
- **`codex_fix`** — that remediation text when `codex` is `fail`, else empty.

Report it in a line only when something is wrong, never as a reason to pause the discussion: `codex: fail` → relay `codex_fix` (`/orca:doctor` walks every remediation); `reviewer: fail` → the config or the reviewer check failed: one line pointing at `/orca:config`. The reviewer is first needed at plan review; planning and the loop say what they need. Never switch reviewers on the user's behalf.

**Re-checking** — after the user ran `/orca:doctor` or `/orca:config`, or when you no longer hold the values (a compaction, say) — is this same call again, on the held `worktree`; when you no longer hold that either, run `objective open <dir>` first (it keeps this session's claim and frames the worktree). It never re-spawns `orca:provision`.

## Provisioning

When the skill calls for it, spawn **`orca:provision`** in the background (Agent tool) on the open's frame. Its task message:

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

When the user says go, plan it. First confirm no decision is open, from the files rather than memory: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective list "$PWD"` and this objective's `OBJECTIVE:` line (the one whose dir is `<dir>`) reading `open:0`. An open one goes back to the discussion: settle it, or mark it `deferred` when the user wants to leave it out of this pass. The open, or its retry, must have returned a worktree, and the reviewer check must have run on it. Then read `${CLAUDE_PLUGIN_ROOT}/skills/new/planning.md` and follow it — the planner, the plan review, and the one confirmation. On its confirmation, read `${CLAUDE_PLUGIN_ROOT}/skills/new/loop.md` and follow it to run the phases. A decision that blocked a phase is settled this way too: the pending and blocked phases are replanned and confirmed before the loop runs again.
