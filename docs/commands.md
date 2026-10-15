# Commands

Every user-facing skill in detail. The [README](../README.md#commands) has the one-paragraph versions.

- [`/orca:run`](#orcafeature-idea)
- [`/orca:review`](#orcareview-branch)
- [`/orca:pr`](#orcapr-run)
- [`/orca:retry`](#orcaretry-run)
- [`/orca:followup`](#orcafollowup-run)
- [`/orca:iterate`](#orcaiterate-instructions)
- [`/orca:status`](#orcastatus-run)
- [`/orca:archive`](#orcaarchive-run)
- [`/orca:init`](#orcainit-path-or-clone-url)
- [`/orca:doctor`](#orcadoctor)
- [`/orca:config`](#orcaconfig-assignments--reset)

## `/orca:run <idea>`

A dispatcher over `.orca/` state. Triage offers the first match, never forcing it:

1. **An interrupted run** — a run directory whose `spec.md` records a workflow runId but has no `report.md`. Offers to resume from the journal: completed work replays instantly, only in-flight and remaining work runs live.
2. **A queued brief** — anything at the top level of `.orca/feat-briefs/`. Offers to run one, or to interview a new idea instead.
3. **Nothing waiting** — interviews the idea into a brief, then asks: run it now, or leave it queued?

### The interview

Turns a rough idea into a brief at `.orca/feat-briefs/<timestamp>-<slug>.md`. It first researches the subsystems the idea touches through the `orca:research` agent, then opens by reflecting the idea against the system as it exists. It is adversarial about scope: it pushes back, hunts for unstated non-goals, and makes you resolve ambiguities now, because the brief is the *entire* intent the run acts on.

A brief records **outcome**, **features**, **non-goals**, **inputs & outputs**, **constraints**, any direction decisions settled in the interview (binding on the spec), and two run controls:

- **Doubt rule** — on an ambiguity, prefer the smaller interpretation and cut scope (`prefer-smaller-scope`, default) or the more complete one (`prefer-complete`).
- **Breakdown checkpoint** — review the spec and work breakdown once before any code (`review-once`), or run straight through (`straight-through`, default).

The brief is *what and why*, never *how*: no work breakdown, interfaces, or file ownership — those come from the spec stage. Top-level briefs are ready; park unfinished ones in `.orca/feat-briefs/drafts/`. One brief is one run.

### The run

You are asked exactly:

1. **One confirmation** of the restated brief, plus the trunk branch. This authorizes everything that follows, and it is asked even if the brief was written seconds earlier.
2. **One optional checkpoint**, only if the brief opted in: approve the spec and work breakdown before any code.

After that nothing asks you anything. Ambiguities resolve against the spec and the doubt rule; what cannot be resolved becomes a `blocked` item in `report.md`, with the options you must choose between. See [Anatomy of a run](anatomy.md).

## `/orca:review [branch]`

Opens a finished deliverable in *your* editor before you land it. It discovers unmerged `feature/<slug>` branches (one → opens it; several → asks; a missing integration worktree → offers to re-add it) and starts a review session on the integration worktree: file list, side-by-side merge-base diffs, your LSP and colors.

- **nvim** — a new tmux window in your current session running [orca.nvim](https://github.com/miguelbacalhau/orca.nvim)'s `:OrcaReview`. Quit nvim (`:qa`) and the window closes, returning you to where you invoked it.
- **vscode** — [orca.vscode](https://github.com/miguelbacalhau/orca.vscode)'s review session, opened via `code --open-url`. Close the review window when done.

Without tmux (nvim path) or without a companion installed, it prints the command to run instead (`cd <worktree> && nvim "+OrcaReview"`, `cd <worktree> && code .` plus the palette command, or a `git difftool` fallback).

The `editor` (`nvim`|`vscode`|`none`) and `terminal` (`tmux`|`none`) config keys control this; see [Configuration](../README.md#configuration).

### Review comments round-trip

Comments you leave in the review persist to `.orca/review-notes/<key>.json` (`<key>` is the sanitized branch name).

On the nvim path the skill waits on the tmux window. When you quit nvim it reads the file and lays out each open comment with what it intends to do — fix (with a one-line approach), answer, decline with reasoning, or defer — and **asks** before acting. You can correct the plan, address now, resume the review, or leave the comments for later.

On consent, the `orca:address` agent works in the integration worktree: change requests are fixed with tests and committed (under the same no-attribution rules as run commits), questions are answered from the code. It writes `status`/`resolution` back into the notes file, and the next `:OrcaReview` shows them inline. Each round is appended to `report.md` under `## Review rounds`; a round whose verification fails marks the deliverable `unverified`. Editing a resolved comment re-opens it for the next round.

Comments left from vscode, a print-only session, or a dead session are picked up by the next `/orca:review`, which reports "N unaddressed comments". Both sides fail loudly on a notes schema version they don't support (`/orca:doctor`'s nvim check diagnoses the mismatch).

## `/orca:pr [run]`

Publishes a **delivered-but-unlanded run** (newest by default, or the one the argument names) as a GitHub pull request via `gh`. Every fact in the PR body comes from the run's `report.md`; for a branch no run produced, use plain `gh pr create`.

Guards: the report must say `**Deliverable state:** verified` and `## Blocked` must be `None`. Anything else is refused with a pointer to `/orca:run`'s resume or `/orca:retry`.

- **New PRs are always drafts.** Mark it ready on GitHub after your own pass. Refreshing an existing PR never changes its draft status.
- **Body shape:** the repo's `pull_request_template.md` if it has one; otherwise a plain-language summary of the problem and the change, **What changed**, **Testing**, and **How it works** / **Notes** only when needed — 200–350 words, grouped by outcome rather than by work item, with no orca vocabulary (item IDs, hashes, run paths, `/orca:*` pointers).
- **No attribution** in the title or body, enforced by the same marker scan as run commits.
- **One confirmation:** you see the exact title, body, base, and head before the push and PR creation. Re-running on an existing PR refreshes it.

It never merges, never edits the report, never touches the integration worktree.

## `/orca:retry [run]`

Finishes a finished run's unmet items **inside the same run** — same run directory, same spec, same integration branch.

1. Picks a finished run with leftovers (newest by default, or the argument).
2. Audits it with `orca:audit`: the report's claims reconciled against the spec's work breakdown and git.
3. Resolves every blocked item's recorded decision with you. This interview is required — a retry without new input would block the same way. You can also restore items the run cut autonomously, and a resolution may let a retried item amend code an earlier item already merged.
4. Appends your resolutions to `spec.md` as binding Decisions bullets, archives the superseded plans, reviews and report in place (`plans/<ID>.round<N>.md`, `reviews/prev<N>/`, `report.round<N>.md`), and relaunches the work loop over the unmet items only. Surviving item branches (including salvaged WIP commits) are resumed, not restarted.

The rewritten report keeps the whole-run picture, with a Prior rounds section. An *interrupted* run goes to `/orca:run`'s resume; a `clean` run has nothing to retry.

## `/orca:followup [run]`

Turns a finished run's *optional follow-ups* — deferred findings, known gaps, improvements reviews flagged without blocking — into a new brief.

It audits the run with `orca:audit` (which items verifiably merged, whether the deliverable branch still exists or already landed) and names any discrepancies. You choose which follow-ups ride along; the rest stay deferred in the old report. The result is a standard brief in `.orca/feat-briefs/`, building on the integration branch or the trunk depending on whether the deliverable landed, with the prior spec's Interfaces and Decisions as binding inputs. `/orca:run` runs it like any other brief; this skill never launches a run.

A run with unmet items is pointed at `/orca:retry` first; a run whose follow-up brief already exists is surfaced, not duplicated.

## `/orca:iterate [instructions]`

New work on a delivered, **still-unlanded** `feature/<slug>` branch, of any size, with the full spec → plan → implement → review → fix → commit → merge treatment — no new run, no full interview.

1. Picks a delivered-but-unlanded run.
2. One research agent validates the instructions against the system; a micro-interview confirms the restated change (at most 2–3 questions, often none).
3. `orca:spec` writes an **amendment** (`spec.amendment.md`) against a worktree at the branch tip. The delivered spec's Interfaces and Decisions bind it — it may extend them, or explicitly supersede them where the change calls for it. The amendment goes through the same spec review and revise round as a fresh run.
4. The new items are appended to `spec.md` under a dated iteration heading (continuing the W-id sequence), the old report is archived to `report.round<N>.md`, and the work loop runs over the new items on the same integration branch.

Routing: unmet items → `/orca:retry`; a landed or deleted branch → `/orca:followup`; an interrupted run or iteration → `/orca:run`'s resume; genuinely unrelated scope → `/orca:run`.

## `/orca:status [run]`

A strictly read-only dashboard answering "where was I?". It joins `.orca/` state (interrupted and unlaunched runs, finished runs and their leftovers, queued briefs) with git (unmerged deliverables, kept item branches, leftover `orca-*` worktrees, orphans from abandoned runs) into one screen grouped by next action, each state naming the skill that owns it. It prescribes cleanup commands where deletion is provably safe but never runs them. With an argument, only the matching run is shown.

Readiness questions — tooling, config, secrets, setup — belong to `/orca:doctor`, not here.

## `/orca:archive [run]`

Retires finished runs from triage and removes their git footprint. The run directory and report always stay.

A run is archivable only when its report exists, `## Blocked` is `None`, no live lease owns it, **every `feature/<slug>` branch attributed to it (integration and item) is merged into the trunk** or already gone, and every `orca-*` worktree it left is clean, unlocked, not your current directory, and not holding a run branch checked out elsewhere.

`triage archive --scan` reports each finished run as `ARCHIVABLE:` (with one `PRUNE:` line per worktree and branch it would remove) or `KEPT:` with a reason: `NOT_LANDED`, `WORKTREE_IN_USE`, `NOT_CLEAN`, `LEASE_LIVE`, `NO_TRUNK`. The skill shows both and asks before removing anything.

Archiving re-checks the gate, removes the worktrees and then the branches (never `--force`), and writes an `archived` marker beside `report.md` recording each removal and branch tip. An archived run shows as one `ARCHIVED:` line in triage, stays addressable by fragment, and `/orca:followup` can still pick it. `--undo` removes the marker and recreates the branches at their recorded tips.

## `/orca:init [path or clone URL]`

One-time, consent-per-step setup of the bare-repo-with-worktrees layout:

- **New repository** — bare init plus a default-branch worktree.
- **Clone a URL** — bare clone, fetch refspec fix (bare clones fetch nothing without it), default-branch worktree.
- **Convert an existing checkout** in place — `.git` becomes `.bare`, tracked files move into a `<branch>/` worktree, and **untracked and ignored files (`.env`s, caches) are carried over**. Every path changes, so re-point editors and terminals. Layout-only (no history, refs, or remotes touched) and reversible until the final cleanup step, which is confirmed separately. Requires a clean tree, no linked worktrees, and no submodules.

Every case ends by **root-linking** the default worktree's `.claude` and `CLAUDE.md` at the repo root, so a session started there gives every stage agent the checkout's conventions. It then offers (never defaults) `/orca:doctor`'s [provisioning pass](worktrees.md#provisioning).

Machine-gate failures (Codex, the review timeout) are `/orca:doctor`'s.

## `/orca:doctor`

Interactive, consent-per-step readiness on two axes: **machine and session tooling**, and **repo readiness** (whether a fresh worktree arrives provisioned). Diagnosis is free; it fixes only what was flagged:

- **Codex missing or stale** — points at the official install (`brew install codex` or release binaries; never npm).
- **Not authenticated** — `codex login`, verified with `codex login status`.
- **`codex exec` interface moved** — names the missing flags and whether the fix is a Codex upgrade or an orca update; offers `reviewer=claude` to unblock.
- **`BASH_MAX_TIMEOUT_MS` unset** — writes it into a settings `env` block (project or user level, your choice).
- **A stale orca status line** — older versions offered a `statusLine` block calling the retired `orca.sh statusline`; doctor offers to remove it. A status line that doesn't mention orca is never touched.

It reports the resolved reviewer. With codex absent it explains that runs use the Claude reviewer and offers to pin either choice. A codex gate failing while the reviewer is codex is always a failure to fix, never a silent switch.

Inside a repository it reads `orca.sh setup status`: `absent`, `current`, `drifted` (naming the manifests that changed), or `unstamped` (hand-written). Any but `current` earns an **offer** of the deep pass: the `orca:doctor` agent derives a `.orca/setup` script from the repo's own evidence and proves it in a throwaway worktree under `.orca/doctor/`; doctor re-runs the verification itself, shows you the script, and installs it only when you say so. See [Worktree provisioning](worktrees.md#provisioning).

Also offered, never defaulted: writing `bypassPermissions` as the repo's default mode, and checking the editor companions — [orca.nvim](https://github.com/miguelbacalhau/orca.nvim) when Neovim is on PATH, [orca.vscode](https://github.com/miguelbacalhau/orca.vscode) when `code` is. `BARE_REPO: FAIL` is routed to `/orca:init`.

## `/orca:config [assignments | reset]`

Per-repository overrides in `.orca/config`, applied at the **next** run launch (a running or resumed run keeps its launch-time config).

```bash
/orca:config                                # show the reviewer + effective table
/orca:config reviewer=claude                # pin the Claude reviewer
/orca:config reviewer=default               # unpin — back to detection
/orca:config plan.model=sonnet review.effort=high
/orca:config plan.model=default             # clear one field
/orca:config reset plan                     # clear one stage
/orca:config reset                          # clear everything (reviewer included)
```

- **`reviewer`** — `codex` or `claude`. Absent, each launch detects (codex on PATH at the minimum version → codex, else claude). Setting it pins the choice, so a broken codex becomes a pre-flight `FAIL` instead of a silent Claude run.
- **Stage model/effort** — models `haiku` | `sonnet` | `opus` | `fable`, efforts `low` | `medium` | `high` | `xhigh` | `max`. The `review` key applies to whichever reviewer agent is active: with codex it only changes the courier that drives Codex, not Codex itself. `fable` is the default for `spec`, `research`, and `plan`; on a plan without fable access, pin them with `/orca:config spec.model=opus research.model=opus plan.model=opus`.
- **`editor` / `terminal`** — for `/orca:review`.

The configurable stages and their defaults are in [Stage agents](anatomy.md#stage-agents). Overrides survive plugin updates.
