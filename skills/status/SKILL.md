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

One read-only script call, from anywhere in the repository (add `--run <argument>` when the invocation carried one):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh triage snapshot
```

The snapshot is both fact domains in one call, plus the script's own routing. Unlike the other callers, read **every** line type. The `.orca` side: `RUN:` (interrupted/unlaunched, with resume-handle lines you do not need here), `DONE:` (clean/leftovers/unknown), `BRIEF:`, and `CASE:` — each `RUN:`/`DONE:`/`CASE:` followed by its `LEASE:` verdict (live/stale/none/unknown — the liveness section below), and each `DONE:` by `BLOCKED:`/`FOLLOWUP:` lines carrying the report's `## Blocked` and `## Follow-ups` section bodies base64-encoded. The git side: `TRUNK:`, then `BRANCH:`/`ITEMBR:`/`WORKTREE:` lines — each carrying merged-ness against the right target (`ahead:<n>` on integration branches counts the commits the trunk lacks) and, as its last field, the joined run directory or `orphan`. Last, `ACTION:` lines — the ranked routing conclusion (`rank`, `slug`, `owner`, `target`, base64 evidence), computed where both fact domains and the slug join live. The join and the routing are computed in the script; never re-derive either conversationally.

`FAIL: NOT_GIT`: say there is nothing here to report on and stop. Otherwise exit 0 always; empty output plus no git footprint is the also-happy answer "nothing is waiting — no runs, no briefs, no cases, no leftover branches or worktrees", said in one line.

## Step 1: Cheap enrichment

Decode the `BLOCKED:`/`FOLLOWUP:` payloads for the `DONE:` runs that will render — the blocked items' names and one-line reasons beside their kept branches, and whether a landed run still has deferred work worth a `/orca:followup`. The sections arrive on the wire byte-exact, so nothing is paraphrased and **no report file is opened**. Deep verification of report claims against git is `orca:audit`'s job under retry/followup; duplicating it here would make status too expensive to invoke reflexively. Status is the glance, not the audit.

## Step 2: Render — one screen, grouped by next action

The grouping is handed to you: each `ACTION:` line's slug names the group, its rank the order, its owner the skill to point at, and its decoded evidence the one-line why — Step 2 is slug→sentence rendering, not derivation. States that get no action line (an in-flight run under a `live` lease, a kept blocked branch corroborating a `leftovers` run) still render from their fact lines. Omit empty groups; keep each entry to state, evidence, and the next move — the slugs map to the groups below, roughly "work in flight" to "housekeeping":

- **In flight / owned** — a `RUN:` or `CASE:` whose lease is `live` gets no resume action, deliberately: an open session owns it. Render it first, as *owned by an open session (not necessarily executing — the owner may be idle)*; never present it as resumable, and never claim it is dead.
- **Interrupted run** (`resume-run`, `debug-case` on an interrupted case) → resumable via `/orca:feature` (or `/orca:debug`) — the lease said `stale`, `none`, or `unknown`; on `unknown` (another host, or an unreadable owner file) add that another machine may be driving it — only the user knows.
- **Rerunnable brief** (`run-brief` on a run dir) — the session died between consuming the brief and writing the spec; `/orca:feature` reruns it in place.
- **Unlaunched run** (`requeue-brief`) — died before its workflow launched and is **not resumable**. Its consumed brief survives at `<run-dir>/brief.md`: prescribe re-queuing it (`mv <run-dir>/brief.md .orca/feat-briefs/` then remove the run dir), where `/orca:feature` will find it.
- **Finished, leftovers** (`finish-unmet`) → `/orca:retry`. List the blocked items (decoded from `BLOCKED:`) side by side with their kept `ITEMBR: unmerged` branches — the two corroborate each other. Kept blocked branches belong here, never in cleanup.
- **Finished clean, deliverable unmerged** (`review-deliverable`) → `/orca:review` to walk the diff, then the user's own `git merge --no-ff feature/<slug>`. The `ahead:<n>` count is worth stating: unmerged by the whole feature reads differently than by one commit.
- **Finished clean, landed** (`followup`) → fully landed; name the decoded `FOLLOWUP:` items and point at `/orca:followup`. A surviving merged branch and its worktree additionally appear under "safe to delete".
- **Queued briefs** (`run-brief`) → `/orca:feature`.
- **Open bug cases** (`debug-case` on a ready case) → `/orca:debug`.
- **Safe to delete** (`prune-branch`, `prune-worktree`) — deletions that are machine-provably lossless: `ITEMBR: merged` branches (merged then never pruned), `BRANCH: merged` integration branches (landed but never pruned — joined or orphan alike), orphan branches at `ahead:0`, and worktrees on any of these. A `stale` lease on a `DONE:` run belongs here too — a lock stranded by a session that died between writing the report and releasing; prescribe `rm -rf <run-dir>/.lock`. Prescribe the exact commands, unhedged: `git worktree remove <path>` first where one exists, then `git branch -D <branch>`.
- **Needs a look** (`inspect-orphan`) — orphans with `ahead:<n> > 0` carry commits reachable nowhere else (a salvaged WIP from a hand-deleted run dir, a pre-plugin half-feature). Inspection commands first (`git log <trunk>..<branch> --oneline`, `git -C <worktree> status`), delete commands after, clearly marked as the step for when the user has looked.

Two safety tiers, deliberately separate, so neither message hedges the other: the provably-safe framing must not bleed onto unlanded work, and the caution must not make users second-guess deletions that need none. Orphan-ness alone never decides the group — the ahead-count does. A `merged` state of `unknown` (no trunk to test against) renders as exactly that, in "needs a look" territory, never as a guess.

**Liveness is the lease's verdict, not a guess.** Each run's `LEASE:` line answers what the old on-disk predicate could not: `live` — an open session on this host owns the run; phrase it as *owned*, never as *executing right now* (the owner may be idle or `/clear`ed), and never offer a resume over it. `stale` — the holder provably crashed; the resume offer is unhedged. `none` — no lock. `unknown` — another machine or an unreadable owner file: the only case where the old caveat survives; present the run as "resumable *if nothing elsewhere is running it*" — only the user knows. One nuance this session can add: if this very session's task list shows the run's workflow running, render it as *running now*.

**The argument filter — render-side only.** With an argument, pass it as `--run <fragment>` and read the script's verdict: `MATCH:` lines name the run dirs whose basename contains the fragment (several matches → say so and render each); `MISS:` plus `CANDIDATE:` lines are the loud miss — list what exists, never guess. The facts are always gathered in full; the filter narrows what renders to the matching run's states — branches, worktrees, enrichment — and may afford more per-run detail (the full blocked list rather than counts). Cross-cutting facts still surface in one line even when filtered out — e.g. asking about run A while run B holds the repository's only interrupted state.

## Non-goals

Stated so the boundary holds under pressure:

- **No mutations.** Not even "obviously safe" ones: no `git worktree remove`, no `git branch -D`, no re-queuing a brief, no removing a stale lock, no consent-per-step cleanup mode. The triage verb's read-only boundary runs per-subcommand — `snapshot` (this skill's one call) is strictly read-only, while `claim`/`release` mutate — and status never touches the mutating pair. A dashboard users run reflexively must have no hands — one misread and a mutating status kills a resumable run. Prescribe; never execute.
- **No audit.** Report claims are rendered as claims; verifying them against git belongs to `orca:audit` under `/orca:retry` and `/orca:followup`.
- **No run-content narration.** Status answers "what states exist and what is the next move for each" — never what a feature was or what shipped. The report already does that; a second narrator invites drift.
- **No invoking other skills.** Hand off by naming them; each one's own triage re-derives state when the user invokes it.
