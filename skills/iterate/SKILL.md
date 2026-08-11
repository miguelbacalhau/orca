---
description: Do localized new work on a finished orca:feature run's still-unmerged deliverable branch — planned, implemented, independently reviewed, fixed, committed, and merged by the same stage agents, without the full feature pipeline. Picks a delivered-but-unlanded run (a `DONE:` run joined to an unmerged `feature/<slug>` branch from `triage snapshot`), validates the instructions against the system through one research agent, confirms the restated change in a micro-interview, then appends the new items to the run's own spec (continuing the W-id sequence), archives the report, and relaunches the work loop over only the new items on the same integration branch — same run directory, same spec, same branch; the run's artifacts stay its single coherent story. Not for unmet items or escalated decisions (`/orca:retry`), not for landed or deleted branches or real decomposition (`/orca:followup`), not for interrupted runs (`/orca:feature`'s resume), not for debug runs' `fix/<slug>` deliverables, and no unreviewed tier (`/orca:prototype` owns unreviewed speed).
args: <optional instructions>
user-invocable: true
disable-model-invocation: true
---

# Orca: iterate

After a feature run delivers `feature/<slug>`, the user keeps working on that branch: localized changes and improvements that deserve the run's full plan → implement → independent review → fix → commit → merge treatment, but not the full pipeline — no interview, no spec agent, no new run directory. This skill is that verb. The pattern is extracted, not invented: the debug loop's fix tail already nests the work loop over a synthesized one-item contract with no interview and no spec agent; iterate is the same "synthesized contract → nested work loop" move, aimed at a feature run's deliverable and driven by the user's instructions instead of a diagnosis.

The deliverable stays the same branch, and the run's artifacts stay its single coherent story: new items append to the run's own `spec.md` Work Breakdown, the loop runs over the same run directory, so `plans/`, `reviews/`, and `merged.tsv` accumulate and the three-way join `orca:audit`, `/orca:status`, and `orca:pr` perform stays complete. A side directory would leave commits on the branch no artifact explains.

The boundary map, so the verb stays narrow: unmet items and escalated decisions are `/orca:retry`'s; work on a landed (or deleted) branch and anything needing real decomposition is `/orca:followup`'s brief; an interrupted run is `/orca:feature`'s resume; a debug run's `fix/<slug>` is out by decision, not deferral — its nested artifact layout differs, and a fixed bug's case-closed record is not a deliverable to keep extending; follow-on work near a fix is new intent, a brief. And there is no unreviewed fast tier here: the plan is what makes the independent review meaningful, and `/orca:prototype` owns unreviewed speed.

## Step 0: Triage

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh triage snapshot
```

(`FAIL: NOT_GIT` → nothing here to iterate on; say so and stop.)

The candidate set is exact and computed by the script, never re-derived conversationally: a `DONE:` **feature** run whose run directory appears as the join field of a `BRANCH:` line with state `unmerged` — delivered, not yet landed. Render the script's facts; the redirects are read from state:

- **The run is `RUN: interrupted`** → its workflow is mid-flight or resumable — including an interrupted iteration round: Step 3's report archive makes an iterating run read `interrupted` carrying the last persisted runId, and `/orca:feature`'s resume replays the iteration's own workflow. Point there and stop.
- **The chosen run is tagged `leftovers`** → point at `/orca:retry` first: it finishes unmet items and resolves the recorded decisions. If the user insists on iterating anyway, proceed — the two surfaces are independent — but iterate never adopts unmet items or resolves escalated decisions; those stay retry's.
- **The branch reads `merged`, or is gone** → the deliverable landed; new work on it is `/orca:followup`'s brief (which handles the trunk-based continuation). Say so and stop.

Target selection: **one candidate** → offer it in prose. **Several** → when instructions were given, match them against the candidates' slugs, leaning literal — one clear match proceeds, no clear match is a loud miss: list the candidates and ask, never guess (the instructions are the *what*; triage owns the *where*). **No instructions** → ask which. **None** → say what was found instead and name the owning skill, as above.

Carry forward the run directory, the branch, and the joined facts exactly as emitted, and collect the instructions now if none were given.

## Step 1: Research

Before anything is authorized, validate the idea against the system. Pick up any per-repo tuning first: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config show`, taking only the `OVERRIDE:` lines whose stage is `research` (a typed `FAIL:` → proceed with defaults, mention orca:config once, never repair the file here).

Compose the research task message from: the repository root; the instructions verbatim; the prior run's `spec.md` (its Interfaces and `## Decisions` bind this change) and `report.md` **by path**; and — when they exist — a `Project context:` line naming `<repo-root>/.orca/map.md` and `.orca/decisions.md` as hints. The report should answer: does the change fight a recorded decision, touch seams the spec assigned to other items, or need real decomposition?

Spawn **one `orca:research` agent through its bundled one-agent workflow**: the Workflow tool with `scriptPath: "${CLAUDE_PLUGIN_ROOT}/scripts/research.workflow.js"` and `args: { prompt, model?, effort? }`, `model`/`effort` from the `research` OVERRIDE lines, each passed only when set. It runs in the background — wait for its task notification, never fabricate the result; it returns `{ report, died }`, and the runId is throwaway. On `died: true` twice, fall back to reading the prior `spec.md`'s Interfaces and Decisions directly and say the research was skipped.

The report is context for you, never shown raw and never persisted. **This is the redirect valve:** research surfacing "not localized after all" — real decomposition, an overturned recorded decision the user would need to relitigate, scope that dwarfs an amendment — is said now, in conversation, where changing course is cheap: `/orca:followup` for a brief riding on this run, `/orca:feature` for unrelated scope. Stop there rather than launching a run against a change known to be bigger than its contract.

## Step 2: Micro-interview

Open with a reflection of the instructions against the research: what the deliverable does *today* in the touched area, the shape the change would take, and any tensions — with a recorded decision, with another item's seams — named plainly. Tensions surface here, where changing course is cheap.

Pacing follows the interview's rules, scaled down: at most 2–3 open questions across at most a couple of rounds, and **AskUserQuestion is banned for substantive discussion**. With clear instructions and clean research, zero questions. Then **one confirmation** of the restated change — the items, the target branch, and any direction decisions the discussion settled — which authorizes everything that follows, feature's autonomy rule: from here the run asks nothing else, and what it cannot decide becomes a blocked item in the report.

## Step 3: Amend the artifacts

All writes happen before launch, in this order, so an interruption leaves a triage-discoverable state:

1. **Append the items** to `spec.md`'s Work Breakdown, continuing the existing ID sequence (after W6 comes W7 — count retry rounds' items too), under a dated iteration heading (`### Iteration <YYYY-MM-DD>: <one line>`). Each item carries a title, file ownership, deps (on prior items where a real edge exists — recorded for the reader; the launch args prune them below), and a one-line acceptance criterion. Default is one item; 2–3 when the ask naturally splits; needing more means Step 1 should have redirected.
2. **Append direction decisions** from the micro-interview to `spec.md`'s `## Decisions` as tagged bullets — `- (W7) chose X over Y: <the user's why>` — retry's exact format, the binding contract amendments the stage agents read.
3. **Archive `report.md`** to the first free `report.round<N>.md`. From this moment triage reports the run `RUN: interrupted` carrying the **old** runId — acceptable and self-healing: resuming that journal replays instantly to its old result and feature's Step 5 rewrites the report, returning the run to `DONE`. Degraded, documented, and what makes an interrupted iteration resume through the ordinary `/orca:feature` path once the new runId lands below.

## Step 4: Pre-flights and launch

This is a fresh workflow launch, not a resume, so launch-time config legitimately applies. Reuse `/orca:feature`'s launch machinery **by reference, not by copy** — read `${CLAUDE_PLUGIN_ROOT}/skills/feature/SKILL.md` and apply:

- **Step 1's pre-flights:** the environment pre-flight (`orca.sh preflight` gates), the Workflow-tool check, the live MCP gate when the resolved reviewer is codex, and the permissions pre-flight (`bypassPermissions`, with the graceful decline — the amended spec waits on disk; post-archive the run reads interrupted, which is the self-healing state Step 3 documents, and enabling bypass and re-invoking `/orca:iterate` or resuming via `/orca:feature` picks it back up).
- **The config read:** `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config validate` — hold the resolved reviewer and `agents` block for the launch; a typed `FAIL:` stops before anything is spent, pointing at orca:config.
- **Integration worktree check:** the run's report names the exact path in its `**Integration worktree:**` field (read it from the just-archived `report.round<N>.md`). The directory exists → reuse it. Gone — reviewed and removed, machine cleaned → re-add it on the existing branch, the same re-add `/orca:review` offers:

  ```bash
  git worktree add <repo-root>/orca-<slug> feature/<slug>
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets place <repo-root>/orca-<slug>
  ```

  (no `-b` — the branch exists; typed secrets skips are worth a mention, never a stop).
- **Fresh status tasks** for the new items only: `TaskCreate` per item, `addBlockedBy` mirroring deps inside the iteration set, ids into each item's `taskId`.
- **Lease, then launch:** claim the run directory (`orca.sh triage claim <run-dir> 'orca iterate skill; slug=<slug>; pre-launch'`), release it immediately before the Workflow call (`triage release <run-dir>` — the workflow takes its own lease at launch), then **invoke the Workflow tool** exactly as feature Step 4 shapes it: same `scriptPath` (`${CLAUDE_PLUGIN_ROOT}/scripts/work-loop.workflow.js`), the same `runDir`, `repoRoot`, `slug`, and `integrationBranch` as the original launch, `items` = **the new items only** (deps pruned to edges inside the iteration set — a dependency on a merged prior item is satisfied and dropped; the launch validators reject unknown ids), the held `reviewer`/`agents`, and `pluginRoot`. On a typed `LEASE_HELD` refusal, act on the verdict it names as feature Step 4 does.
- **Persist the resume handle immediately:** append the new `**Workflow run:** <runId>` / `**Workflow args:** <one-line JSON, exactly as passed>` pair to the end of `spec.md` — triage reads the LAST pair, so an interrupted iteration resumes through `/orca:feature` with the iteration's own workflow, byte-exact.

## Step 5: Report

Run feature Step 5 by reference — the task reconciliation from the returned values, the re-claim/release around the report window, the `report.md` rewrite, the spoken summary — with the iterate additions:

- The rewrite keeps the **whole-deliverable picture**: the original shipped rows plus the new items' rows with their hashes — and a shipped row an amendment *revised* is corrected in place, never left stale.
- A dated **`## Amendments`** entry recording what was asked and why — provenance that keeps future rounds' research and triage grounded.
- **Integration verification** results for the amended behavior, from the workflow's returned values as usual.
- A **Prior rounds** section naming the archived `report.round*.md` files.

The context agent runs inside the workflow (`updateContext` defaults true), folding the amendment's decisions into `map.md`/`decisions.md` like any landed work — nothing to pass. Close with the standard landing pointer (`/orca:review`, then `git merge --no-ff feature/<slug>` — or `/orca:pr`), and route anything blocked to `/orca:retry` as ever.

## Guidelines

- **Iteration never creates a run**, same as recovery: same run directory, same spec, same branch. Reaching for a new run directory is the sign the user wanted a brief.
- **New scope beyond localized change is a redirect, not a growth path:** `/orca:retry` for unmet items, `/orca:followup` for landed deliverables and real decomposition, `/orca:prototype` for unreviewed speed.
- **No bound on iteration rounds** — deliberately: each requires fresh human intent (the Step 2 confirmation). The artifacts are the memory that keeps round N+1 grounded in rounds 1..N — the dated Work Breakdown headings, the dated Amendments entries, the accumulated `merged.tsv` rows.
- **Attribution, commit, and merge rules are the work loop's own** — the deterministic no-attribution check, the squash-merge ritual, the bounded fix rounds all run inside the workflow; nothing to restate here.
