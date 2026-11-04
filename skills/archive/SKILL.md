---
description: Retire finished orca runs whose work has provably landed — take them off triage and clear their git footprint. Scans every finished run against one deterministic gate — report present, nothing blocked, no live lease, every feature/<slug> branch the run produced merged into the trunk (or already pruned), and every orca-* worktree it left removable without loss — then presents the archivable set with its evidence and the exact worktrees and branches each would remove, and on your consent removes them and marks each run archived. The run directory and report stay: /orca:followup still picks archived runs for deferred follow-ups, and /orca:archive --undo reverses the marker and recreates the removed branches at their recorded tips. Refuses any run it cannot prove has landed, and any worktree holding uncommitted work. Objectives retire here too, landed or not: a landed one loses its worktree and branch, an unlanded one is abandoned on one confirmation naming what is set aside — uncommitted work salvaged into a wip: commit, the tip kept under a hidden ref — and --undo restores either.
args: <optional run directory, objective, or slug fragment, or --undo <run|objective>>
user-invocable: true
disable-model-invocation: true
---

# Orca: archive

Orca never removes a finished run's record. That is the right default — a run's spec, plans, reviews, and report are the durable record of a decision, and `/orca:retry` and `/orca:followup` read them long after the branch has landed. But nothing retires them either, so every entry-point skill's Step 0 triage carries the full history of the repository forever: after a dozen features the finished runs dominate a snapshot that exists to show what is *waiting* — and their merged branches and leftover worktrees pile up under `/orca:status`'s "safe to delete" alongside them.

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

Idempotent and ungated. For each branch the archive removed, it prints `RESTORED:<TAB>branch<TAB><name><TAB><sha>` (recreated at its recorded tip) or `NOT_RESTORED:<TAB>branch<TAB><name><TAB><why>` (a branch of that name exists again, or the commit is gone — left alone), then `UNARCHIVED:`. Worktrees are not re-added — `/orca:review` re-adds its own when it needs one. Confirm the run is back on the routing surface, and mention that `/orca:status` will show it in whatever group its facts put it in — with restored branches merged, that is usually "safe to delete" again.

Runs archived before archiving removed footprints carry a marker with no recorded removals: their undo only removes the marker, and their leftover branches and worktrees stay where `/orca:status` lists them. Undoing and re-archiving such a run clears them through the gate.

## Objectives

An objective (`.orca/objectives/<YYYYMMDD-HHMMSS>-<slug>/`) retires through its own verb, never `triage archive` (which refuses one, `BAD_ARGS`). Unlike a run, it can be retired without landing: **abandoning** sets it aside, restorable. Its directory — objective, decisions, phases, report, follow-ups — always stays.

**Scan.** Alongside Step 1's call:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective list . --all
```

One `OBJECTIVE:` line per objective, TAB-separated: dir, slug, state, `open:`, `pending:`, `blocked:`, `followups:`, `owner:`. `archived` and `abandoned` are already retired — count them with the archived runs. The rest:

- **`landed`** — every phase done and the branch merged into the trunk. Present it with the archivable runs: archiving removes its worktree (`<repo-root>/orca-<slug>`) and branch (`feature/<slug>`), and keeps its directory.
- **Any other state** — not landed. Never offered unprompted: abandoning is the user's call. When the argument or the user names one, prepare the abandon confirmation below.
- **`owner:live`** or **`owner:unknown`** — another session drives it (`unknown`: another machine, maybe). It cannot be archived from here; say which, and that it can be once that session has ended. `owner:mine` and `owner:stale` are fine.

**One confirmation per objective**, never one for a batch — each names what that one retires:

- **Landed** → its worktree and branch go, its directory and report stay, and `--undo` brings the branch back.
- **Abandon** → name what is being set aside, from the verbs, never from git yourself: the commits ahead of the trunk (from `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh triage snapshot`, read-only, run once before composing the confirmation: the `ahead:<n>` of the `BRANCH:` line whose last field is the objective's directory — no such line means it has no branch yet), whether the worktree is dirty (the `Worktree:` line of `objective digest <dir>`: `clean`, `dirty`, or `absent`), its open follow-ups and pending or blocked phases (the list line's counts), and an active phase when the state is `active`. Then say what happens on yes: uncommitted work becomes one `wip:` commit, the tip is kept under a hidden ref (`refs/orca/archive/<slug>`, safe from `git gc`), the worktree and branch go, and `--undo` restores the branch. Ask for a one-line reason, optional — it is recorded with the archive.

**Archive**, one call per confirmed objective:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective archive <dir>                               # landed
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective archive <dir> --abandon [--note '<reason>']   # anything else
```

The frame: `state` (`landed` or `abandoned`), `tip`, `ref`, `salvaged` (`committed` — the wip: commit was made; `clean`; `no-worktree`), `worktree` and `branch` (`removed` or `absent`); `already=yes` means it was archived before — a no-op. A typed `FAIL:` changed nothing; relay it and move on: `NOT_LANDED` (it is not landed, or its tree is dirty — only a confirmed abandon passes `--abandon`), `OWNED_ELSEWHERE` (another session owns it), `WORKTREE_IN_USE` (this shell stands inside its worktree — `cd` out and retry; or its branch is checked out somewhere else, which the detail names). `GIT_ERROR` part way leaves no `archived` file: relay git's message; re-running the same call finishes the job once the cause is cleared.

**Undo.** `--undo <objective>` (its directory, or a slug the `--all` list matches with state `archived` or `abandoned`):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective unarchive <dir>
```

The frame: `restored` (`no` — it was not archived), `branch` (`restored` at the kept tip, `exists` — already there at that tip, or `none` — it never had one), `tip`. `BRANCH_EXISTS` means a branch of that name now points elsewhere and `NO_ARCHIVE` that the kept tip is gone; nothing was restored — relay the detail. The worktree is not re-added: the next `/orca:open` re-adds it on the restored branch, salvaged work included.

## Non-goals

- **No deletion beyond the gated footprint.** Never a run or objective directory, a report, the trunk, a user's branch, the main worktree, a remote branch, or anything the scan did not list under `PRUNE:` for a consented run — not even when the user asks mid-conversation. Deleting a run directory is the user's alone, and this skill never suggests it.
- **No git outside the verb.** This skill runs no `git worktree remove`, `git branch -D`, `git merge`, or `git push` itself; every removal is the verb's, behind its gate.
- **No abandoning an objective without its own confirmation**, and never one another session owns.
- **No archiving of unfinished, blocked, unlanded, or in-use runs.** The gate exists precisely to make "landed" and "nothing lost" provable rather than judged; a user's assurance that something landed or that a worktree's changes do not matter is not evidence, and the answer to a `KEPT:` verdict is the move that clears it.
- **No run-content narration.** Same reason as status: the report is the narrator, and a second one invites drift.
- **No launching.** It hands off by naming skills; each one re-derives its own state.
