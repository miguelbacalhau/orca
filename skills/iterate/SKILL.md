---
description: Do new work on a finished orca:feature run's still-unmerged deliverable branch, whatever the size — specced by the run's own spec agent in an amend round, adversarially reviewed before launch, then planned, implemented, independently reviewed, fixed, committed, and merged by the same stage agents. Picks a delivered-but-unlanded run (a `DONE:` run joined to an unmerged `feature/<slug>` branch from `triage snapshot`), validates the instructions against the system through one research agent, confirms the restated change in a micro-interview, routes it through the spec workflow (an orca:spec amend round plus the independent spec review), appends the amendment to the run's own spec (continuing the W-id sequence), archives the report, and relaunches the work loop over only the new items on the same integration branch — same run directory, same spec, same branch; the run's artifacts stay its single coherent story. Not for unmet items or escalated decisions (`/orca:retry`), not for merged or deleted branches (the deliverable landed; nothing to iterate on), not for interrupted runs (`/orca:feature`'s resume), not for debug runs' `fix/<slug>` deliverables, and no unreviewed tier (`/orca:prototype` owns unreviewed speed).
args: <optional instructions>
user-invocable: true
disable-model-invocation: true
---

# Orca: iterate

After a feature run delivers `feature/<slug>`, the user keeps working on that branch: new work on the still-unmerged deliverable, whatever the size, that deserves the run's full spec → plan → implement → independent review → fix → commit → merge treatment without a new run. This skill is that verb. Every iteration authors its work contract the way every other orca verb does — through an agent: the confirmed change goes to `orca:spec` in an **amend round**, gets the same independent adversarial review and bounded revise round a fresh run's spec gets, and only then does the work loop run over the new items. The main conversation never hand-authors file ownership, deps, or acceptance criteria from a research report — the one place it used to is exactly the place where a "trivial" amendment silently conflicting with a delivered interface went uncaught.

The deliverable stays the same branch, and the run's artifacts stay its single coherent story: the amendment's items append to the run's own `spec.md` Work Breakdown, the loop runs over the same run directory, so `plans/`, `reviews/`, and `merged.tsv` accumulate and the three-way join `orca:audit`, `/orca:status`, and `orca:pr` perform stays complete. A side directory would leave commits on the branch no artifact explains.

The boundary map is factual — what state is the deliverable in, never a scope call: unmet items and escalated decisions are `/orca:retry`'s; an interrupted run is `/orca:feature`'s resume; a merged or deleted branch means the deliverable landed and there is nothing here to iterate on; a debug run's `fix/<slug>` is out by decision, not deferral — its nested artifact layout differs, and a fixed bug's case-closed record is not a deliverable to keep extending. And there is no unreviewed fast tier here: the spec and plan are what make the independent reviews meaningful, and `/orca:prototype` owns unreviewed speed.

## Step 0: Triage

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh triage snapshot
```

(`FAIL: NOT_GIT` → nothing here to iterate on; say so and stop.)

The candidate set is exact and computed by the script, never re-derived conversationally: a `DONE:` **feature** run whose run directory appears as the join field of a `BRANCH:` line with state `unmerged` — delivered, not yet landed. Render the script's facts; the redirects are read from state:

- **The run is `RUN: interrupted`** → its workflow is mid-flight or resumable — including an interrupted iteration round: Step 4's report archive makes an iterating run read `interrupted` carrying the last persisted runId, and `/orca:feature`'s resume replays the iteration's own workflow. Point there and stop.
- **The chosen run is tagged `leftovers`** → point at `/orca:retry` first: it finishes unmet items and resolves the recorded decisions. If the user insists on iterating anyway, proceed — the two surfaces are independent — but iterate never adopts unmet items or resolves escalated decisions; those stay retry's.
- **The branch reads `merged`, or is gone** → the deliverable landed; there is nothing here to iterate on. Say so and stop.

Target selection: **one candidate** → offer it in prose. **Several** → when instructions were given, match them against the candidates' slugs, leaning literal — one clear match proceeds, no clear match is a loud miss: list the candidates and ask, never guess (the instructions are the *what*; triage owns the *where*). **No instructions** → ask which. **None** → say what was found instead, with whatever pointer its state earns above.

Carry forward the run directory, the branch, and the joined facts exactly as emitted, and collect the instructions now if none were given.

## Step 1: Research

Before anything is authorized, validate the idea against the system. Pick up any per-repo tuning first: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config show`, taking only the `OVERRIDE:` lines whose stage is `research` (a typed `FAIL:` → proceed with defaults, mention orca:config once, never repair the file here).

Compose the research task message from: the repository root; the instructions verbatim; the prior run's `spec.md` (its Interfaces and `## Decisions` bind this change) and `report.md` **by path**; and — when they exist — a `Project context:` line naming `<repo-root>/.orca/map.md` and `.orca/decisions.md` as hints. The report should answer: does the change fight a recorded decision, touch seams the spec assigned to other items, or ask for something this deliverable was never about?

Spawn **one `orca:research` agent through its bundled one-agent workflow**: the Workflow tool with `scriptPath: "${CLAUDE_PLUGIN_ROOT}/scripts/research.workflow.js"` and `args: { prompt, model?, effort? }`, `model`/`effort` from the `research` OVERRIDE lines, each passed only when set. It runs in the background — wait for its task notification, never fabricate the result; it returns `{ report, died }`, and the runId is throwaway. On `died: true` twice, fall back to reading the prior `spec.md`'s Interfaces and Decisions directly and say the research was skipped.

The report is context for you, never shown raw and never persisted. **The valve is intent, not size:** only genuinely unrelated scope — a new outcome, not an amendment to this one — is a redirect, said now, in conversation, where changing course is cheap: `/orca:feature`. Everything else research surfaces — seams the change touches, tensions with delivered interfaces, recorded decisions the change presses on, a change that decomposes into many items — is input to the micro-interview and the spec prompt, never a reason to stop: the spec agent authors as many items as the change needs, and the spec review polices the conflicts.

## Step 2: Micro-interview

Open with a reflection of the instructions against the research: what the deliverable does *today* in the touched area, the shape the change would take, and any tensions — with a recorded decision, with another item's seams — named plainly. Tensions surface here, where changing course is cheap. When the change would **reverse a recorded decision** (a `## Decisions` entry, or one from `.orca/decisions.md`), relitigate it with the user directly, here: present the recorded choice and its why, ask whether it falls, and carry the outcome as a direction decision — the reversal lands as a tagged `## Decisions` bullet in Step 4 that the amendment builds under. A reversal never routes anywhere; this interview is where it is decided.

Pacing follows the interview's rules, scaled down: at most 2–3 open questions across at most a couple of rounds, and **AskUserQuestion is banned for substantive discussion**. With clear instructions and clean research, zero questions. Then **one confirmation** of the restated change — the change itself, the target branch, and any direction decisions the discussion settled (reversals included) — which authorizes everything that follows, feature's autonomy rule: from here the run asks nothing else, and what it cannot decide becomes a blocked item in the report. The confirmation is on intent; the spec workflow then translates, and its outcome lands as one-way status — no second gate.

## Step 3: Spec the amendment

The confirmed change goes to the spec workflow — `orca:spec` in an amend round, followed by the same independent adversarial review and bounded revise round a fresh run's spec gets. Nothing is written to the run's artifacts until Step 4; everything here fails cheap.

**Validate before spending** (feature Step 1's rationale, moved to where the first spawn happens):

- **Environment pre-flight:** `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh preflight` — on any `FAIL`, relay the failing gate's remediation from `${CLAUDE_PLUGIN_ROOT}/skills/feature/SKILL.md` Step 1 and stop. Hold its `REVIEWER:` line.
- **Config read:** `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config validate` — hold the resolved JSON for the rest of the invocation; a typed `FAIL:` stops before anything is spent, pointing at orca:config. **The run's reviewer** is the held JSON's `reviewer` when present, else the preflight's `REVIEWER:` value; the held `agents` block travels to both workflow launches. No later step re-reads the config.
- **Workflow tool:** this step and Step 5 both run through it; if the session lacks it, stop and say so.
- **Live MCP gate**, when the resolved reviewer is codex: ToolSearch `select:mcp__plugin_orca_orca-codex__codex`; if it does not resolve, diagnose and stop per feature Step 1's live MCP gate.

**Compose the amend prompt** from:

- an opening line marking this an **amend round** (the spec agent's third mode)
- the run directory and the repository root
- the current timestamp, from `date +"%Y-%m-%d %H:%M"`
- the **confirmed change** from Step 2, direction decisions included — it stands in for the brief
- the existing spec **by path** (`<run-dir>/spec.md`), stated as binding: its Interfaces and `## Decisions` are contracts delivered code relies on
- the W-id to continue from: the next id after the highest in `spec.md`'s Work Breakdown, retry rounds' items counted
- the output path: `<run-dir>/spec.amendment.md`
- when they exist, a `Project context:` line naming `<repo-root>/.orca/map.md` and `.orca/decisions.md` as hints

**Create the review worktree at the deliverable branch's tip, not trunk** — the amendment amends `feature/<slug>`'s code, and a reviewer on the trunk tip would judge it against a codebase missing everything the run delivered:

```bash
git worktree add --detach <repo-root>/orca-<slug>-specreview feature/<slug>
```

No branch, no `secrets place` — clean by construction. Every spec-workflow invocation is bracketed by this create and the matching remove.

**Invoke the Workflow tool** with `scriptPath: "${CLAUDE_PLUGIN_ROOT}/scripts/spec.workflow.js"` and `args: { prompt, model?, effort?, runDir, reviewWorktree, reviewer, amendPath }` — `model`/`effort` from the held `agents.spec` block, each passed only when set; `runDir`, `reviewWorktree`, and `amendPath` (`<run-dir>/spec.amendment.md`) absolute; `reviewer` the held value. It runs in the background — wait for its task notification, never fabricate the result; the runId is throwaway, never persisted. The review artifact lands as `reviews/spec-amend-<reviewer>.json` — the original run's spec review is never clobbered; across iteration rounds it is latest-wins, like `report.md`.

It returns `{ summary, died, review }`. **Remove the review worktree first** — `git worktree remove <repo-root>/orca-<slug>-specreview` — on every path out. Then branch on the result, feature's gate semantics verbatim:

- `died: true` → relaunch once, re-creating the worktree first. Died twice → the **hand-authoring fallback**: author the items yourself from the confirmed change, exactly as the amend round would have — table rows continuing the W-id sequence with title, file ownership, deps, and a one-line acceptance criterion each — say plainly that the spec stage was skipped, and proceed to Step 4 with these items in place of the amendment file.
- `review.written` with `criticalHigh > 0` and `revised: true` → the revise round folded the findings into the amendment, and its output proceeds — no re-review; carry the counts into the closing status line.
- `review.written` with `criticalHigh > 0` and `revised: false` → the revise spawn died and the findings stand unaddressed. Surface them, pointing at `<run-dir>/reviews/spec-amend-<reviewer>.json` as the evidence, and stop — cheap by construction: nothing has been written yet, the run still reads `DONE`, no report archived, `spec.md` untouched.
- `review.written: false` → the review failed open; relay `review.reason` as a one-way status line and proceed — the amendment stands unreviewed, and every downstream gate still stands.
- otherwise (`criticalHigh: 0`) → clean — proceed.

Close with one one-way status line: what the amendment specced ("specced as W7–W9") and the review outcome (reviewer, finding counts, whether a revise round ran — or that the review failed open).

## Step 4: Amend the artifacts

All persistent writes happen here, in the main conversation, in this order, so an interruption leaves a triage-discoverable state:

1. **Append the amendment to `spec.md`.** Under a dated iteration heading in the Work Breakdown (`### Iteration <YYYY-MM-DD>: <one line>`), append `spec.amendment.md`'s items — the table rows and their acceptance lines (or the hand-authored items on the died-twice path). When the amendment carries an `## Interface additions` section, append its entries to `spec.md`'s Interfaces Between Work Items. Then **delete `spec.amendment.md`** — its content now lives in the spec; the review artifacts stay.
2. **Append direction decisions** from the micro-interview — reversals of recorded decisions included — to `spec.md`'s `## Decisions` as tagged bullets: `- (W7) chose X over Y: <the user's why>` — retry's exact format, the binding contract amendments the stage agents read.
3. **Archive `report.md`** to the first free `report.round<N>.md`. From this moment triage reports the run `RUN: interrupted` carrying the **old** runId — acceptable and self-healing: resuming that journal replays instantly to its old result and feature's Step 5 rewrites the report, returning the run to `DONE`. Degraded, documented, and what makes an interrupted iteration resume through the ordinary `/orca:feature` path once the new runId lands below.

## Step 5: Pre-flights and launch

This is a fresh workflow launch, not a resume, so launch-time config legitimately applies — the config and reviewer were read and held in Step 3; nothing re-reads them here. Reuse `/orca:feature`'s launch machinery **by reference, not by copy** — read `${CLAUDE_PLUGIN_ROOT}/skills/feature/SKILL.md` and apply:

- **The permissions pre-flight** from its Step 1 (`bypassPermissions`, with the graceful decline — the amended spec waits on disk; post-archive the run reads interrupted, which is the self-healing state Step 4 documents, and enabling bypass and re-invoking `/orca:iterate` or resuming via `/orca:feature` picks it back up). The environment pre-flight, config read, and MCP gate already ran in Step 3 — reuse the held values.
- **Integration worktree check:** the run's report names the exact path in its `**Integration worktree:**` field (read it from the just-archived `report.round<N>.md`). The directory exists → reuse it. Gone — reviewed and removed, machine cleaned → re-add it on the existing branch, the same re-add `/orca:review` offers:

  ```bash
  git worktree add <repo-root>/orca-<slug> feature/<slug>
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets place <repo-root>/orca-<slug>
  ```

  (no `-b` — the branch exists; typed secrets skips are worth a mention, never a stop).
- **Fresh status tasks** for the new items only: `TaskCreate` per item, `addBlockedBy` mirroring deps inside the iteration set, ids into each item's `taskId`.
- **Lease, then launch:** claim the run directory (`orca.sh triage claim <run-dir> 'orca iterate skill; slug=<slug>; pre-launch'`), release it immediately before the Workflow call (`triage release <run-dir>` — the workflow takes its own lease at launch), then **invoke the Workflow tool** exactly as feature Step 4 shapes it: same `scriptPath` (`${CLAUDE_PLUGIN_ROOT}/scripts/work-loop.workflow.js`), the same `runDir`, `repoRoot`, `slug`, and `integrationBranch` as the original launch, `items` = **the new items only** (deps pruned to edges inside the iteration set — a dependency on a merged prior item is satisfied and dropped; the launch validators reject unknown ids), the held `reviewer`/`agents` from Step 3, and `pluginRoot`. On a typed `LEASE_HELD` refusal, act on the verdict it names as feature Step 4 does.
- **Persist the resume handle immediately:** append the new `**Workflow run:** <runId>` / `**Workflow args:** <one-line JSON, exactly as passed>` pair to the end of `spec.md` — triage reads the LAST pair, so an interrupted iteration resumes through `/orca:feature` with the iteration's own workflow, byte-exact.

## Step 6: Report

Run feature Step 5 by reference — the task reconciliation from the returned values, the re-claim/release around the report window, the `report.md` rewrite, the spoken summary — with the iterate additions:

- The rewrite keeps the **whole-deliverable picture**: the original shipped rows plus the new items' rows with their hashes — and a shipped row an amendment *revised* is corrected in place, never left stale.
- A dated **`## Amendments`** entry recording what was asked and why, noting that the round was specced through the amend round and independently reviewed, with the artifact name (`reviews/spec-amend-<reviewer>.json`) — or that the died-twice fallback hand-authored it — provenance that keeps future rounds' research and triage grounded.
- **Integration verification** results for the amended behavior, from the workflow's returned values as usual.
- A **Prior rounds** section naming the archived `report.round*.md` files.

The context agent runs inside the workflow (`updateContext` defaults true), folding the amendment's decisions into `map.md`/`decisions.md` like any landed work — nothing to pass. Close with the standard landing pointer (`/orca:review`, then `git merge --no-ff feature/<slug>` — or `/orca:pr`), and route anything blocked to `/orca:retry` as ever.

## Guidelines

- **Iteration never creates a run**, same as recovery: same run directory, same spec, same branch. Reaching for a new run directory is the sign the user wanted a fresh `/orca:feature` run.
- **The spec workflow runs every round** — even an iteration whose amendment matches what hand-authoring would have produced: uniform provenance (every Work Breakdown item was authored by the spec stage and passed the same gate), and the adversarial review covers exactly the case that most needs it — a "trivial" amendment silently conflicting with a delivered interface. Hand-authoring is the died-twice fallback, never a choice.
- **No bound on iteration rounds** — deliberately: each requires fresh human intent (the Step 2 confirmation). The artifacts are the memory that keeps round N+1 grounded in rounds 1..N — the dated Work Breakdown headings, the dated Amendments entries, the accumulated `merged.tsv` rows.
- **Attribution, commit, and merge rules are the work loop's own** — the deterministic no-attribution check, the squash-merge ritual, the bounded fix rounds all run inside the workflow; nothing to restate here.
