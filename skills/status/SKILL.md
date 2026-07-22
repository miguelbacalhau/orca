---
description: The read-only dashboard — the answer to "where was I?" in a repository orca has worked in. Joins the .orca/ picture (interrupted and unlaunched runs, finished runs and their leftovers, queued briefs, open bug cases) with git ground truth (unmerged feature/<slug> deliverables, kept item branches, leftover orca-* worktrees, orphans from abandoned runs) into one screen grouped by next action, each state naming the skill that owns it — /orca:feature, /orca:retry, /orca:followup, /orca:review, /orca:debug. Strictly read-only: it prescribes cleanup commands for provably safe deletions but never runs them, launches nothing, and invokes no other skill. With an argument, only the matching run's states render. Use it reflexively; the skills it points at re-derive state themselves, so nothing depends on status having run.
args: <optional run directory or slug fragment>
user-invocable: true
disable-model-invocation: true
---

# Orca: status

Every other skill that reads orca's state immediately starts *doing* something with it — feature resumes, retry retries, followup writes a brief. This skill is the way to just look. It joins two fact sources — what `.orca/` records and what git actually holds — and renders one screen grouped by what the user can do about each thing, every state pointing at the skill that owns it. It looks, it routes, and it gets out of the way: the named skill's own triage re-derives state at invocation time, so nothing depends on status having been run, and status going stale mid-conversation costs nothing.

The cross-reference is where the value lives. A `DONE clean` run whose `feature/<slug>` is unmerged is *delivered but not landed* — a different next move than the same run with the branch merged or gone (*fully landed*, the happiest state). A finished run's kept item branches corroborate its blocked items. A branch or worktree matching no surviving run directory is an orphan from an abandoned or pre-plugin run — and whether that orphan is safe to delete is provable from its ahead-count, not guessed from its provenance.

## Step 0: Gather the facts

Two read-only script calls, from anywhere in the repository:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/triage.sh discover
bash ${CLAUDE_PLUGIN_ROOT}/scripts/triage.sh status
```

`discover` is the shared triage spine; unlike the other callers, read **every** line type: `RUN:` (interrupted/unlaunched, with resume-handle lines you do not need here), `DONE:` (clean/leftovers/unknown), `BRIEF:`, and `CASE:`. `status` is the git side: `TRUNK:`, then `BRANCH:`/`ITEMBR:`/`WORKTREE:` lines — each carrying merged-ness against the right target (`ahead:<n>` on integration branches counts the commits the trunk lacks) and, as its last field, the joined run directory or `orphan`. The join is computed in the script, by slug; never re-derive it conversationally.

`FAIL: NOT_GIT` from either call: say there is nothing here to report on and stop. Both otherwise exit 0 always; empty output plus no git footprint is the also-happy answer "nothing is waiting — no runs, no briefs, no cases, no leftover branches or worktrees", said in one line.

## Step 1: Cheap enrichment

For each `DONE:` run that will render, do a **targeted** read of its `report.md`: the `## Blocked` section (to name the blocked items beside their kept branches) and the `## Follow-ups` section (to know whether a landed run still has deferred work worth a `/orca:followup`). Names and one-line reasons only — no whole-report reads, no subagent. Deep verification of report claims against git is `orca:audit`'s job under retry/followup; duplicating it here would make status too expensive to invoke reflexively. Status is the glance, not the audit.

## Step 2: Render — one screen, grouped by next action

Group by what the user can do, each group naming its owning skill. Omit empty groups; keep each entry to state, evidence, and the next move — the order below is roughly "work in flight" to "housekeeping":

- **Interrupted run** → resumable via `/orca:feature` (or `/orca:debug` for an interrupted `CASE:`) — with the liveness caveat below.
- **Unlaunched run** — `RUN: <dir> unlaunched` died before its workflow launched and is **not resumable**. Its consumed brief survives at `<run-dir>/brief.md`: prescribe re-queuing it (`mv <run-dir>/brief.md .orca/feat-briefs/` then remove the run dir), where `/orca:feature` will find it.
- **Finished, leftovers** → `/orca:retry`. List the blocked items (from the report) side by side with their kept `ITEMBR: unmerged` branches — the two corroborate each other. Kept blocked branches belong here, never in cleanup.
- **Finished clean, deliverable unmerged** — the joined `BRANCH:` is `unmerged` → `/orca:review` to walk the diff, then the user's own `git merge --no-ff feature/<slug>`. The `ahead:<n>` count is worth stating: unmerged by the whole feature reads differently than by one commit.
- **Finished clean, landed** — no surviving `BRANCH:` line, or the joined `BRANCH:` is `merged` (landed but never pruned) → fully landed; when its report's Follow-ups list anything, name them and point at `/orca:followup`. A surviving merged branch and its worktree additionally appear under "safe to delete".
- **Queued briefs** → `/orca:feature`.
- **Open bug cases** (`CASE: ready`) → `/orca:debug`.
- **Safe to delete** — deletions that are machine-provably lossless: `ITEMBR: merged` branches (merged then never pruned), `BRANCH: merged` integration branches (landed but never pruned — joined or orphan alike), orphan branches at `ahead:0`, and worktrees on any of these. Prescribe the exact commands, unhedged: `git worktree remove <path>` first where one exists, then `git branch -D <branch>`.
- **Needs a look** — orphans with `ahead:<n> > 0` carry commits reachable nowhere else (a salvaged WIP from a hand-deleted run dir, a pre-plugin half-feature). Inspection commands first (`git log <trunk>..<branch> --oneline`, `git -C <worktree> status`), delete commands after, clearly marked as the step for when the user has looked.

Two safety tiers, deliberately separate, so neither message hedges the other: the provably-safe framing must not bleed onto unlanded work, and the caution must not make users second-guess deletions that need none. Orphan-ness alone never decides the group — the ahead-count does. A `merged` state of `unknown` (no trunk to test against) renders as exactly that, in "needs a look" territory, never as a guess.

**The liveness caveat.** The on-disk predicate cannot tell an interrupted run from one still executing — `report.md` only appears at the end. Before saying "resume it", check this session's own task list and background tasks: if the run's workflow is live there, render it as *running now*, not interrupted. Otherwise present it as "not finished; resumable via `/orca:feature` *if nothing is running it*" — another session could be driving it, and only the user knows. Never claim a run is dead.

**The argument filter — render-side only.** With an argument, match it against the run directories (name or slug fragment — the same matching rule as `/orca:retry` and `/orca:followup`: one match → that run; no match → a loud miss listing what exists, never a guess). The facts are always gathered in full; the filter narrows what renders to the matching run's states — branches, worktrees, report enrichment — and may afford more per-run detail (the full blocked list rather than counts). Cross-cutting facts still surface in one line even when filtered out — e.g. asking about run A while run B holds the repository's only interrupted state.

## Non-goals

Stated so the boundary holds under pressure:

- **No mutations.** Not even "obviously safe" ones: no `git worktree remove`, no `git branch -D`, no re-queuing a brief, no consent-per-step cleanup mode. A dashboard users run reflexively must have no hands — one misread and a mutating status kills a resumable run. Prescribe; never execute.
- **No audit.** Report claims are rendered as claims; verifying them against git belongs to `orca:audit` under `/orca:retry` and `/orca:followup`.
- **No run-content narration.** Status answers "what states exist and what is the next move for each" — never what a feature was or what shipped. The report already does that; a second narrator invites drift.
- **No invoking other skills.** Hand off by naming them; each one's own triage re-derives state when the user invokes it.
