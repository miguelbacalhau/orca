---
description: Drive light work through an implement → independent review → fix loop in an existing checkout until a review round reports no Critical/High finding, then commit it — no interview, no spec, no plan, no workflow, no new worktree or branch. This session stays the orchestrator and the user's point of contact; one `orca:loop-implement` agent implements, fixes every round, and commits, and each round's review runs in a fresh reviewer agent (the configured reviewer — Codex by default, Claude as fallback). The instructions become a short brief written from the conversation, unconfirmed; work that cannot be stated in a few lines without asking is `/orca:run`'s. The loop has no round cap and stops early only on a stall, which goes to the user, as does every disputed Critical/High finding. The commit is attribution-checked; when the branch is a run's deliverable, the loop records an entry in its report for `/orca:pr`.
args: <optional instructions>
user-invocable: true
disable-model-invocation: true
---

# Orca: loop

Light work that does not deserve a run still deserves an independent review. This skill is the shortest path that keeps one: an implementer builds the change in the checkout the user is already working in, a fresh reviewer attacks it, the implementer fixes what the reviewer found, and the loop repeats until a round comes back with no Critical/High — then the implementer commits it.

You — this session — sequence the loop, and you never edit code. Implementing, fixing, and committing happen in one `orca:loop-implement` agent, kept alive for the whole loop and continued with `SendMessage` (a deferred tool: load it through ToolSearch when it appears only by name), so it keeps its own context from round to round. Each review round runs in a fresh reviewer agent, so no round inherits another's blind spots. You stay the user's point of contact: the implementer cannot ask the user anything, so a question it returns comes to you, you ask, and the answer goes back by message.

Every spawn runs in the background: wait for its notification, and never fabricate a result. Shell calls go through `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh` with your own Bash tool, like `/orca:review` and `/orca:iterate` — the work loop's verb hook plays no part, so the loop needs no bypass mode.

## Step 1: Target

The checkout comes from the conversation (the worktree the user has been working in, or one they named), from `<args>`, or — when neither settles it — from asking. One target, an existing checkout on a branch. Never create a worktree or a branch: a change that needs one is the user's to set up, or `/orca:run`'s.

## Step 2: Reviewer

From inside the target checkout:

```bash
cd <worktree> && bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config validate
cd <worktree> && bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh preflight
```

A typed `FAIL:` from `config validate` stops the loop before anything is spent — point at `/orca:config`. From the preflight, read only the `REVIEWER:` and `CODEX:` lines; its other gates (the bare layout above all) are a run's requirements, not the loop's, and its exit status is not yours to act on. **The reviewer** is `config validate`'s `reviewer` when present, else the `REVIEWER:` value — the same resolution `/orca:iterate` uses. A `REVIEWER: FAIL` → `/orca:config`, stop. A codex reviewer with `CODEX: FAIL` → relay its remediation (`/orca:doctor` walks every one of them) and stop; never switch to the Claude reviewer on the user's behalf.

## Step 3: Start

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh loop start <worktree>
```

One frame: `worktree` (the checkout's top level — use it from here on), `branch`, `dirty`, `base`, `dir`, `run_dir`. A typed `FAIL:` stops the loop: `DETACHED` → the commit needs a branch, ask the user to check one out; `UNBORN` → there is no commit to build on; `NOT_GIT` → not a checkout; `LOOP_DIR_UNIGNORED` → git would commit (or already tracks) the loop's scratch, so the user must ignore `.orca/` there first; `KEY_COLLISION` → another branch's loop with the same key is live, or left behind by a dead session — relay the detail; `UNSAFE_LOOP_DIR` or `BAD_PATH` → relay the detail, never work around it.

`dirty=yes` → the checkout has uncommitted changes of the user's own, and the loop commits everything in the tree. Ask them to commit or stash those themselves, or stop. Never stash, commit, or discard them for the user. When they have, run `start` again — it empties the loop directory and reads the base afresh — and continue only on `dirty=no`.

Hold `base`, `dir`, and `run_dir` for the rest of the loop. **From here on, every exit — finished, stopped, or failed — ends at Step 9's cleanup.**

## Step 4: Brief

Write `<dir>/brief.md` from the conversation and `<args>`:

```markdown
# Loop brief

**Intent:** <one line: what the change is for>

**Acceptance:**
- <one to three lines, each a behavior the change must have>

**Scope:** <the files or area the change belongs in>
```

It is the reviewer's yardstick, so it says what the user asked for, not how to build it. It is not confirmed with the user — writing it is your judgment, and the user sees it in the closing summary. **When you cannot write it without asking** — the intent is unclear, the acceptance lines would be guesses, the change has many parts or open design questions — this is `/orca:run` work: say so, run Step 9's cleanup, and stop.

## Step 5: Implement

Spawn one `orca:loop-implement` agent. Its task message: the worktree, the brief path, the loop directory, and the base sha. Hold its agent id — every later turn of the loop goes to it by `SendMessage`.

Each of its turns ends with one JSON object: `status`, `questions`, `checks {commands, pass, failure}`, `findings [{title, outcome, reason}]`, `summary`. Read it after every turn:

- `needs_input` → put the `questions` to the user, then send the answer back. A question you can answer from the conversation without guessing, answer yourself and say so.
- `infeasible` → tell the user why, run Step 9's cleanup, and stop. The changes stay in the tree.
- `checks.pass: false` → send it back to make them pass. When it reports the same failure twice, or a failure that predates the change, ask the user: carry on with the checks red, or stop. Red checks block the commit like a Critical finding — unless the user chose to carry on: hold that as the **checks override** for the rest of the loop, naming the failure they accepted. From then on red checks no longer gate a round or the commit; a *different* failure from the one they accepted is new, and goes back to the implementer as above.

## Step 6: Review round N

Rounds count from 1. For each:

1. `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets remove <worktree>` — the reviewer reads adversarial content and needs no credentials.
2. Spawn a fresh `orca:loop-review-<reviewer>`. Its task message: the worktree, the brief path, the artifact path `<dir>/reviews/round-<N>.json`, the declines path `<dir>/declines.md` (whether or not it exists yet), and — for codex — the plugin root, `${CLAUDE_PLUGIN_ROOT}` substituted.
3. `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets place <worktree>` — on every path out of the round, the reviewer's failure included.

`secrets` failing `OUTSIDE_ROOT` means orca never placed secrets in that checkout — carry on. Any other typed `FAIL:` from `secrets remove` stops the round before the reviewer spawns: tell the user, and stop the loop.

The reviewer returns `{written, total, criticalHigh, reason}`. `written: false` → run the round once more; a second failure → relay both reasons and ask the user: retry the round, or stop.

## Step 7: Gate

Read `<dir>/reviews/round-<N>.json` yourself and split its findings:

- **Out of scope** — `fix_location` is `another work item`: defects outside the change, or work the brief does not ask for. They never gate the loop and never count toward a stall. Collect them for the closing summary, every round; never ask the implementer to fix them.
- **Gating** — every other finding whose `severity` is not recognizably `medium` or `low` (an unknown severity gates, as the reviewer counts it).
- **Medium/Low** — the rest. Every Medium/Low the implementer returns `declined`, in any round, is collected with its reason for the report and the closing summary; the round files that held them are deleted at cleanup, so nothing else keeps them.

Then:

**Gating findings in round N** → `SendMessage` a fix request naming `round-<N>.json`, re-review to follow; Medium/Low ride along. In its return, every gating finding is `fixed` or `disputed`:

- **Disputed** → put each to the user: the finding (severity, title, file:line, the reviewer's body) and the implementer's reason. The user decides. An accepted dispute is a **settled decline**: append it to `<dir>/declines.md` — `- <severity> · <title> · <file> — declined: <the user's reason, or the implementer's when the user just agreed>` — and send it to the implementer as settled. A rejected dispute goes back as a fix request for that finding, with the user's reasoning, until the implementer returns it `fixed`.
- **Stall check** — only from round 2, once the round's fixes are in. The loop has stalled when this round's gating count is not lower than the previous round's, or when a gating finding reappears that an earlier round's return marked `fixed` (same title and same file). Stalled → tell the user what is recurring or not shrinking and ask: **continue** (round N+1 as usual), **commit anyway** (Step 8 — the commit carries those findings, and the report says so), or **stop**.
- Then the implementer's checks (Step 5's handling), then round N+1.

**No gating findings and checks green** (or red under the checks override) → when Medium/Low findings remain, one fix request for them, saying no re-review follows. Its outcomes are `fixed` or `declined` with a reason; those edits are unreviewed, so they are listed in the closing summary as "fixed after the last review". If its checks come back red (beyond what the override accepted), send it back once; still red → ask the user: another review round, commit anyway, or stop. Then Step 8.

**No gating findings, checks red, no override** → the red checks gate: send them back as Step 5 says — which may itself end in the override — then round N+1. Under the override this branch never runs.

Never decline a Critical/High finding on the user's behalf, and never treat a reviewer's silence on a disputed finding as its withdrawal — only `declines.md` settles one.

## Step 8: Commit

Take a snapshot of exactly what the commit should hold — the tree `git add -A` would commit now, after the last checks and review — then `SendMessage` the commit request, then judge the result against it:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh loop snapshot <worktree> <dir>
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh loop check <worktree> <base> <tree>
```

`<tree>` is the snapshot's `tree`. **Hold it across every commit-only retry** — `needs_commit` without a hook failure, `incomplete`, `violation_reset` — and take a new one only after checks and a review round have run again (a failed hook's fix pass, a `content_reset`). A snapshot retaken between retries would bless whatever a hook changed during the failed attempt. A typed `LOOP_DIR_UNIGNORED` from `snapshot` means an ignore rule changed during the loop and the commit would carry the loop's scratch: tell the user, and ask them to ignore `.orca/` again before the commit request. Act on `action`:

- `accepted` → the commit stands: `head` is its hash, `message.b64` its message.
- `needs_commit` → no commit happened. When the implementer's return has `checks.pass: false`, a commit hook failed: that is red checks, not a commit problem — a fix pass, then a review round (Step 6), then a fresh snapshot and the commit request again. A hook that fails on the very failure the user accepted under the checks override still blocks every commit: ask the user. Otherwise send the request back, naming that no commit happened.
- `incomplete` → the commit left files behind; send it back to commit them too.
- `violation_reset` → the message carried attribution and the commit was undone, changes left staged; send the request back with the warning that the message must not mention Claude, AI, agents, orca, or carry an attribution trailer.
- `content_reset` → the commit held changes made after the snapshot — a commit hook that rewrote code, or an edit during the commit turn — so nothing checked or reviewed them. The commit was undone with everything left staged. Tell the user what changed (`git diff --cached --stat <tree>` — the staged state against the snapshot — is enough), then run the checks and a review round over it as usual, and commit again from a fresh snapshot. A hook that only reformats converges on the next commit, since its output is now in the snapshot.
- `diverged` → the history under the base was rewritten. Stop and show the user `git log` from the base; never repair it yourself.

A second failure of any kind → ask the user how to proceed. Never commit, amend, or reset yourself.

## Step 9: Report and finish

**The report entry.** When `run_dir` is not `-`, the branch is that run's deliverable, and `/orca:pr` composes its PR body from `<run_dir>/report.md` without reading the diff — so record the loop there. Keep a `## Loop rounds` section placed immediately before `## Review rounds` when that exists, else immediately before `## Landing`, so `/orca:review`'s own placement rule stays true. Create it on the first loop, append on later ones, one entry per loop:

```markdown
### <YYYY-MM-DD HH:MM> — <commit hash>

- Change: <the brief's intent, one line>
- Review: <reviewer>, <N> rounds, Critical/High fixed <n>
- Fixed after the last review: <Medium/Low titles — omit the line when none>
- Declined: <title — reason, per settled decline — omit the line when none>
- Left unfixed: <Medium/Low title — the implementer's reason, per Medium/Low it declined — omit the line when none>
- Checks: pass | fail — <the commands>
```

Timestamp via `date +"%Y-%m-%d %H:%M"`. When the commit went in with failing checks (the checks override, or "commit anyway") or unfixed Critical/High findings (a stall's "commit anyway") and `**Deliverable state:**` reads `verified`, rewrite that one line to `unverified — loop commit (<hash>) left checks failing` (or `… left Critical/High findings unfixed`). Never upgrade a state, and touch nothing else in the report. Only a committed loop gets an entry.

**Cleanup.** On every exit after Step 3, stops and failures included, remove the loop directory through the verb — never with `rm` yourself:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh loop finish <dir>
```

`<dir>` is exactly the path `start` printed. The verb re-proves it is the loop's own directory before deleting it; a typed `UNSAFE_LOOP_DIR` means something changed under `.orca/` during the loop — relay it and leave the path alone. Nothing else under `.orca/` is touched. A session that dies mid-loop leaves its changes in the tree; there is no resume.

**Close** with: the commit hash and subject (or why there is none), the rounds and the reviewer, what was fixed, the settled declines, the Medium/Low findings the implementer declined with its reasons, the out-of-scope findings — each worth the user's judgment, not this loop's — the Medium/Low fixed after the last review, the checks with their commands, and the brief the loop worked to. On a deliverable branch, any `Deliverable state` downgrade and why.

## Guidelines

- You never edit code, and never stash, reset, commit, or discard the user's own changes.
- Never decline a Critical/High finding on the user's behalf. Disputes and stalls are the user's decisions; everything else the loop settles itself.
- The loop's files are scratch: `.orca/loops/<key>/` exists only while the loop runs, and only `loop finish` removes it. Triage, `/orca:status`, and `/orca:archive` never learn about it.
- A change that outgrows the brief mid-loop — the implementer keeps asking design questions, findings keep landing outside the scope line — is `/orca:run` work. Say so, and let the user decide whether to stop.
