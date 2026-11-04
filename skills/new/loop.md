# Orca: objective — the phase loop

This file is read by `/orca:new` and `/orca:open` once a plan is installed, and by `/orca:loop` for the one phase it adds. It runs an objective's pending phases in order, one at a time, on the objective's branch in its one worktree. Each phase gets one implementer, kept alive for that phase: it implements, fixes every review round, and commits. Each review round gets a fresh reviewer. The phase is done when a round has no Critical/High finding and the commit stands.

You sequence it; you never edit code, and you never apply the gate yourself. After every implementer turn and every review, **`rounds next` reads the phase directory and prints the one next action** — you execute it. Counts come from its frame and finding titles from `rounds summary`, so you never read a review or response file whole. The one exception is a dispute: the disputed entries of that round's response, and each disputed finding's own entry in the review, read by its title.

You hold, from the skill that loaded this file: the objective directory `<dir>`, and from this session's `orca:worktree` `open` result its `worktree` and `reviewer`. When you no longer hold them (the open happened before a compaction, say), spawn `orca:worktree` in `open` mode again — it keeps this session's claim and returns them. Every spawn runs in the background: wait for its notification, and never fabricate a result. Shell calls go through `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh` with your own Bash tool. Later turns go to the implementer by `SendMessage` (a deferred tool: load it through ToolSearch when it appears only by name).

**The reviewer** is the held `reviewer`. When it is `fail`, or `codex` with the result's `codex: fail`, no phase can be reviewed: relay `codex_fix` (`/orca:doctor` walks every remediation; `/orca:config` picks another reviewer) and stop before any phase starts. Never switch reviewers on the user's behalf.

## Step 1: The next phase

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective digest <dir>
```

From its phase lines (`<P>  <state>  <title>`, where a done phase's state carries its commit and a blocked one's reads `blocked on D<n>`), take the `active` phase when there is one — an interrupted phase, resumed below — else the first `pending` one. A `blocked` phase stops the whole pass: while one is blocked no phase starts (`phase-start` refuses a pending phase with `PHASE_BLOCKED`, or `DECISION_OPEN` while a decision is open) — its decision is settled and the plan redone first. No phase to take, or a blocked one → the pass is over (Step 8).

When the skill that loaded this file named one phase (`/orca:loop`), take that phase only, and end the pass after it.

Below, `<P>` is the phase id and `<phase-dir>` is `<dir>/phases/<P>`.

## Step 2: Start the phase

Spawn `orca:worktree` in `phase-start` mode. Its task message: `phase-start <dir> <P>`, and the plugin root — `${CLAUDE_PLUGIN_ROOT}`, substituted. It marks the phase active, keeps or records its base, renders `<phase-dir>/brief.md` from the phase and the decisions it realizes, and provisions the worktree.

It returns `{status, worktree, branch, arrival, setup, base, cause, log, …}`. Hold `base` — the commit check's base for the whole phase (a resumed phase keeps its original one).

- `status: ok` → on.
- `status: setup_failed` / `setup_timeout` → relay `cause` in one line with the `log` path, and offer `/orca:doctor`. Provisioning is advisory: the phase runs, and the implementer's task message carries one more line, `Provisioning failed: <cause>`, so it knows dependencies may be missing.
- `status: failed` → relay `cause` in one line and stop the pass. `PHASE_ACTIVE` means another phase is mid-loop; `RESTART_PENDING` names a restarted phase that must run first — take that one instead; `PHASE_BLOCKED` / `DECISION_OPEN` mean the pass is stopped behind a decision — back to the discussion; `PHASE_STATE` / `NO_PHASE` mean the phase is not startable — the files changed under the pass.

## Step 3: The implementer

One `orca:loop-implement` per phase, **spawned on the first action that needs it** (Step 4) and continued by `SendMessage` until the phase's commit stands. Its task message:

```text
Worktree: <worktree>
Brief: <phase-dir>/brief.md
Rounds directory: <phase-dir>
Notes: <phase-dir>/notes.md
Base: <base>
Plugin root: ${CLAUDE_PLUGIN_ROOT}
```

(the plugin root substituted, absolute: the implementer records each response's checked tree through `orca.sh rounds tree`.)

Every turn it writes `<phase-dir>/responses/round-<N>.json` and keeps `notes.md` current, and returns `{status, questions, response}`. Never reuse a previous phase's implementer: the phase boundary is the context reset.

**A resumed phase** — Step 1 took an `active` one — gets a fresh implementer with the resume handoff, since the earlier one is gone with its session. Add to the task message: `Resumed: an earlier implementer worked this brief and is gone. Latest round: <N | none>` — `<N>` the highest `responses/round-<N>.json` in `<phase-dir>` (`ls`), `none` when there is none — and the request the first implementer action below calls for. **Every implementer request needs a live implementer.** A fix, checks, or revalidation request, an answer, settled declines, and the commit request (Step 6) all go to this phase's implementer by `SendMessage` — and when none is live (a resumed phase, or one the session lost), you spawn one first with the resume handoff, that request as its first message. So a resumed phase whose first action is `review N` spawns its implementer when the first request after the review comes, and one that resumes straight at `commit N` spawns it with the handoff and the commit request.

**A restarted phase** — one replanned after a block: `objective plan-accept` moved its earlier attempt's rounds under `<phase-dir>/superseded/<k>/`, and Step 1 took it as `pending` — gets a fresh implementer whose task message carries one more line, `Superseded: an earlier attempt at this phase, under a brief since replanned; its notes: <phase-dir>/superseded/<k>/notes.md`, with `<k>` the highest directory there (`ls <phase-dir>/superseded`). The attempt's changes may still be in the worktree; the implementer reconciles them with the new brief.

## Step 4: The rounds

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh rounds next <phase-dir>
```

One frame: `action`, `round` (`N` below), and the round's `gating`, `minor`, `out_of_scope` counts. Act on it, then run `rounds next` again — after every implementer turn, every review, and every recorded ruling:

- **`implement`** → spawn the implementer (Step 3): the brief is its request.
- **`fix N`** → a fix request naming `<phase-dir>/reviews/round-<N>.json`, a re-review to follow. Medium/Low ride along.
- **`fix-minor N`** → a fix request naming `<phase-dir>/reviews/round-<N>.json`, saying **no re-review follows**: fix or decline the Medium/Low findings. Those edits go unreviewed; the report lists them.
- **`fix-checks N`** → a checks request: the checks it reported are red, make them pass. When `rounds next` answers `fix-checks` again right after a checks request, the failure is not going away: name it in one line from `<phase-dir>/notes.md` (its "what is left"), and ask the user — **carry on with the checks red**, or **stop**. Carry on → record it, and the engine stops gating on exactly that failure (a different one later is new, and comes back as `fix-checks`):

  ```bash
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh rounds record <phase-dir> checks-override "<the user's reason>"
  ```

- **`review N`** → Step 5.
- **`ask-questions N`** → put the implementer's `questions` to the user, and send the answer back. A question you can answer from the conversation without guessing, answer yourself and say so. On a resumed phase you hold no questions: spawn the implementer with the handoff and the request round `N` was answering (the fix request for `reviews/round-<N>.json`, or for `N` = 0 the initial implement); it returns them again.
- **`ask-disputes N`** → the implementer disputes Critical/High findings of review `N`: a user decision for each (Rulings, below). Find the disputed ones in `<phase-dir>/responses/round-<N>.json` (`outcome` `disputed`, with the implementer's reason), and read each one's own entry in `reviews/round-<N>.json` by its title. Put each to the user: severity, title, `file:line`, the reviewer's body, and the implementer's reason.
  - **Decline it** (the user agrees with the implementer) → a settled decline, then tell the implementer which findings are settled:

    ```bash
    bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh rounds record <phase-dir> decline "<title>" "<file>" "<the user's reason, or the implementer's when the user just agreed>"
    ```

    `<file>` exactly as the review has it, empty for a cross-cutting finding.
  - **Fix it** → a fix request for that finding with the user's reasoning, re-review to follow, until it comes back `fixed`.
- **`stalled N`** → the gating findings are not shrinking, or a finding marked `fixed` is back. Tell the user what is recurring or not shrinking — this round's `gating` against the previous round's, and the titles from `rounds summary <phase-dir>/reviews/round-<N>.json` — and ask (Rulings, below):
  - **Continue** → `rounds record <phase-dir> continue <N> "<reason>"`; the next action follows.
  - **Commit anyway** → straight to Step 6's commit, without asking `rounds next`. The report marks the deliverable unverified.
  - **Stop** → the pass stops; the phase stays active, and `/orca:open` asks again.
- **`infeasible N`** → the implementer judged the phase unbuildable as briefed. Tell the user why, from `<phase-dir>/notes.md`. The phase needs a different direction, which is a decision: write it `open` (`**Source:** <P> (infeasible)`), block the phase on it (Rulings, "decide later"), and the pass stops.
- **`drifted N`** → the work tree changed since round `N`'s last file was written — an edit while the session was stopped, a hand edit, provisioning that left tracked files behind — so the checks and reviews on file are of a tree that is no longer there. The engine set round `N`'s stale response aside. Tell the user in one line, then send the implementer a **revalidation request** for round `N`: the tree changed outside the loop; re-answer round `N` over the tree as it is now — the full checks, and, for `N` ≥ 1, the dispositions of `reviews/round-<N>.json` again. On a resumed phase, spawn the implementer with the handoff and this request. Then `rounds next`: a review always follows before anything commits.
- **`commit N`** → Step 6.

A typed `FAIL:` from `rounds next` — `BAD_JSON` or `BAD_ROUNDS` naming a response file → send the implementer back once with the detail, to rewrite that file. A second failure, or one naming a review file, `BAD_DIR`, or anything else → relay the detail and stop the pass.

### Rulings

Every ruling the user makes on the spot — an answer to the implementer's questions, a dispute settled either way, a stall's continue or commit anyway — is a decision, **recorded twice**: once by `rounds record` where the action above names one (so the engine advances), and once as a decided entry in `<dir>/decisions.md` (so the objective remembers why). Append it with a heredoc; its id is one past the highest `## D<n>` in the file (`grep -oE '^## D[1-9][0-9]*' <dir>/decisions.md`), never the whole file read:

```markdown
## D<n> — <the question, one line>
**State:** decided
**Source:** <P> (implementer question) | <P> round <N> (disputed finding) | <P> round <N> (stall)
**Options:** <A> · <B>
**Decision:** <the user's choice>
**Why:** <the user's reason>
```

**Decide later** — offered at every one of these asks, for a user who does not want to settle it now — is the same entry with `**State:** open` and no `**Decision:**` line, then:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective phase-block <dir> <P> D<n>
```

**The pass stops** — every later phase waits too, since a later decision can change their scope. Tell the user the phase is blocked on `D<n>`; it can be settled now — follow `${CLAUDE_PLUGIN_ROOT}/skills/new/discussion.md`, then `${CLAUDE_PLUGIN_ROOT}/skills/new/planning.md`, as `/orca:open` would — or later through `/orca:open`. Once it is decided, the pending and blocked phases are replanned and confirmed before the loop runs again.

## Step 5: Review round N

1. `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets remove <worktree>` — the reviewer reads adversarial content and needs no credentials.
2. Spawn a fresh `orca:loop-review-<reviewer>`. Its task message: the worktree, the brief path `<phase-dir>/brief.md`, the artifact path `<phase-dir>/reviews/round-<N>.json`, the declines path `<phase-dir>/declines.md` (whether or not it exists yet), the rounds directory `<phase-dir>`, the base `<base>` — the review covers everything since it, committed or not — and, for codex, the plugin root, `${CLAUDE_PLUGIN_ROOT}` substituted.
3. `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh secrets place <worktree>` — on every path out of the round, the reviewer's failure included.

`secrets` failing `OUTSIDE_ROOT` means orca never placed secrets in that checkout — carry on. Any other typed `FAIL:` from `secrets remove` stops the round before the reviewer spawns: tell the user, and stop the pass.

The reviewer returns `{written, total, criticalHigh, reason}`. `written: false` → run the round once more, **all three steps again** — `secrets remove`, a fresh reviewer, `secrets place`, never a reviewer spawned while secrets are placed; a second failure → relay both reasons and ask the user: retry the round (the same three steps), or stop. Then `rounds next`.

## Step 6: Commit

Take a snapshot of exactly what the commit should hold — the tree `git add -A` would commit now, after the last checks and review — then send the commit request — to the live implementer, or to one spawned with the resume handoff and the commit request when none is (Step 3) — then judge the result against it. **The commit request names its round `N`**: the `N` of `commit N`, or of `stalled N` for a commit anyway. The implementer answers it in `responses/round-<N>.json` — creating it when the commit follows a clean review it never answered — so whatever the commit turn reports, a failed hook included, is round `N`'s, and the next review is `N+1`:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh loop snapshot <worktree> <phase-dir>
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh loop check <worktree> <base> <tree>
```

`<tree>` is the snapshot's `tree`. Run `loop snapshot` before **every** commit request — the first, each commit-only retry (`needs_commit` without a hook failure, `incomplete`, `violation_reset`), and a commit resumed in a new session: it records the tree in `<phase-dir>/snapshot` against the latest review round and returns that same tree (`kept=yes`) until a new review round exists, so a hook's change during a failed attempt is never blessed. It is retaken (`kept=no`) only after checks and a review round have run again (a failed hook's fix pass, a `content_reset`).

The commit request asks for the body to carry one `- chose <the decision> over <the other options>: <why>` line per decision the brief lists — the trunk's decision log is rendered from them.

**A red commit turn first.** Unless `check` says `accepted` or `diverged`, run `rounds next` before anything else. `fix-checks N` means the commit turn reported red checks — a commit hook failed — whatever `check` said: `needs_commit`, or `incomplete` when the branch already holds commits past the base (a salvaged `wip:` commit) and the hook left changes staged. That is never a commit problem: send the checks request, then record that the hook's fix needs a review — `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh rounds record <phase-dir> rereview <N>` — so `rounds next` answers `review N+1` (Step 5) instead of counting an edit no review has seen as reviewed; then follow `rounds next` to a fresh snapshot and the commit request again. Never resend the commit request over a red commit turn.

Otherwise, act on `check`'s `action`:

- `accepted` → the commit stands: `head` is its hash, `message.b64` its message. On to Step 7.
- `needs_commit` → no commit happened and the commit turn's checks are green (`rounds next` still says `commit N`): under a checks override, a hook failing on the very failure the user accepted still blocks every commit — ask the user; otherwise send the request back, naming that no commit happened.
- `incomplete` → the commit left files behind; send it back to commit them too.
- `violation_reset` → the message carried attribution and the commit was undone, changes left staged; send the request back with the warning that the message must not mention Claude, AI, agents, orca, or carry an attribution trailer.
- `content_reset` → the commit held changes made after the snapshot — a commit hook that rewrote code, or an edit during the commit turn — so nothing checked or reviewed them. The commit was undone with everything left staged. Tell the user what changed (`git -C <worktree> diff --cached --stat <tree>` is enough), send the implementer a checks request saying why — the commit was undone, and the staged changes need the checks run over them — then `rounds record <phase-dir> rereview <N>`, and follow `rounds next` (`review N+1`, Step 5) from there to a fresh snapshot and commit. A hook that only reformats converges on the next commit, since its output is now in the snapshot.
- `diverged` → the history under the base was rewritten. Stop the pass and show the user `git -C <worktree> log <base>`; never repair it yourself.

A second failure of any kind → ask the user how to proceed. Never commit, amend, or reset yourself.

## Step 7: Phase done

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective phase-done <dir> <P> <head>
```

It renders the phase's report entry and follow-ups into `<dir>/report.md` from the phase's files. Relay its frame in a line or two: the entry's heading (`headline.b64`, decoded), the follow-ups it added (`followups_added`), and — when `deliverable_state` reads `unverified` — that the deliverable is now unverified (a checks override, or a stall's commit anyway). A typed `FAIL:` → relay it and stop the pass; the commit stands, and the phase stays active for `/orca:open` to finish.

The phase's implementer is done. Back to Step 1 for the next phase.

## Step 8: The end of the pass

The pass ends when no phase is left to take, a phase blocks, or the user stops it; every stop leaves the files saying exactly where it is. Close with: the phases done this pass, each with its heading and commit; the follow-ups added, by count; any deliverable-state downgrade and why; and what comes next — the blocking decision, the active phase `/orca:open` resumes, or, when every phase is done, `/orca:review`, `/orca:pr`, `/orca:archive`, or more work through `/orca:open`.

## Guidelines

- You never edit code, never read a review or response file beyond what a dispute needs, and never edit `phases.md`, `report.md`, `declines.md`, `overrides`, or `trees` — the verbs own them. `decisions.md` is the one file this loop writes, entry by entry.
- Never decline a Critical/High finding on the user's behalf. Disputes, stalls, and the implementer's questions are the user's decisions; everything else the engine settles.
- Out-of-scope findings never reach the implementer as work: they become the phase's follow-ups, rendered by `phase-done`.
