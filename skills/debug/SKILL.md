---
description: Drive a bug from symptom to a verified diagnosis — and, when the case's scope says so, to a committed fix — using a deterministic workflow over dedicated subagents: an autonomous orca debug run. A dispatcher over `.orca` state: triage offers to resume an interrupted run (found through its open case), to re-run an open case from `.orca/bug-cases/` with its ledger loaded, or — with nothing waiting — interviews the symptom into a durable case file with a scope rule (diagnose-only or diagnose-and-fix). The run gates hard on a deterministic reproduction script, fans out adversarial verification agents over ranked hypotheses in throwaway worktrees, converges the verdicts through a judge, and under diagnose-and-fix nests the standard work loop over a synthesized one-item contract to land the fix on a fix/<slug> branch — re-checked against the repro script, with exactly one internal retry. Requires the bare-repo-with-worktrees layout and a harness with the Workflow tool; the deliverable of a fixing run is a branch the user lands themselves. After one confirmation of the case and scope, nothing asks the user anything; a run that cannot reproduce, diagnose, or fix says so loudly and leaves the case open for a smarter re-run. Do not use for quick bugs the user can already point at, or when they only want an explanation.
args: <symptom>
user-invocable: true
disable-model-invocation: true
---

# Orca: debug

Coordinate autonomous debugging through isolated subagents. The main conversation handles everything interactive and cheap — triage, the interview, the pre-flights, the confirmation, and the final report — and delegates the long autonomous middle to **one deterministic workflow**: the bundled `debug-loop.workflow.js`, run through the Workflow tool. All heavy context — codebase exploration, instrumented runs, bisects, diffs — lives and dies inside subagents; the main conversation only reads artifact files and the workflow's structured result.

Debugging is a different shape of work from building: the outcome is unknown, the fan-out is over *hypotheses* rather than work items, convergence is a judgment call rather than a merge, and **reproduction is the currency** — every verdict, bisect, and fix check trades in one deterministic `repro.sh`. What carries over from the feature verb: worktree isolation (each hypothesis gets a throwaway worktree off the shared bare repo), artifact-file context passing, the journal-backed resume, and — under diagnose-and-fix — the entire plan/implement/review/fix/commit/merge/integrate machinery, reused via a nested work-loop call rather than reimplemented.

Two invariants shape everything below. The **repro gate is hard**: no deterministic reproduction means the run records the attempt and stops loudly — no evidence-only fallback, no diagnosis built on a bug that cannot be demonstrated. And **verdicts are three-valued** (`confirmed` / `refuted` / `inconclusive`): a `confirmed` requires observed evidence, an `inconclusive` is an honest open question that seeds the next run, and nothing manufactures confidence to have something to report.

## Step 0: Triage

This skill is a dispatcher over `.orca` state, and the **case file is the pivot**: a case stays in `.orca/bug-cases/<slug>/` until a run closes it, so every interrupted or unfinished run is reachable through its open case — location is status, exactly like feat-briefs. Resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir` and work the ordered checks below, discovering by listing, never by reading files to decide. Present the first hit, but never force it: every offer includes starting something new instead.

### 1. An interrupted run, reachable through its case

Discover everything waiting with one read-only script call:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/triage.sh discover
```

Each `CASE:` line is an open case. `interrupted` means its `case.md` carries a launch whose run directory has no `report.md` — the `RUNID:`/`ARGS:` lines that follow are the last persisted `**Workflow run:**`/`**Workflow args:**` pair (lines from several launches accumulate; the last pair is the live one), extracted byte-exact. `ready` means never launched, or the run finished and left the case open deliberately — check 2's territory. The same call emits `RUN:`/`BRIEF:` lines that belong to orca:feature's triage, and `DONE:` lines (finished runs) that belong to orca:retry's and orca:followup's — ignore those here.

The on-disk predicate cannot tell an interrupted run from one still executing — `report.md` only appears at the end — so before offering, check the run is not live: if this session's task list or background tasks show its workflow still running, it is in flight, not interrupted — report that and fall through. If another session could plausibly be driving it (the user would know), ask rather than assume.

To resume — never by re-running phases conversationally: take the `RUNID:` and `ARGS:` values the discovery emitted (the case's last persisted pair, extracted byte-exact), then re-invoke the Workflow tool exactly as Step 2 specifies — same `scriptPath`, the emitted args **verbatim**, plus `resumeFromRunId: "<RUNID>"`. Verbatim matters twice over: `.orca/config` may have changed since launch (the recorded `agents`/`reviewer` are the run's generation), and any changed value — including a substituted `fixTaskId` — changes agent prompts and makes completed stages re-run instead of replaying from the journal. A stale `fixTaskId` from a dead session is harmless: status updates are fail-soft and agents skip a failed TaskUpdate. Before resuming, reconcile leftover git state (`git worktree list`) only if the journal and the worktrees disagree — the case and fix worktrees from the launch are expected to still exist. Step 1's permissions pre-flight applies to a resume too; if the user declines, report that the case stays open in `bug-cases/` and resumable, and that enabling bypass (Shift+Tab) and re-invoking `/orca:debug` will rediscover it. When the resumed workflow completes, continue at Step 3.

### 2. An open case, ready to run

A case the discovery tagged `ready` — never launched, or its last run completed and left it open (`not-fixed`, `undiagnosed`, `no-repro`). Present the case slugs (several → list them and ask which) and offer to run the chosen one, or to interview a new symptom instead. This is where the ledger pays: a re-run loads `ledger.md`, so refuted hypotheses are never re-proposed and inconclusive ones are picked up first — the run starts smarter, not over.

A `<symptom>` argument alongside open cases: if it describes the same bug as an open case, fold it into that case as an amendment at the Step 1 confirmation; if it is a different bug, ask whether to run the open case anyway or interview the new symptom into its own case first.

### 3. Nothing waiting

Interview. Read `${CLAUDE_PLUGIN_ROOT}/skills/debug/interview.md` and follow it — it covers the discussion, reading the evidence the user points at, the early pre-flight, and writing the case files. It is loaded only now, so a pure run or resume invocation never carries the interview instructions. The `<symptom>` argument, if any, seeds the interview.

When the interview has written and approved its case, ask once: **run it now, or leave it open?** Run now → proceed to Step 1 with the just-written case; the restatement and confirmation run in full — the file, not the conversation, is the authorized intent. Leave it → tell the user the case is open in `.orca/bug-cases/` and a later `/orca:debug` will find it; end cleanly.

## Step 1: Confirm the case

The case file is the only place the bug's description was captured — once this step ends, the run is autonomous. Restate it: the symptom, expected behavior, reproduction steps (or "none known"), last known good, environment, what has been ruled out, and the **scope rule** — `diagnose-only` (the run ends after the judge, with a root-cause report and no fix branch) or `diagnose-and-fix` (the run continues into a nested work loop and lands a fix). Fold in any amendments from a symptom argument. Note the case's age from its `Created` line and warn when it is more than a few days old. If a hand-written case lacks the scope rule, apply the default — `diagnose-and-fix` — and state it in the restatement rather than asking. If the case has a ledger with prior-run entries, summarize what was already refuted or left inconclusive: it is part of what the user is confirming the run will build on.

### Environment pre-flight (script)

Run the bundled read-only pre-flight from the project root (reusing the interview's early pre-flight output if it ran in this same invocation; re-run only after a `FAIL` the user has since fixed):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh
```

The gates read exactly as they do for a feature run — `BARE_REPO`, `TRUNK_CANDIDATE` (confirm the trunk with the user; the case and fix branches are created from its tip), `REVIEWER` (hold the resolved value — it governs the fix tail's independent review exactly as it governs a feature run's), `CODEX`, `RESULT` — with one scope-sensitive reading: the codex machine gates exist for the **fix tail's** review, so on a `CODEX: FAIL` under scope `diagnose-and-fix`, stop and route to orca:doctor as usual; under `diagnose-only` — a run with no review stage anywhere — report the failure as a warning for future fixing runs and proceed. A `BARE_REPO: FAIL` always stops (route to orca:init), and a `REVIEWER: FAIL` always stops (route to orca:config).

The harness must expose the **Workflow tool**; without it, stop and say this skill requires a Claude Code harness with workflows. And when the resolved reviewer is codex **and** the scope is `diagnose-and-fix`, apply the live MCP gate: confirm `ToolSearch` resolves `select:mcp__plugin_orca_orca-codex__codex`, diagnosing a failure exactly as orca:feature does (project-level MCP config suppressing plugin servers — as of Claude Code 2.1.202 — versus a session predating the install; either way the user fixes the cause and starts a fresh session, and the case is untouched).

**Read the model config once, now.** Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config validate` while nothing has been spent: on success it emits `VALID:` followed by one-line JSON carrying the pinned `reviewer` (when set) and the canonical `agents` block (when non-empty); an absent config file emits `VALID: {}`. On a typed `FAIL:` line, stop, relay the field it names, and point at orca:config — never author or repair the file here. Hold the emitted values — and the reviewer resolved from them (pinned when present, else the preflight's `REVIEWER:` line) — for the rest of the run: the debug loop applies the four debug stages itself and passes the whole block **verbatim** into its nested work-loop call, where the feature stages except `spec` apply (a debug run never spawns a spec agent — the diagnose agent writes the fix contract) — one config, both verbs, each validating everything and applying only its own keys. No step re-reads the file.

### Permissions pre-flight

The run only stays autonomous in `bypassPermissions` mode — the same reasoning as a feature run (open-ended agent-chosen commands; prefix-glob allow-lists leak), and **diagnosis-only is no exception**: verify agents run arbitrary build, test, instrumentation, and `git bisect` commands. Confirm the mode before the confirmation; enable via Shift+Tab, `claude --dangerously-skip-permissions`, or the settings default, with the whole-session trade-off stated (a dedicated session is the clean choice).

If the user will not enable bypass now, do not fail the invocation — and here the story is simpler than a feature brief's: the case is durable in `bug-cases/` and is **not consumed at launch**, so an initial decline and a resume decline report the same thing — the case stays open, and enabling bypass and re-invoking `/orca:debug` will find it (and any interrupted run through it). End cleanly.

**The user's confirmation of the restated case and scope rule authorizes the run.** From this point on, never ask the user anything else.

## Step 2: Launch the debug loop

Create the run directory — `date +%Y%m%d-%H%M%S` for the timestamp; the `bug-` marker is fixed, telling debug runs from `feat-` runs in a bare `ls .orca/`:

```text
<repo-root>/.orca/YYYYMMDD-HHMMSS-bug-<slug>/
├── hypotheses.md      # ranked candidates (hypotheses-2.md on the retry round)
├── verdicts/          # one JSON per hypothesis
├── diagnosis.md       # the judge's root-cause statement
├── report.md          # final run report, written at the end
└── fix/               # the nested work loop's OWN run dir (diagnose-and-fix)
    ├── spec.md        # the synthesized one-item contract, written by the diagnose agent
    ├── plans/         # the fix item's plan
    └── reviews/       # the fix item's review rounds
```

Never write a top-level `spec.md` in a debug run dir: `orca:feature`'s triage detects its runs by globbing `.orca/*/spec.md` at depth 1, and the nested `fix/spec.md` staying one level down is what keeps the two verbs' triage from ever offering each other's runs.

Create the run's worktrees at the repo root, branched from the confirmed trunk's tip:

```bash
git worktree add <repo-root>/orca-bug-<slug> -b bug/<slug> <trunk-branch>          # always: the case worktree
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets place <repo-root>/orca-bug-<slug>
git worktree add <repo-root>/orca-fix-<slug> -b fix/<slug> <trunk-branch>          # diagnose-and-fix only: the fix integration worktree
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets place <repo-root>/orca-fix-<slug>    # diagnose-and-fix only
```

Each `place` links the user's secrets (`<repo-root>/.orca/secrets/`, the mirror-tree convention — the README documents it) into the fresh worktree as relative symlinks, so the repro and the fix's builds find their `.env`s. Idempotent and best-effort: a missing or empty secrets tree is a clean `OK` no-op, per-file problems are typed skips — relay any `UNIGNORED:` or `SKIPPED_EXISTS:` lines as one-way status, never a reason to stop.

The **case worktree** is where the repro is established, the hypothesize agent explores, and the workflow runs its git plumbing; the workflow creates the per-hypothesis worktrees (`orca-bug-<slug>-H1`, throwaway branches `bug/<slug>-H1`) off it itself and removes each after its verdict. The **fix integration worktree** is what the nested work loop merges into — `fix/<slug>` mirrors `feature/<slug>`: it reads as ordinary dev work and carries no orca trace in git, while the `orca-*` directory names stay local scratch. `worktree add -b` fails loudly on an existing branch; if `bug/<slug>` or `fix/<slug>` survives from an earlier interrupted run of **this same case**, reuse the existing worktree as-is instead of erroring — for anything else, pick a different slug.

**Refresh the project context** — the two machine-local hint files at the top level of `.orca/`, `map.md` (codebase map) and `decisions.md` (decision log), which the hypothesize and diagnose agents read first. Both are caches over what git already shares, stamped `**As of:** <short-sha>` in their headers, never committed. Against the confirmed trunk's tip (`git rev-parse --short <trunk>`): both present with stamps equal to the tip → skip; present but stale → spawn one `orca:context` agent to catch them up, with a task message that opens with a `Mode: catch-up` line and carries the two file paths, the repo root, and the trunk tip — the agent owns the maintenance rules (amend/prune the map from the diff, reconstruct missed decisions from full-history log, advance both stamps) and returns its summary as plain text; `map.md` missing → seed it with one exploration subagent (the same format, ~200-line cap, and stamp rules the context agent maintains — the only full-project sweep the design performs) and create `decisions.md` yourself with only a `# Decision log` header and the stamp. Non-fatal: a run with stale or missing context files still runs — the agents treat a missing file as a skippable hint.

**Create the fix status task** (diagnose-and-fix only, fail-soft): `TaskCreate` with subject `Fix — <case title>`; hold the id as `fixTaskId`. The nested work loop threads it into the fix item, whose stage agents advance it live. Hypothesis rows need no pre-creation — each verify agent creates and completes its own task (`H1 — <statement> · <verdict>`), also fail-soft. If task creation fails, launch anyway.

**Invoke the Workflow tool** (this skill instructing the call is the user's consent for workflow orchestration). All paths absolute — `${CLAUDE_PLUGIN_ROOT}` substitutes to the installed plugin root; the script rejects relative paths at launch:

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/scripts/debug-loop.workflow.js",
  args: {
    runDir: "<run-dir>",
    repoRoot: "<repo-root>",
    slug: "<slug>",
    caseDir: "<repo-root>/.orca/bug-cases/<slug>",
    scope: "<diagnose-only|diagnose-and-fix>",
    hasRepro: <true iff <case-dir>/repro.sh exists right now>,
    workLoopPath: "${CLAUDE_PLUGIN_ROOT}/scripts/work-loop.workflow.js",
    reviewer: "<codex|claude>",   // the resolved reviewer held since Step 1 — always present
    agents: { … },                // only when the held block is non-empty — passed verbatim
    fixTaskId: "<id>",            // only when the fix status task was created
    pluginRoot: "${CLAUDE_PLUGIN_ROOT}"  // the substituted absolute path — REQUIRED: the hypothesis worktree ritual and the nested work loop's worktree/commit/merge rituals run through the plugin-shipped CLI (scripts/orca.sh); a missing value refuses launch typed (NO_PLUGIN_ROOT)
  }
})
```

Pass `args` as real JSON values, never stringified. The script takes an atomic per-run lease at launch: an existing `<run-dir>/.lock` means another writer holds the run directory and the launch fails typed, naming the owner metadata inside. A resume (`resumeFromRunId`) replays the lease from the journal and is never blocked by its own leftover lock. On the typed refusal, confirm with the user that the holding run is dead before removing `<run-dir>/.lock` and relaunching — never delete a lease unconfirmed. Persist the resume handle immediately: append to the **case file** (`<case-dir>/case.md`) a `**Workflow run:** <runId>` line and a `**Workflow args:** <the args object as one-line JSON, exactly as passed>` line — the case file is the durable anchor (the run dir has no spec.md to carry them, and `diagnosis.md` is written far too late to be the record). The interruption that needs these lines — session death — erases the conversation, and `.orca/config` may drift; the recorded args, replayed verbatim, are what make a resume replay instead of re-run.

### What the workflow does

Phase by phase, every branch in script code: **Repro** — the `orca:reproduce` agent turns the case into `<case-dir>/repro.sh` under the git-bisect exit contract (0 = bug absent, 1–127 = present, 125 = cannot test; the workflow additionally normalizes exit 124 — GNU timeout — and anything >127 — signal deaths, OOM-kill 137 — to cannot-test, so a killed check is never read as "bug present"); a case that already has one gets it re-confirmed instead. The gate is deterministic — a zero-judgment checker runs the script and the workflow branches on the exit code, never on an agent's self-report — and it is hard: no repro → `{status: 'no-repro'}` and the run stops (exit 0 *and* exit 125 both fail it — a tree that cannot be tested is not a reproduction). **Hypothesize** — `orca:hypothesize` reads case, ledger, and evidence, then writes 1–8 ranked falsifiable candidates (aiming for 3 or more, never padding); refuted ledger entries are never re-proposed, inconclusive ones come first, failed-fix diffs are first-class evidence. **Verify** — one `orca:verify` agent per hypothesis in parallel, each in its own throwaway worktree, adversarially trying to *refute*; `confirmed` requires observed evidence; verdict JSONs land in `verdicts/` and each worktree is removed after its verdict. **Diagnose** — the `orca:diagnose` judge merges verdicts into `diagnosis.md`, or reports nothing-confirmed honestly (`{status: 'undiagnosed'}`); under `diagnose-only` the run returns `{status: 'diagnosed'}` here. **Fix** — the diagnose agent has written the synthesized one-item contract to `fix/spec.md`; the workflow nests a `workflow()` call to the standard work loop over it (`slug: fix-<slug>`, `integrationBranch: fix/<slug>`, the held reviewer and agents passed verbatim), so the fix is planned, implemented, independently reviewed, fixed, committed, merged, and integration-verified by exactly the machinery a feature run uses — including the regression test the contract requires. **Check** — the checker runs `repro.sh` in the fix integration worktree: exit 0 → `{status: 'fixed'}`, after which an `orca:context` agent folds the landed fix into the machine-local project context (map amended from the fix diff, the diagnosis appended to the decision log; distills artifacts only, never re-explores, non-fatal on failure) and its promotion suggestions ride the return; exit 125 → the tree cannot run the probe, and the run ends `{status: 'not-fixed'}` with `notes` marking the fix unverified rather than retrying on a false premise; still red → the failed attempt is reverted on the branch tip (its diff stays in history as evidence), hypotheses regenerate **once** (refuted ones excluded), one more verify→diagnose→fix cycle runs, and a second red check returns `{status: 'not-fixed'}`.

The workflow runs in the background; its `log()` lines are not visible mid-run ([anthropics/claude-code#74419](https://github.com/anthropics/claude-code/issues/74419)) — the live surface is the session task list (the fix row plus the verify agents' self-created hypothesis rows). **If the run is interrupted**, do not re-run phases conversationally: it stays resumable from its journal, rediscovered through the open case by a later `/orca:debug` (Step 0), or resumed the same way from this session.

## Step 3: Report

The workflow returns `{status, diagnosis?, fixBranch?, notes?, promotions?, hypothesesTested, tokensSpent}` — `fixBranch` is present whenever a fix attempt was committed, whatever the final status, `notes` carries what stopped a `no-repro` run or why a committed fix went unverified (repro exit 125), and `promotions` (fixed only) carries rule-shaped knowledge the context agent flagged for the human to promote into CLAUDE.md or the repo's real docs. Reconcile the status tasks first, fail-soft: on `fixed`, the fix task → `completed` with its subject restored to `Fix — <case title>`; on `not-fixed` — or any other status that returned a `fixBranch` — → `pending` with subject `✗ not fixed — Fix — <case title> — <short reason>`; on statuses without a returned `fixBranch` (nothing was ever committed), the fix task → `status: "deleted"` via TaskUpdate (the tool's only removal verb); any hypothesis row a dead verify agent left `in_progress` → completed with an ` · inconclusive` suffix.

Then, in order — the artifacts at hand are `diagnosis.md`, `verdicts/*.json`, `hypotheses*.md`, and (diagnose-and-fix) the nested run's `fix/spec.md`, `fix/plans/`, and its returned values; do not re-explore beyond them:

1. **Write `<run-dir>/report.md`** — the durable record (`date +"%Y-%m-%d %H:%M"` for the timestamp):

```markdown
# Report: <case title>

**Run:** <run-dir>
**Completed:** <YYYY-MM-DD HH:MM>
**Status:** fixed | not-fixed | diagnosed | undiagnosed | no-repro
**Case:** closed — archived in this run dir | open — `.orca/bug-cases/<slug>/`
**Deliverable:** `fix/<slug>` <!-- fixed only -->

## Diagnosis

<The root-cause statement from diagnosis.md, or what stopped short of one: the repro gate, or nothing confirmed.>

## Hypotheses tested

| ID | Hypothesis | Verdict |
| -- | ---------- | ------- |

## Fix

<Fixed: the shipped commits and the regression test, from the nested run's values and plan. Not-fixed — or any status with a returned `fixBranch`: each attempt and where its repro check failed or went unverified (the returned `notes`) — the diffs stay in the history of `fix/<slug>` as evidence. Diagnose-only: "not in scope". Otherwise (no `fixBranch`): "not reached".>

## Follow-ups

- <Inconclusive hypotheses and the experiment that would decide each; deviations recorded in the fix plan; anything the diagnosis flagged.>

## Knowledge worth promoting

- <From the returned `promotions` (fixed only): rules or docs the context agent flagged as belonging in CLAUDE.md or the repo's real documentation — the human commits them under their own name; orca never writes CLAUDE.md. "None" otherwise.>

## Landing  <!-- fixed only -->

The fix — regression test included — is the `fix/<slug>` branch, built in the fix integration worktree. Walk the diff in your own editor first with `/orca:review`, then land it from your own worktree with `git merge --no-ff fix/<slug>`, then optionally push.
```

2. **Append the run's outcomes to `<case-dir>/ledger.md`** — the append-only memory that makes the next run converge: a `## Run YYYYMMDD-HHMMSS-bug-<slug> — <status>` section with one line per hypothesis tested (id, statement, verdict, evidence pointer into the run dir or `evidence/`), one line per fix attempt (the `fix/<slug>` ref and its repro-check outcome), and on `no-repro` a line recording what reproduction attempt failed (from the returned `notes`). Never rewrite or delete prior entries.

3. **Close or keep the case.** On `fixed` or `diagnosed`, the case is done: `mv <case-dir> <run-dir>/case` — the whole directory, ledger and evidence included, archived with the run that closed it; `bug-cases/` holding only open cases is what keeps triage honest. On `not-fixed`, `undiagnosed`, or `no-repro`, the case **stays open**, ledger appended — state explicitly that a later `/orca:debug` will find it and start smarter: refuted hypotheses excluded, inconclusive ones first, failed-fix diffs and the recorded repro attempt as evidence.

4. **Clean up worktrees**, best-effort: remove the case worktree and its `bug/<slug>` branch on every terminal status (`git worktree remove` + `branch -D`; any hypothesis worktree a dead verify agent left behind too). Remove the fix worktree and `fix/<slug>` **only when the branch holds no commits beyond its base** — on `fixed` both stay (the deliverable, like a feature run's integration worktree), and after a failed committed attempt both stay as evidence the ledger points at.

Finally, give the user a short spoken summary — status first, then the diagnosis in a sentence, hypotheses tested with their verdicts, the fix and its regression test with the landing command (or the case-stays-open line), tokens spent, and the path to `report.md`.

## Guidelines

- The main conversation never reproduces, explores, instruments, or fixes anything itself. If you catch yourself reading source or running the bug in the main context, delegate — the interview's evidence reading (stack traces, logs the user points at) is the one deliberate exception.
- Each stage is a dedicated subagent type — `orca:reproduce`, `orca:hypothesize`, `orca:verify`, `orca:diagnose`, plus the standard stage agents inside the nested fix tail — spawned by the workflow with only per-phase values; the heavy instructions live in the agent definitions and never enter the main context.
- State lives in files and the workflow journal: the case file (with the persisted runId and args lines) anchors resume; the ledger is append-only cross-run memory; `report.md` is the outcome. Mid-run state is the journal — never re-run phases conversationally.
- Context passes between stages through artifact files — hypotheses file, verdict JSONs, `diagnosis.md`, the synthesized `fix/spec.md` — never relayed summaries. Structured returns exist for the workflow's control flow only.
- Worktree discipline: hypothesis worktrees are throwaway and never merge; only the nested merge agent writes `fix/<slug>`, inside the fix integration worktree; the run never reads or writes the user's worktrees.
- No commit anywhere in the run mentions Claude, AI, agents, orca, or the user — the nested work loop enforces its attribution check on every fix-tail commit, merge commits included.
- If a run is abandoned, clean up `orca-bug-<slug>*` / `orca-fix-<slug>` worktrees and `bug/<slug>*` / `fix/<slug>*` branches via `git worktree list` — but prefer resuming through the open case.
- After the Step 1 confirmation the run never waits on the user: no approval requests, no clarifying questions. What the run cannot decide lands in the report and the ledger, and the case stays open.
- Keep the user informed at phase transitions with one or two one-way status lines; inform, never ask.
