---
description: Retire finished orca runs whose work has provably landed, so triage stops carrying a repository's whole history. Scans every finished run against one deterministic gate — report present, nothing blocked, no live lease, and every feature/<slug> branch the run produced merged into the trunk (or already pruned) — then presents the archivable set with its evidence and, on your consent, marks each one archived. An archived run leaves the routing surface only: its directory, report, and branches are untouched, /orca:followup still picks it for deferred follow-ups, and /orca:archive --undo reverses the marker. Never deletes anything, never touches git, and refuses any run it cannot prove has landed. Not a cleanup skill — pruning merged branches and leftover worktrees stays /orca:status's prescription and your own hand.
args: <optional run directory or slug fragment, or --undo <run>>
user-invocable: true
disable-model-invocation: true
---

# Orca: archive

Orca never removes a finished run. That is the right default — a run's spec, plans, reviews, and report are the durable record of a decision, and `/orca:retry`, `/orca:followup`, and `/orca:iterate` all read them long after the branch has landed. But nothing retires them either, so every entry-point skill's Step 0 triage carries the full history of the repository forever: after a dozen features the finished runs dominate a snapshot that exists to show what is *waiting*.

This skill closes that loop. It is the counterpart to `/orca:status`: status renders the picture and prescribes, this skill performs the one retirement mutation — writing an `archived` marker beside a finished run's `report.md`. Everything else about the run stays exactly where it was.

**What archiving is not.** It deletes nothing: no run directory, no report, no branch, no worktree, no commit. It touches git not at all — merged branches and leftover worktrees remain `/orca:status`'s "safe to delete" prescription, run by the user's own hand, and archiving a run neither prunes them nor hides them (the status join still reports them). It is one marker file, and removing that file restores the run to the routing surface exactly as it was.

## Step 1: Scan

One call, from anywhere in the repository:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh triage archive --scan
```

Read-only, exit 0 always (`FAIL: NOT_GIT` → nothing here to archive; say so and stop). Three line types, all TAB-separated:

- `ARCHIVABLE:<TAB><run-dir><TAB><evidence>` — every gate passed. The evidence is the script's own sentence; render it, never embellish it. When it mentions leftover worktrees, pass that through: worktrees are deliberately *not* a gate (one on a merged branch is exactly the garbage `/orca:status` already prescribes removing, and archiving leaves it visible there), but the user should see that git cleanup remains outstanding.
- `KEPT:<TAB><run-dir><TAB><reason><TAB><detail>` — a gate failed. The reason routes the explanation: `NOT_CLEAN` (the report lists unmet items — `/orca:retry` finishes them, and *that* is the user's real next move, worth naming), `LEASE_LIVE` (an open session owns the run), `NO_TRUNK` (detached or unset HEAD, so merged-ness is unknowable), `NOT_LANDED` (the detail names each unmerged branch and its state — the common case, and the one to state plainly: the work is delivered but not yet landed, so `/orca:review` and the user's own merge come first).
- `ARCHIVED:<TAB><run-dir>` — already archived. Count them; do not itemize.

**The gate is the script's, not yours.** Never archive a run the scan did not mark `ARCHIVABLE:`, never argue a `KEPT:` verdict into a pass, and never re-derive merged-ness conversationally — the same anchored slug join and the same merge-base test that `/orca:status` renders are what the gate runs, so the two can never disagree. An unmerged branch means unlanded work, full stop.

An argument narrows what you *present*, never what you scan: match it against the run directories by name or slug fragment, and on no match say so loudly with the list of what exists rather than guessing.

## Step 2: Present, then ask

Open with the count and the consequence in one breath — how many runs are archivable, and what archiving does and does not do (the "what archiving is not" paragraph above, compressed to a sentence). Then list the archivable runs: directory name, what the run was (its slug is usually enough — do **not** open reports to narrate them; that is the report's job and status's non-goal for the same reason), and the one-line evidence.

List the `KEPT:` runs after, grouped by reason, each with the move that would unblock it. This is the more useful half of the output for a user who expected everything to retire: a run kept because its branch is unmerged is telling them they have a deliverable waiting to land.

Then ask once, plainly: archive all of them, a subset they name, or nothing. Consent is to a stated set. If the user names a subset, read back exactly which directories you are about to mark before doing it.

## Step 3: Archive

One call per consented run:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh triage archive <run-dir>
```

The verb re-runs the full gate at write time — the scan may be minutes old, and a branch can land or a session can claim a lease in between — so a typed failure here (`NOT_CLEAN`, `LEASE_LIVE`, `NO_TRUNK`, `NOT_LANDED`, `NO_REPORT`, `NO_RUN_DIR`) is the gate refusing, not an error to work around. Report it and move on to the next run; never edit or create the marker file by hand to get past a refusal. Re-archiving an already-archived run is a no-op that succeeds.

Close by stating what changed and what did not: N runs retired from triage, their directories and reports untouched, `/orca:followup` still able to pick them, and any merged branches or worktrees still listed by `/orca:status` under "safe to delete" — archiving is not cleanup, and pretending otherwise would leave the user believing git state was tidied when it was not.

## Undo

`--undo <run>` (or a user asking to restore one) removes the marker:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh triage unarchive <run-dir>
```

Idempotent, ungated, and instant — an archived run has no state to restore beyond the marker's absence. Confirm the run is back on the routing surface, and mention that `/orca:status` will show it in whatever group its facts put it in.

## Non-goals

- **No deletion, ever.** Not run directories, not reports, not branches, not worktrees — not even when the user asks mid-conversation. Deleting a landed run's branch is `/orca:status`'s prescription and the user's own `git branch -D`; deleting a run directory is theirs alone and this skill never suggests it. The marker is the only write.
- **No git.** This skill runs no git command that changes anything, and no `git merge`, `git branch -D`, or `git worktree remove` at all. It reads merged-ness only through the triage verb.
- **No archiving of unfinished, blocked, or unlanded runs.** The gate exists precisely to make "landed" provable rather than judged; a user's assurance that something landed is not evidence, and the answer to a `KEPT:` verdict is the move that clears it.
- **No run-content narration.** Same reason as status: the report is the narrator, and a second one invites drift.
- **No launching.** It hands off by naming skills; each one re-derives its own state.
