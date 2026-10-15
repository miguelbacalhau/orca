# Anatomy of a run

What `/orca:run` does between your confirmation and the report.

```text
/orca:run
   │
   ├─ 0. Triage                     resume an interrupted run · run a queued brief
   │                                · or interview → brief, then run now or queue
   ├─ 1. Pre-flight + confirm       orca.sh preflight gates, Workflow tool
   │                                check, bypassPermissions; ONE user confirmation
   ├─ 2. Spec (orca:spec)           read-only codebase exploration → spec.md with
   │                                Interfaces + a 2–8 item dependency-ordered
   │                                Work Breakdown with file ownership
   │       ──► independent spec review (codex or claude, vs. brief + codebase)
   │       ──► [one revise round folds Critical/High findings in, then launch]
   ├─ 3. Announce / checkpoint      status update, or the one opt-in approval;
   │                                create integration worktree on feature/<slug>
   ├─ 4. Work loop (Workflow tool)  deterministic script, per readiness wave:
   │       plan ∥ ──► reconcile (2+ plans only) ──► [escalate once:
   │                    amend · replan · cut · block] ──► per item:
   │       worktree ► implement ► review (codex or claude) ► fix ► re-review ► commit ► merge
   │       …then, after the loop drains: integrate (verify the assembled feature)
   └─ 5. Report                     report.md: shipped/cut/blocked, deviations,
                                    integration verification, follow-ups,
                                    knowledge worth promoting, landing
```

## Pre-flight

`orca.sh preflight` is read-only and prints one line per gate:

| Line | Checks |
|---|---|
| `BARE_REPO` | git ≥ 2.31, and the repository uses the bare-with-worktrees layout. |
| `TRUNK_CANDIDATE` | Informational: the branch the run would build from. |
| `PLUGIN_ROOT` | The plugin's `scripts/orca.sh` is where the install put it. |
| `CONFIG` | Informational, only when a legacy `.orca/config.json` lingers (`OBSOLETE`). |
| `REVIEWER` | `codex\|claude (pinned\|detected)` — which reviewer this run uses; `FAIL` on an invalid key. |
| `CODEX` | Binary ≥ 0.142.5, authenticated, `codex exec` still has the flags orca drives, `BASH_MAX_TIMEOUT_MS` set to a usable value. `SKIPPED` when the reviewer is claude. |
| `RESULT` | Overall, mirrored by the exit code. |

On any `FAIL` the run does not start. Layout failures go to `/orca:init`, machine failures to `/orca:doctor`.

## Spec and spec review

The `orca:spec` agent writes `spec.md` once, read-only, from the confirmed brief. Its two load-bearing sections:

- **Interfaces Between Work Items** — the contracts (type shapes, signatures, file ownership, naming) that let items build in parallel.
- **Work Breakdown** — the workflow's item list, each item with a one-line acceptance criterion checkable from the integration worktree.

If the scope cannot be split cleanly, the run stops instead of launching.

The run's reviewer then reviews the brief and spec together against a clean checkout at the build tip. It looks for scope drift, missing or violated non-goals, unsound decomposition, unobservable acceptance lines, and undefined or conflicting interfaces; every finding must cite the brief or the codebase. Findings land at `reviews/spec-<reviewer>.json`.

- **Critical/High** findings trigger exactly one revise round. The revised spec launches without re-review. Only a revise agent that dies with findings unaddressed stops the run.
- **Medium/Low** findings are reported in the announce.
- A reviewer that cannot complete **fails open**: reported as status, and the run proceeds.

## The work loop

The bundled `work-loop.workflow.js` runs through the Workflow tool. It is completion-driven: an item launches as soon as its dependencies merge and advances as soon as its previous stage finishes. Each item gets its own worktree on `feature/<slug>-<ID>`.

- **Plan reconciliation** runs only when a wave has two or more plans. It checks for conflicts *between* plans and against the spec's contracts. It runs outside the serialized section; a clean pass over an unchanged `spec.md` doesn't hold other waves back.
- **Review** — codex or claude, adversarial, explicitly attacking the tests. Secrets are stripped from the worktree first. Codex reviews are limited to 2 at a time (they share one Codex login); claude reviews use the normal workflow concurrency.
- **Fix** — at most 2 rounds, only on Critical/High findings.
- **Commit** — one Conventional Commit per item. A deterministic check against `git log` rejects attribution (two attempts, then a forced rewrite).
- **Merge** — serialized. Each item is squashed onto the integration branch under its own commit message; conflicts are resolved by the merge agent with both plans in hand.

### Escalation

- **Amend and continue** when a fix keeps the brief's outcome, features, and non-goals (it changes only *how*). Recorded in the spec's `## Decisions` log, citing the doubt rule. Under `prefer-smaller-scope`, cleanly cutting a feature counts as an amendment.
- **Replan** when the contract is right and a plan got it wrong: that plan is regenerated and `spec.md` is untouched.
- **Block and route around** when every fix would change *what* was agreed. A blocked item's worktree is salvaged into a `wip:` commit on its branch and removed; the branch waits for `/orca:retry`. Unaffected work continues.

One escalation round per reconciliation failure; at most one escalation-backed replan-and-rebuild per item. Whether the spec changed is read from a content hash of `spec.md`, not from the agent's report.

## Integration verification

After the loop drains, `orca:integrate` builds, tests, and exercises each spec feature end to end in the integration worktree, focusing on where items compose. Small integration bugs are fixed, review-checked, and committed; larger mismatches are reported as gaps.

## The report

`report.md` in the run directory: shipped items with commit hashes, deviations (mirroring the Decisions log), blocked items and the decision each waits on, per-feature integration results, follow-ups, knowledge worth promoting, and the landing command. `/orca:review` rounds are appended to it later.

## The run band

The session that launched a run shows it live above the prompt:

```text
── orca ─ staged-typecheck-overlay · build · 3/6 merged ────────────
  W1  Overlay view layers      ✓ done
  W2  Whiteout collector       ✓ done
  W3  CLI flag wiring          ● review r2
  W4  Cache invalidation       ● implement
  W5  Docs + config            ◌ waiting on W3, W4
  W6  Telemetry hook           ✕ blocked: <escalation reason>
```

- During the spec stage the header reads `spec · drafting | reviewing | revising | ready`, and the rows are `spec`, `review` (with findings, or `failed open: <reason>`), and `revise` (or `not needed`). They stay through the checkpoint.
- `◌ waiting on` names unmerged dependencies; an item behind a blocked one reads `waiting on W6 (blocked)`. `–` marks an item the escalation cut.
- It follows only the run this session launched, and disappears when the work loop ends or `report.md` is written. A finished spec followed by three of your prompts without a launch is treated as abandoned.
- Without a readable workflow journal it falls back to the artifacts on disk and shows `no journal` in the header.
- Collapse it with `[-]` or ctrl+x ctrl+a. Where a band can't be drawn (VS Code, `claude -p`) it does nothing.

It is read-only (`hooks/run-band.tsx`, logic in `hooks/derive.ts`): it watches this session's launches of `spec.workflow.js` and `work-loop.workflow.js` and reads the run directory and the workflow journal every 1.5 s.

## Decision log

`.orca/decisions.md` records what was *rejected*, and why — the one thing the code can't tell a future run. Each entry is `chose X over Y: <reason>` with a date, the carrying commit's subject, and an id `D-<short-sha>`. The spec, plan, and interview agents read it first.

It is generated, not maintained: `orca.sh decisions render` rebuilds it from **trunk** commit history at every run launch, extracting the `- chose X over Y: <reason>` bullets the commit stage writes into each item's commit. A run's decisions appear only once you merge its branch, so it is always safe to delete. Land with a real merge (`git merge --no-ff`, or a merge commit on GitHub): a squash merge collapses the item commits and loses their decision bullets. A hand-maintained log can be frozen as `.orca/decisions.archive.md`; the render appends it under `## Archived`.

Rule-shaped knowledge ("never install X via npm") goes in the report under **Knowledge worth promoting**, for you to commit to CLAUDE.md or real docs. Orca never writes CLAUDE.md.

## Stage agents

Seventeen agents ship in `agents/<stage>.md`, loaded as `orca:<stage>`. Each runs in its own context; stages pass context through artifact files.

| Stage | Role | Model | Effort | Configurable |
|---|---|---|---|---|
| `spec` | Explores the codebase; writes the spec and work breakdown | fable | high | ✓ |
| `spec-review-codex` | Courier driving the Codex spec review via `orca.sh codex` | sonnet | medium | |
| `spec-review-claude` | Performs the spec review itself | opus | high | |
| `plan` | Read-only planner for one item | fable | high | ✓ |
| `implement` | Builds one item in its worktree | opus | high | ✓ |
| `review-codex` | Courier driving the Codex item review via `orca.sh codex` | sonnet | medium | ✓ (`review`) |
| `review-claude` | Performs the item review itself | opus | high | ✓ (`review`) |
| `fix` | Applies review findings; escalates ones rooted in the plan, spec, or other items | opus | high | ✓ |
| `commit` | One Conventional Commit per item, carrying its decisions | sonnet | low | ✓ |
| `merge` | Serialized squash onto the integration branch; resolves conflicts | opus | high | ✓ |
| `integrate` | Verifies the assembled feature against the spec | opus | high | ✓ |
| `research` | Explores what an idea touches, for the interview, `/orca:iterate`, and `/orca:followup` | fable | high | ✓ (at next spawn) |
| `address` | Turns `/orca:review` comments into fixes and answers | opus | high | |
| `audit` | Reconciles a finished run against git, for `/orca:retry` and `/orca:followup` | opus | high | |
| `doctor` | Derives and proves `.orca/setup`, for `/orca:doctor` and `/orca:init` | opus | high | |
| `council` | One Claude seat of `/orca:council`; the model is the seat's | per seat | high | ✓ (`council` roster) |
| `council-codex` | Courier driving `/orca:council`'s Codex seat via `orca.sh codex` | sonnet | medium | |

The resolved reviewer picks both the item reviewer and the spec reviewer. The workflow's internal helper agents (reconciliation, escalation) are not configurable.
