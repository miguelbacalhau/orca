---
description: Retire finished orca runs whose work has provably landed — take them off triage and clear their git footprint. Scans every finished run against one deterministic gate — report present, nothing blocked, no live lease, every feature/<slug> branch the run produced merged into the trunk (or already pruned), and every orca-* worktree it left removable without loss — then presents the archivable set with its evidence and the exact worktrees and branches each would remove, and on your consent removes them and marks each run archived. The run directory and report stay: /orca:followup still picks archived runs for deferred follow-ups, and /orca:archive --undo reverses the marker and recreates the removed branches at their recorded tips. Refuses any run it cannot prove has landed, and any worktree holding uncommitted work.
args: <optional run directory or slug fragment, or --undo <run>>
user-invocable: true
disable-model-invocation: true
---

# Orca: archive

Orca never removes a finished run's record. That is the right default — a run's spec, plans, reviews, and report are the durable record of a decision, and `/orca:retry`, `/orca:followup`, and `/orca:iterate` all read them long after the branch has landed. But nothing retires them either, so every entry-point skill's Step 0 triage carries the full history of the repository forever: after a dozen features the finished runs dominate a snapshot that exists to show what is *waiting* — and their merged branches and leftover worktrees pile up under `/orca:status`'s "safe to delete" alongside them.

This skill closes that loop. It is the counterpart to `/orca:status`: status renders the picture and prescribes, this skill performs the retirement — removing a landed run's git footprint (its `orca-*` worktrees and `feature/<slug>` branches) and writing an `archived` marker beside its `report.md`.

**What archiving keeps.** The run directory — spec, plans, reviews, report — is untouched; so is every commit, since the gate only passes when each removed branch is already reachable from the trunk. Nothing outside the run's own footprint is touched: not the trunk, not the user's branches, not the main worktree, not any remote. The marker records every removed branch's tip, so `--undo` recreates them exactly.

## Step 1: Scan

One call, from anywhere in the repository:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh triage archive --scan
```

Read-only, exit 0 always (`FAIL: NOT_GIT` → nothing here to archive; say so and stop). Line types, all TAB-separated:

- `ARCHIVABLE:<TAB><run-dir><TAB><evidence>` — every gate passed. The evidence is the script's own sentence; render it, never embellish it. It is followed by the footprint the archive will remove:
  - `PRUNE:<TAB><run-dir><TAB>worktree|branch<TAB><path|name>` — one line per worktree and branch. These are what the user consents to; render every one.
- `KEPT:<TAB><run-dir><TAB><reason><TAB><detail>` — a gate failed. The reason routes the explanation:
  - `NOT_CLEAN` — the report lists unmet items. `/orca:retry` finishes them, and *that* is the user's real next move, worth naming.
  - `LEASE_LIVE` — an open session owns the run.
  - `NO_TRUNK` — detached or unset HEAD, so merged-ness is unknowable.
  - `NOT_LANDED` — the detail names each unmerged branch (or detached worktree with unmerged commits) and its state. The common case, and the one to state plainly: the work is delivered but not yet landed, so `/orca:review` and the user's own merge come first.
  - `WORKTREE_IN_USE` — removing the footprint would destroy work or pull the floor from under someone. The detail names each case: `(uncommitted changes)` — the user commits, stashes, or discards them; `(locked)` — `git worktree unlock` is theirs to run; `(current directory)` — this session stands inside the worktree, so `cd` out and re-scan; `(checked out at <path>)` or `(the trunk)` — a run branch is in use outside the run.
- `ARCHIVED:<TAB><run-dir>` — already archived. Count them; do not itemize.

**The gate is the script's, not yours.** Never archive a run the scan did not mark `ARCHIVABLE:`, never argue a `KEPT:` verdict into a pass, and never re-derive merged-ness or cleanliness conversationally — the same anchored slug join and the same merge-base test that `/orca:status` renders are what the gate runs, so the two can never disagree. An unmerged branch means unlanded work, and a dirty worktree means work nobody committed — full stop.

An argument narrows what you *present*, never what you scan: match it against the run directories by name or slug fragment, and on no match say so loudly with the list of what exists rather than guessing.

## Step 2: Present, then ask

Open with the count and the consequence in one breath — how many runs are archivable, and that archiving removes their worktrees and branches while keeping their run directories and reports. Then list the archivable runs: directory name, what the run was (its slug is usually enough — do **not** open reports to narrate them; that is the report's job and status's non-goal for the same reason), the one-line evidence, and beneath it every `PRUNE:` worktree path and branch name. A run with no `PRUNE:` lines has no footprint left and archives as a marker alone.

List the `KEPT:` runs after, grouped by reason, each with the move that would unblock it. This is the more useful half of the output for a user who expected everything to retire: a run kept because its branch is unmerged is telling them they have a deliverable waiting to land, and one kept for uncommitted changes is telling them there is work in a worktree they may have forgotten.

Then ask once, plainly: archive all of them, a subset they name, or nothing. Consent is to a stated set of removals. If the user names a subset, read back exactly which directories — and which worktrees and branches with them — you are about to remove before doing it.

## Step 3: Archive

One call per consented run:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh triage archive <run-dir>
```

The verb re-runs the full gate at write time — the scan may be minutes old, and a branch can land, a file can be written, or a session can claim a lease in between — so a typed failure here (`NOT_CLEAN`, `LEASE_LIVE`, `NO_TRUNK`, `NOT_LANDED`, `WORKTREE_IN_USE`, `NO_REPORT`, `NO_RUN_DIR`) is the gate refusing before anything was removed, not an error to work around. Report it and move on to the next run.

On success it prints one `PRUNED:` line per removal — `PRUNED:<TAB>worktree<TAB><path>`, then `PRUNED:<TAB>branch<TAB><name><TAB><sha>` — and then `ARCHIVED:`. `FAIL: PRUNE_FAILED` means git itself refused a removal after the gate passed (a file written in the gap, a submodule): the `PRUNED:` lines before it did happen, no marker was written, and the detail carries git's message. Relay it; once the user clears the cause, re-running the same call finishes the job.

Never edit or create the marker file by hand, and never run `git worktree remove`, `git branch -D`, or `--force` yourself to get past a refusal. Re-archiving an already-archived run is a no-op that succeeds.

Close by stating what changed: N runs retired from triage, the worktrees and branches removed (count them), their directories and reports untouched, `/orca:followup` still able to pick them, and `--undo` able to bring the branches back.

## Undo

`--undo <run>` (or a user asking to restore one) removes the marker:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh triage unarchive <run-dir>
```

Idempotent and ungated. For each branch the archive removed, it prints `RESTORED:<TAB>branch<TAB><name><TAB><sha>` (recreated at its recorded tip) or `NOT_RESTORED:<TAB>branch<TAB><name><TAB><why>` (a branch of that name exists again, or the commit is gone — left alone), then `UNARCHIVED:`. Worktrees are not re-added — `/orca:review` and `/orca:iterate` re-add their own when they need one. Confirm the run is back on the routing surface, and mention that `/orca:status` will show it in whatever group its facts put it in — with restored branches merged, that is usually "safe to delete" again.

Runs archived before archiving removed footprints carry a marker with no recorded removals: their undo only removes the marker, and their leftover branches and worktrees stay where `/orca:status` lists them. Undoing and re-archiving such a run clears them through the gate.

## Non-goals

- **No deletion beyond the gated footprint.** Never a run directory, a report, the trunk, a user's branch, the main worktree, a remote branch, or anything the scan did not list under `PRUNE:` for a consented run — not even when the user asks mid-conversation. Deleting a run directory is the user's alone, and this skill never suggests it.
- **No git outside the verb.** This skill runs no `git worktree remove`, `git branch -D`, `git merge`, or `git push` itself; every removal is the verb's, behind its gate.
- **No archiving of unfinished, blocked, unlanded, or in-use runs.** The gate exists precisely to make "landed" and "nothing lost" provable rather than judged; a user's assurance that something landed or that a worktree's changes do not matter is not evidence, and the answer to a `KEPT:` verdict is the move that clears it.
- **No run-content narration.** Same reason as status: the report is the narrator, and a second one invites drift.
- **No launching.** It hands off by naming skills; each one re-derives its own state.
