---
description: Finish a finished orca:feature run's unmet work items inside the same run. Picks a finished run with leftovers (newest by default, or the one named), audits it through a subagent — reconciling the report's claims against the spec's work breakdown and git ground truth — then resolves every blocked item's recorded decision with the user, appends those resolutions to the run's own spec as binding Decisions bullets, archives the superseded plans, reviews, and report, and relaunches the work loop over only the unmet items on the same integration branch, each carrying a retry note that points at the precise failure evidence. Recovery never creates a run: no new run directory, no new spec, no brief. Not for interrupted runs (no report.md yet — that is `/orca:feature`'s resume) and not for new scope (that is a brief, via `/orca:followup` or `/orca:feature`'s interview).
args: <optional run directory or slug fragment>
user-invocable: true
disable-model-invocation: true
---

# Orca: retry

A run ends in exactly one of two honest states: spec fully resolved — every item merged or cut — or explicitly awaiting retry. This skill is the retry. It finishes a finished run's unmet work **inside the same run**: same run directory, same spec, same integration branch. The precise failure record the run left behind — the blocked reasons, the review findings under `reviews/`, the archived plans, the escalation options — stays exactly where the retry round's agents will look for it, instead of being laundered into a prose brief for a second run.

Three surfaces, three answers to "what does this run need next": an *interrupted* run (no `report.md`) resumes from its journal via `/orca:feature`; a *finished run with unmet items* retries here; a *finished run whose optional follow-ups the user wants* becomes a new brief via `/orca:followup`. This skill owns only the middle case, and redirects the other two.

One boundary is principled, not arbitrary: the run's escalation agents already spent its bounded machine retries deciding each blocked item could not be resolved within the spec. A retry with no new input would reproduce the block. What legitimately resets those bounds is **human initiation** — the user resolving, in Step 2, exactly the decisions the run recorded as beyond its authority. That is why the unblock interview is mandatory, and why its resolutions are written into the spec before anything relaunches.

## Step 0: Pick the run

Discovery runs through the shared triage spine:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/triage.sh discover
```

Read the `DONE:` lines — finished feature runs, oldest first, each tagged `clean`, `leftovers`, or `unknown` from its report's `## Blocked` section. (`FAIL: NOT_GIT` means there is nothing here to retry; say so and stop.)

- **No `DONE:` lines** — nothing has finished. If a `RUN: <dir> interrupted` line exists, the user's real move is the resume: say the run is interrupted, not finished-partial, and point at `/orca:feature`, which discovers it in triage. Otherwise point at `/orca:feature` to run something first. Stop either way.
- **An argument** — match it against the `DONE:` run directories (name or slug fragment). One match → that run. No match → a loud miss: list the finished runs, never guess.
- **No argument** — default to the newest (last `DONE:` line). When several runs finished, name the chosen one and list the others in one line — the audit verdict in Step 2 restates the choice, so a wrong default is visible and cheap to correct.

**The chosen run is `clean`** — nothing to retry: every item merged or was cut. Say so; if its report's Follow-ups section lists anything, point at `/orca:followup` for those. Stop. An `unknown` tag proceeds — the marker is routing sugar and the audit is the real check.

## Step 1: Audit

Spawn **one `orca:audit` subagent**, passing the repository root (the parent of `git rev-parse --path-format=absolute --git-common-dir`), the run directory, and that **orca:retry** is asking. The agent reads the run's artifacts, verifies the report's claims against the work breakdown and git, and returns a compact reconciliation as its final message. All heavy reading lives and dies there — the main conversation consumes only the returned report. Retry consumes the **completion picture** (which items verifiably merged — the integration branch's first-parent log, not the Shipped table), the **discrepancies**, the **unfinished items** (with their blocked reasons and surviving branches), and the **escalated decisions**.

The audit is context for you, never shown raw to the user. If the agent fails, fall back to reading `<run-dir>/report.md` and `<run-dir>/spec.md` directly and say plainly that the git verification was skipped — a degraded but honest basis beats a dead end.

**If the audit finds nothing unmet** — an optimistic Blocked section over work that actually merged — report that, point at `/orca:followup` if follow-ups remain, and stop.

## Step 2: Unblock interview

The load-bearing step. Open with the verification verdict — which run, what verifiably landed, what did not, any report-vs-git discrepancies named plainly — then work through the unmet items. Present per item: the blocked reason as recorded, the options the escalation recorded for the user, and the relevant Critical/High review findings. Collect the user's resolution for **every** item that will be retried — or the decision to cut it, which here is the user amending scope, recorded like any decision. Two further moves are in scope, both recorded as tagged `## Decisions` bullets in Step 3:

- **Un-cut.** The user may resurrect an item the run cut autonomously. A cut is a machine-made scope reduction under prefer-smaller-scope that the user never directly approved — overruling it restores scope the original brief contained rather than expanding it. A resurrected item rejoins the retry set like a blocked one, and its resolution bullet records the overrule.
- **Amending merged code.** A resolution may require changing code an earlier item already merged — an interface the blocked item cannot live with. That is allowed: the retried item's plan amends the merged code as part of its own build, with the decision bullet as the authority. Frame merged commits as facts to build from, never to revert wholesale — and cross-item file ownership is no obstacle in a small retry wave.

Pacing follows the interview's rules: multi-round, at most 2–3 open questions per round, no topic-list batching, and **AskUserQuestion is banned for substantive discussion**. Depth is proportional to what is open: one mechanical block with an obvious recorded fix needs one confirming round; real decisions take the rounds they take.

**New scope is refused politely.** Work beyond the spec's own unmet items (plus un-cut resurrections) is a brief — point at `/orca:followup` for follow-ups riding on this run, or `/orca:feature`'s interview for unrelated ideas. The retry's item set is the original breakdown's unmet subset; a restructure is a new brief.

## Step 3: Amend the run

All writes happen before launch, in this order, so an interruption at any point leaves a triage-discoverable state:

1. **Append the resolutions to `spec.md`'s `## Decisions`** as tagged bullets — `- (W3) chose X over Y: <the user's why>` — the same format the escalation agents write. Un-cut resurrections and merged-code amendments land here too, each tagged with the item ids it binds.
2. **Archive per retried item:** move `plans/<ID>.md` to the first free `plans/<ID>.round<N>.md` (the workflow's own replan convention — a superseded plan left in place reads as finished work to a fresh planner), and move the item's `reviews/<ID>-*.json` files (round archives included) into `reviews/prev<N>/`, first free `N` per retry. The retry round's fresh archives must never overwrite the failure evidence the retry notes point at, and a second retry must not collide with the first's archive.
3. **Archive `report.md`** to the first free `report.round<N>.md`. From this moment triage reports the run `RUN: interrupted` carrying the **old** runId — acceptable and self-healing: resuming that journal replays instantly to the old result, and the feature skill's Step 5 rewrites the report, returning the run to `DONE`. Degraded, documented, and preferable to a run-state file.
4. **Reuse or recreate the integration worktree**, stating which case applied: `<repo-root>/orca-<slug>` exists → reuse it; the directory is gone but `feature/<slug>` exists → `git worktree add <repo-root>/orca-<slug> feature/<slug>` (no `-b` — the branch exists) followed by `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets place <repo-root>/orca-<slug>`; branch gone too (the user landed and deleted it) → create fresh from the trunk tip exactly as feature Step 3 does, since the landed work is in the trunk.

## Step 4: Relaunch

Reuse `/orca:feature`'s launch machinery **by reference, not by copy** — read `${CLAUDE_PLUGIN_ROOT}/skills/feature/SKILL.md` and apply:

- **Step 1's pre-flights:** the environment pre-flight (`preflight.sh` gates, the Workflow-tool check, the live MCP gate when the reviewer is codex) and the permissions pre-flight (`bypassPermissions`, with the same graceful decline — here the run's amended state simply waits on disk, rediscoverable by `/orca:retry` or, post-archive, as an interrupted run).
- **The config read:** `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config validate`, holding the resolved reviewer and `agents` block for the launch. The retry resolves these fresh — it is a new workflow run, not a resume, so launch-time config legitimately applies; a reviewer switch between rounds just yields mixed artifact filenames in `reviews/`, which the audit and retry notes tolerate by discovering files rather than reconstructing names.
- **Fresh status tasks** for the retried items only: `TaskCreate` per item, `addBlockedBy` mirroring the pruned deps, ids into each item's `taskId`.
- **The Workflow invocation**, exactly as feature Step 4 shapes it — same `scriptPath` (`${CLAUDE_PLUGIN_ROOT}/scripts/work-loop.workflow.js`), same `runDir`/`repoRoot`/`slug`/`integrationBranch` as the original launch, the held `reviewer`/`agents`, `pluginRoot` — with `items` = the unmet items (plus any un-cut resurrections), each with:
  - **`deps` pruned to edges inside the retry set.** A dependency on a previously merged or cut item is satisfied and simply dropped; the launch validators reject unknown ids, and a satisfied dependency needs no entry.
  - **A per-item `retryNote`**, composed here, mirroring the workflow's replan-note posture:

    > Retry: this item blocked in a previous round of this run. Recorded reason: `<the blocked reason>`. The superseded plan is archived at `plans/<ID>.round*.md`, and the prior round's review findings under `reviews/prev<N>/`. The user's unblocking decisions are in `spec.md`'s `## Decisions` — bullets tagged `<ID>` are binding contract amendments. A surviving `wip:` commit on the item branch is partial work to build on or discard — never evidence of completion.

Kept item branches are picked up by the workflow's own arrival ladder (`BRANCH_RESUMED`, secrets re-placed) — no worktree archaeology here.

**Persist the resume handle immediately:** append the new `**Workflow run:** <runId>` / `**Workflow args:** <one-line JSON, exactly as passed>` pair to the end of `spec.md`. Triage reads the LAST pair — designed for this — so an interrupted retry resumes through the ordinary `/orca:feature` triage path with the new runId.

## Step 5: Report

Run feature Step 5 by reference — the task reconciliation from the returned values, the `report.md` write, the spoken summary — with one addition: a **Prior rounds** section naming the archived `report.round*.md` files and the items each round verifiably merged (from the audit), so `report.md` stays the authoritative whole-run picture. The Landing section keeps the standard split: still-blocked items point at `/orca:retry` (another round needs another set of human decisions), remaining follow-ups at `/orca:followup`.

## Non-goals

Stated so the boundary holds under pressure:

- **No spec restructuring.** The item set is the original breakdown's unmet subset, plus un-cut resurrections. Splitting, merging, or adding items is a new brief.
- **No retry of interrupted runs.** No `report.md` means the workflow journal is the recovery surface — `/orca:feature`'s resume, which replays completed work instead of redoing it.
- **No worktree archaeology.** Surviving branches and worktrees are the workflow's arrival ladder's job; this skill never reconstructs, rebases, or inspects them beyond what the audit reports.
- **No bound on rounds** — deliberately. Each retry requires fresh human decisions; the bound on machine retries stays inside the workflow.
