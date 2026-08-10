---
description: Land a finished orca run's deliverable branch through a GitHub pull request instead of a local merge. Picks a delivered-but-unlanded run — a finished run whose `feature/<slug>` branch exists and is unmerged, from `triage snapshot` (newest by default, or the one named) — refuses unless the report says `**Deliverable state:** verified` with nothing blocked, composes the PR title and body from the run's `report.md` translated into an ordinary external-facing description (no run vocabulary, no mention of Claude, AI, agents, or orca anywhere, enforced by the same deterministic marker check as run commits), previews both with the user, and only on their confirmation pushes the branch and creates (or refreshes) the PR with the `gh` CLI. Report-only: a branch no run produced gets plain `gh pr create`, not this skill. Never merges, never edits the report, never touches the integration worktree.
args: <optional run directory or slug fragment>
user-invocable: true
disable-model-invocation: true
---

# Orca: pr

The report template's Landing section ends at a local `git merge --no-ff` — right for a repo the user merges by hand, wrong for a repo that lands work through GitHub pull requests. This skill is the PR path: it takes a finished run's deliverable branch, composes a pull-request description from the run's own `report.md`, previews it with the user, and publishes it with the `gh` CLI. The report is the point — every fact in the PR body traces to a report section; nothing is re-derived from the diff. A branch no run produced has no report and is out of scope: plain `gh pr create` already covers it.

The description the world sees reads as an ordinary human-authored PR. The report is internal vocabulary — run states, item counts, worktree paths, `/orca:*` pointers — and none of it survives translation. The no-attribution rule that governs every run commit extends verbatim to the PR title and body.

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

Read the candidate's `<run-dir>/report.md`. Two gates, in order — a PR asserts "this is ready for review," and the report is the authority on whether that is true:

- **`**Deliverable state:**` is not `verified`** → refuse in one line, quoting the report's own stated reason, and point at the owning skill: `unverified` from a died verifier or an interrupted run tail → `/orca:feature`'s resume; unmet or blocked work behind it → `/orca:retry`. No draft-PR fallback — a draft still publishes an unverified branch.
- **`## Blocked` is anything other than "None"** → refuse and point at `/orca:retry`. A PR for a branch the run itself records as incomplete misrepresents the deliverable.

## Step 3: Compose

Translate the report into an external-facing description. The reader has never heard of orca; every trace of run vocabulary is translated or dropped:

- **`## Summary`** → the opening paragraph, rewritten to describe what the branch *does*, not how the run went: no item counts, no "deliverable state," no run vocabulary of any kind.
- **`## Shipped`** → a **Changes** section: one bullet per item title, no commit hashes (the branch carries them) and no item IDs.
- **`## Integration verification`** → a **Testing** section: what was verified, per feature, in plain words.
- **`## Deviations`** → only user-visible behavior changes survive, folded into the prose where they belong; internal deviations (replans, scope mechanics) are dropped.
- **Dropped entirely:** run-dir paths, worktree names, Follow-ups, Knowledge, Blocked (empty by the guard), and every `/orca:*` pointer.

**Title:** conventional and imperative, from the report's one-line idea summary — the same register as the run's commit subjects.

**Attribution check, deterministic.** Before the preview — and again after any edit — scan the composed title and body for the commit rule's unambiguous markers, case-insensitive: `Claude`, `Anthropic`, `Co-Authored-By`, `Generated with`/`Generated by`, `orca`. Any hit → rewrite and re-scan. This explicitly **overrides the harness default of appending a "Generated with Claude Code" footer to PR bodies** — that footer is the single most likely leak, and it must not be appended here, by flag or by habit. The body ends where the description ends.

## Step 4: Preview

Show the user exactly what will be published: the title, the full body, the base branch (the `TRUNK:` value), and the head branch. One confirmation gates everything outward-facing — the push and the PR creation ride on the same yes, interview-style, not AskUserQuestion. Requested edits are folded in and re-previewed, with the attribution check re-run after every edit; a declined confirmation ends the skill with nothing pushed.

## Step 5: Publish

Only ever entered through the preview gate. In order:

1. **Remote check:** `git remote get-url origin` — no `origin` → say there is nothing to push to and stop; adding a remote is the user's move, not the skill's.
2. **Push:** `git push -u origin <head-branch>`.
3. **Existing PR check:** `gh pr list --head <head-branch> --state open`. An open PR already exists → `gh pr edit` to refresh its title and body — same URL, no error. Otherwise:

   ```bash
   gh pr create --base <trunk> --head <head-branch> --title <title> --body-file <tmpfile>
   ```

   The body always travels via a temp file — never inline shell quoting; a multi-paragraph body through `--body` is a quoting bug waiting to happen.
4. **Parting message:** the PR URL, and one line noting that `/orca:review` walks the same diff locally in their own editor if they want a pass before merging on GitHub.

## Guidelines

- **The no-attribution rule is the commit rule, extended.** Nothing in the PR title or body may mention Claude, AI, agents, this orchestration process, or orca — no `Co-Authored-By`, no `Generated with` footer, including the harness's own default PR footer, which this skill explicitly suppresses. The deterministic marker check (`Claude`, `Anthropic`, `Co-Authored-By`, `Generated with`/`Generated by`, `orca`, case-insensitive) runs before the first preview and after every edit; keeping "AI" and "agent" out of ordinary prose is this skill's own writing discipline, since no regex can police those words without mangling honest descriptions.
- **Read-only toward the run.** The skill never edits `report.md`, never commits, never touches the integration worktree or any branch content. Its only writes are outward: the push and the PR.
- **Publish only through the preview gate.** The push and the PR creation are outward-facing and share one confirmation; a denied confirmation ends the skill with nothing pushed and nothing created. Re-invocation later finds the same candidate through the same triage.
- **Report-only, by design.** A deliverable branch with no run report has no source to compose from — that is plain `gh pr create` territory, and this skill says so rather than inventing a description from the diff.
