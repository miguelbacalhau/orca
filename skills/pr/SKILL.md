---
description: Land a finished orca run's deliverable branch through a GitHub pull request instead of a local merge. Picks a delivered-but-unlanded run — a finished run whose `feature/<slug>` branch exists and is unmerged, from `triage snapshot` (newest by default, or the one named) — refuses unless the report says `**Deliverable state:** verified` with nothing blocked, composes the PR title and body from the run's `report.md` and `brief.md` into an ordinary external-facing description with a fixed shape — the repo's own `pull_request_template.md` when it has one, otherwise a three-section skeleton (problem, what changed, testing) under a word budget and a plain-language register (no run vocabulary, no mention of Claude, AI, agents, or orca anywhere, enforced by the same deterministic marker check as run commits), previews both with the user, and only on their confirmation pushes the branch and creates the PR — always as a **draft**, for the user to mark ready on GitHub once they have read it — or refreshes an existing one, with the `gh` CLI. Report-only: a branch no run produced gets plain `gh pr create`, not this skill. Never merges, never edits the report, never touches the integration worktree.
args: <optional run directory or slug fragment>
user-invocable: true
disable-model-invocation: true
---

# Orca: pr

The report template's Landing section ends at a local `git merge --no-ff` — right for a repo the user merges by hand, wrong for a repo that lands work through GitHub pull requests. This skill is the PR path: it takes a finished run's deliverable branch, composes a pull-request description from the run's own artifacts, previews it with the user, and publishes it with the `gh` CLI. The artifacts are the point — every fact in the PR body traces to a section of the run's `report.md` or `brief.md`; nothing is re-derived from the diff. A branch no run produced has no report and is out of scope: plain `gh pr create` already covers it.

The description the world sees reads as an ordinary human-authored PR: the same shape every time, in plain language, opening on the problem and closing on how it was checked. The report is internal vocabulary — run states, item counts, worktree paths, `/orca:*` pointers — and none of it survives translation, nor does the run's item-by-item shape. The no-attribution rule that governs every run commit extends verbatim to the PR title and body.

**New PRs are always drafts.** Two different readinesses are in play, and the skill can only vouch for one. The guard below settles *run* readiness — the run finished and verified its own work. It cannot settle *social* readiness: at the moment this skill runs, no human has read the diff. A ready PR announces the opposite — auto-requesting the CODEOWNERS reviewers, notifying the team, releasing whatever CI and merge automation keys on non-draft — for a branch nobody has looked at. So the PR goes up as a draft and the user marks it ready on GitHub after their own pass, which is what the parting pointer at `/orca:review` has always been for. There is no flag: the wrong default in this direction costs one click, and in the other direction it costs a notification that cannot be recalled.

## Step 1: Triage

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh triage snapshot
```

— with `--run <argument>` when one was given. (`FAIL: NOT_GIT` → nothing here to publish; say so and stop.)

The candidate set is exact and computed by the script, never re-derived conversationally: a `DONE:` run whose run directory appears as the join field of a `BRANCH:` line with state `unmerged` — delivered, not yet landed. Read `TRUNK:` as the PR's base branch and the joined `BRANCH:` ref as its head. Triage in the house style:

- **One candidate** → proceed with it.
- **Several, no argument** → default to the newest (run-dir names are timestamped; the last `DONE:` line), name the choice, and offer the others as a picker — offer, never force.
- **An argument** → the `MATCH:` line names the run; `MISS:` is a loud miss — list the `CANDIDATE:` lines, never guess.
- **None** → say what was found instead, and name the skill that owns that state: the branch exists but reads `merged` (already landed — nothing to do), the run is `RUN: interrupted` (no report yet — `/orca:feature` resumes it), or nothing has been delivered at all (`/orca:feature`, `/orca:debug`). A `DONE:` run whose branch is gone was landed and pruned; say that too.
- **No `TRUNK:` line, or the branch reads `unknown`** → the base branch cannot be determined (detached or unset bare-repo HEAD); a PR needs a base, so say so and stop rather than guessing one.

Carry forward the run directory, the head branch, and the trunk, exactly as emitted.

## Step 2: Guard

Read the candidate's `<run-dir>/report.md`. Two gates, in order — even a draft PR asserts "the work is finished," and the report is the authority on whether that is true:

- **`**Deliverable state:**` is not `verified`** → refuse in one line, quoting the report's own stated reason, and point at the owning skill: `unverified` from a died verifier or an interrupted run tail → `/orca:feature`'s resume; unmet or blocked work behind it → `/orca:retry`. Draft status is no fallback here — publishing as a draft is this skill's unconditional default, not an escape hatch, and it still pushes an unverified branch under a description claiming work the run never verified.
- **`## Blocked` is anything other than "None"** → refuse and point at `/orca:retry`. A PR for a branch the run itself records as incomplete misrepresents the deliverable.

## Step 3: Compose

Read `<run-dir>/brief.md` alongside the `report.md` already in hand. The report is the authority on what shipped; the brief's `## Outcome` and `## Direction` are the only record of what was missing or wrong *before* it did, and a description that opens on the problem is the one a reviewer can actually follow. Nothing else is read — not the diff, not the plans, not the spec. A run with no `brief.md` still composes: the opening paragraph carries only what the branch does, which is what the report alone supports. Never invent a problem statement the artifacts do not contain.

The reader has never heard of orca, so run vocabulary is translated or dropped — and so is the run's *shape*. Work items are the run's unit of parallelism, not the reader's unit of understanding: a nine-item run does not become nine bullets. Group by outcome, several items serving one visible change to one bullet.

**Dropped entirely:** item IDs, commit hashes (the branch carries them), item counts and "deliverable state", run-dir and worktree paths, Follow-ups, Knowledge, Blocked (empty by the guard), internal deviations (replans, scope mechanics), and every `/orca:*` pointer. A deviation survives only where it changed user-visible behavior, folded into the prose where it belongs.

**Title:** conventional and imperative, from the report's one-line idea summary — the same register as the run's commit subjects.

### The repo's own template wins

A repo that ships a pull-request template has already decided what its PR bodies look like, and that decision outranks this skill's default:

```bash
ls .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE.md \
   pull_request_template.md PULL_REQUEST_TEMPLATE.md \
   docs/pull_request_template.md docs/PULL_REQUEST_TEMPLATE.md 2>/dev/null
ls -d .github/PULL_REQUEST_TEMPLATE 2>/dev/null
```

- **One file** → fill it. Keep its headings, their order, and its checklists verbatim; strip its HTML comments, which are instructions to the author rather than body text. Leave a checkbox unchecked unless the report states the thing was actually done. A section the artifacts cannot answer gets one honest line, never an invented one; a section that plainly does not apply is left empty rather than padded. Add no heading the template does not have — anything left over goes in the closest section that fits, or is dropped. The budget and register below still govern what goes inside their headings.
- **A `PULL_REQUEST_TEMPLATE/` directory** → the repo expects a human to pick among named templates. Use the default skeleton, and name the available templates in the preview so the user can ask for one; choosing for them is not this skill's call.
- **Neither** → the default skeleton.

### The default skeleton

Three sections are fixed and two are conditional — a one-line bugfix must not arrive as a five-heading document.

```markdown
<One paragraph, two to four sentences, no heading: what was wrong or
missing before, then what this branch does about it. Plain language — a
reader who has never touched this area follows it without asking a
question.>

## What changed

- <One bullet per change a reader would notice, three to seven in all,
  grouped by outcome rather than by work item.>

## Testing

- <What was checked and how it came out, one line per claim, in the
  words a teammate would use.>

## How it works

<Only when the approach is not obvious from the diff: two to four
sentences on the mechanism a reviewer needs to follow it. Omit the
section otherwise.>

## Notes

<Only when there is something: behavior existing users will feel
differently, a migration or config step, scope deliberately left out.
Omit the section otherwise.>
```

**Budget:** 200–350 words for the whole body, 500 the hard ceiling. Over it means the opening paragraph is doing too much, or the bullets are tracking work items instead of outcomes.

**Register:** short sentences, one idea per bullet. Name things the way the repo's own code and docs name them, and expand an acronym the first time it appears. Write "the export retries when the API returns 429", not "the implementation introduces a retry mechanism whereby". State what the change does, never how hard it was.

### A worked example

Title: `fix: keep scheduled exports running when the reporting API rate-limits`

```markdown
Nightly exports have been failing about twice a week. When the reporting
API returned 429, the export worker treated it as a hard error, dropped
the job, and left the customer with no file and no warning. This branch
makes the worker wait and retry, and tells the customer when a file is
genuinely late.

## What changed

- The export worker retries a rate-limited request up to five times,
  backing off from one second to about thirty, and respects a
  `Retry-After` header when the API sends one.
- A job that still fails after those retries is marked `delayed` rather
  than `failed`, and the next scheduled run picks it up.
- Customers get a "your export is running late" email once a job has
  been delayed for more than an hour. Previously they got nothing.
- The admin job list shows the delayed state and the attempt count.

## Testing

- Unit tests cover the backoff schedule, the `Retry-After` path, and the
  move to `delayed` after the last attempt.
- Ran the worker against a stub API that returns 429 for the first three
  calls: the export completed on the fourth, with no duplicated rows.
- Replayed last Tuesday's failed job against staging; it finished in
  four minutes.

## Notes

- The retry ceiling is `EXPORT_MAX_ATTEMPTS`, default 5. Existing
  deployments need no change.
- Only the reporting API is covered. The billing export has the same
  problem and is untouched here.
```

**Attribution check, deterministic.** Before the preview — and again after any edit — scan the composed title and body for the commit rule's unambiguous markers, case-insensitive: `Claude`, `Anthropic`, `Co-Authored-By`, `Generated with`/`Generated by`, `orca`. Any hit → rewrite and re-scan. This explicitly **overrides the harness default of appending a "Generated with Claude Code" footer to PR bodies** — that footer is the single most likely leak, and it must not be appended here, by flag or by habit. The body ends where the description ends.

## Step 4: Preview

Show the user exactly what will be published: the title, the full body, the base branch (the `TRUNK:` value), the head branch, which shape the body follows (the repo's own template, named, or the default skeleton), and — on the create path — that it goes up as a draft. Where a `PULL_REQUEST_TEMPLATE/` directory exists, name the templates it holds so the user can ask for one. One confirmation gates everything outward-facing — the push and the PR creation ride on the same yes, interview-style, not AskUserQuestion. Requested edits are folded in and re-previewed, with the attribution check re-run after every edit; a declined confirmation ends the skill with nothing pushed.

## Step 5: Publish

Only ever entered through the preview gate. In order:

1. **Remote check:** `git remote get-url origin` — no `origin` → say there is nothing to push to and stop; adding a remote is the user's move, not the skill's.
2. **Push:** `git push -u origin <head-branch>`.
3. **Existing PR check:** `gh pr list --head <head-branch> --state open` (drafts are listed too — a draft is an open PR). An open PR already exists → `gh pr edit` to refresh its title and body — same URL, no error, **and draft status untouched**. Otherwise:

   ```bash
   gh pr create --draft --base <trunk> --head <head-branch> --title <title> --body-file <tmpfile>
   ```

   The body always travels via a temp file — never inline shell quoting; a multi-paragraph body through `--body` is a quoting bug waiting to happen.

   **Draft is a creation-time choice only.** The refresh path never moves draft status in either direction, and `gh pr edit` cannot — that is `gh pr ready` / `gh pr ready --undo`, and neither belongs here. The user marks a PR ready when they have read it; a later refresh (after `/orca:retry`, say) must not undo that. Never "restore" the default by demoting a ready PR back to draft.
4. **Parting message:** the PR URL, that it went up as a draft for them to mark ready on GitHub once they have had their pass (omit on the refresh path, which left the status alone), and one line noting that `/orca:review` walks the same diff locally in their own editor if they want that pass before promoting it.

## Guidelines

- **The no-attribution rule is the commit rule, extended.** Nothing in the PR title or body may mention Claude, AI, agents, this orchestration process, or orca — no `Co-Authored-By`, no `Generated with` footer, including the harness's own default PR footer, which this skill explicitly suppresses. The deterministic marker check (`Claude`, `Anthropic`, `Co-Authored-By`, `Generated with`/`Generated by`, `orca`, case-insensitive) runs before the first preview and after every edit; keeping "AI" and "agent" out of ordinary prose is this skill's own writing discipline, since no regex can police those words without mangling honest descriptions.
- **One shape, every time, under a budget.** The body is not composed freehand: it fills the repo's own `pull_request_template.md` where one exists, and the default skeleton otherwise — problem paragraph, **What changed**, **Testing**, with **How it works** and **Notes** only when they earn their place. 200–350 words, 500 the ceiling. Verbosity here comes from mirroring the run's internals: a bullet per work item, a line per spec feature, counts and states the reader has no use for. Group by outcome instead, and say what the change does in the words a teammate would use.
- **Draft on create, hands off on refresh.** Every PR this skill opens is a draft, unconditionally — no flag, no `.orca/config` key: the choice is the same on every invocation, so there is nothing to configure. Promotion is the user's, on GitHub, after their own pass. Should `gh pr create --draft` be rejected outright (drafts unavailable on the plan or the GitHub Enterprise Server version), fail loudly and say so — never silently retry without the flag. That retry would publish a ready, reviewer-notifying PR the user's one confirmation did not cover; opening it by hand is their call to make.
- **Read-only toward the run.** The skill never edits `report.md`, never commits, never touches the integration worktree or any branch content. Its only writes are outward: the push and the PR.
- **Publish only through the preview gate.** The push and the PR creation are outward-facing and share one confirmation; a denied confirmation ends the skill with nothing pushed and nothing created. Re-invocation later finds the same candidate through the same triage.
- **Report-only, by design.** A deliverable branch with no run report has no source to compose from — that is plain `gh pr create` territory, and this skill says so rather than inventing a description from the diff.
