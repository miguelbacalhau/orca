---
description: Add one small phase to this session's orca objective and run it now — no planner, no plan review, no confirmation. Works only inside an objective this session opened with `/orca:new` or `/orca:open`; anywhere else it refuses and points at them, and it refuses while a phase is mid-loop or blocked, or a decision is open. The instructions become a short phase entry written from the conversation, unconfirmed; work that cannot be stated in a few lines without asking goes to the objective's discussion instead. The phase then runs through the objective's phase loop in its worktree: one `orca:objective-implement` agent implements, fixes every round, and commits, each round's review runs in a fresh reviewer agent (Codex by default, Claude as fallback), and the round engine decides every next step until a round reports no Critical/High finding. A final verification of the whole branch follows, and a regression it finds becomes one more phase. Disputed Critical/High findings, stalls, and the implementer's questions go to the user and are recorded as decisions. The commit is attribution-checked, and the phase's entry and follow-ups land in the objective's report.
args: <optional instructions>
user-invocable: true
disable-model-invocation: true
---

# Orca: loop

A small change inside an objective still deserves an independent review. This skill is the shortest path that keeps one: it writes the change as one phase of this session's objective and runs it through the objective's phase loop — an implementer builds it in the objective's worktree, a fresh reviewer attacks it each round, and the round engine decides what happens next until a round comes back with no Critical/High and the commit stands.

You — this session — write the phase entry and sequence the loop; you never edit code. Shell calls go through `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh` with your own Bash tool — the work loop's verb hook plays no part, so the loop needs no bypass mode.

## Step 1: Gate

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective current "$PWD"
```

One frame: `dir`, the objective this session owns, or `none`.

- `none` → refuse in one line: `/orca:loop` works inside an objective — `/orca:new <idea>` or `/orca:open`. Stop. (`NO_SESSION_ID` reads the same way: this session cannot own one.)
- Otherwise, read this objective's line from `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective list "$PWD"` (the one whose dir is `<dir>`):
  - state `active` → a phase is mid-loop: refuse — finish it first; `/orca:open` continues it. Stop.
  - `open:` above 0 → a decision is open: refuse — settle it first, in the objective's discussion (`/orca:open`). Stop.
  - `blocked:` above 0 → a phase waits on a decision, and no phase runs until it is settled and the plan redone: refuse — `/orca:open` takes it to the discussion. Stop.

Hold `<dir>`. The worktree and the reviewer come from this session's open (the `orca:objective-open` result); `${CLAUDE_PLUGIN_ROOT}/skills/new/loop.md` says what to do when you no longer hold them.

## Step 2: The phase

Write the phase entry from the conversation and `<args>` into a scratch file outside the objective (`mktemp "${TMPDIR:-/tmp}/orca-phase.XXXXXX"`). Head it `## P1`: `phase-add` gives it the next free id and names that id in its frame.

```markdown
## P1 — <title, one line>
**State:** pending
**Source:** loop
**Decisions:** <the decided D-ids it touches, usually none>
**Goal:** <one paragraph: what the change is for, and where it belongs>
**Acceptance:**
- <one to three lines, each a behavior the change must have, checkable from the worktree>
```

It is the reviewer's yardstick and the implementer's test contract, so it says what the user asked for, not how to build it. It is not confirmed with the user — writing it is your judgment, and the user sees it in the closing summary. **When you cannot write it without asking** — the intent is unclear, the acceptance lines would be guesses, the change has many parts or open design questions — this is not loop work: say so, and offer to take it into the objective's discussion (`${CLAUDE_PLUGIN_ROOT}/skills/new/discussion.md`), which plans it properly. Stop either way.

Then add it:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective phase-add <dir> <block-file>
```

One frame: `phase` (the id it was given — the one the loop runs), `acceptance`. A typed `FAIL:` installs nothing:

- `PHASE_ACTIVE` / `DECISION_OPEN` / `PHASE_BLOCKED` → the objective changed since the gate: refuse as Step 1 does.
- `RESTART_PENDING` → a phase restarted after a block waits to run from its earlier base, and nothing may commit before it: refuse — `/orca:open` runs it first.
- `PLAN_BAD_ID` / `PLAN_BAD_PHASE` → the block broke the format (one `## P<n> — <title>` block, pending, `**Source:** loop`, a Goal, an acceptance line): fix it, and add once more.
- `PLAN_UNDECIDED` → it cites a decision that is not decided: drop the reference, or settle the decision first in the discussion.
- Anything else (`ARCHIVED`, `BAD_DIR`, `NO_FILE`, …) → relay the detail and stop.

A second failure of the same kind goes to the user.

## Step 3: Run it

Read `${CLAUDE_PLUGIN_ROOT}/skills/new/loop.md` and follow it **for this one phase** — the `phase` the frame named — with `<dir>` and the held worktree and reviewer. Then follow its final verification (Step 8), as that file says: every phase is done again, and the branch has moved. A fix phase the verification adds runs in this pass too. Its report entry and follow-ups are ordinary phase output, and its close is this skill's close; add the phase entry the loop worked to.

## Guidelines

- `/orca:loop` never runs outside this session's objective: no target checkout, no worktree or branch of its own, no run's integration worktree. A small fix on a run's deliverable is done by hand in the session, or through `/orca:review`'s address flow.
- You never edit code. The scratch block file is the only file this skill writes; `phase-add` installs it, and the loop's rulings write `decisions.md`.
- A change that outgrows its phase mid-loop — the implementer keeps asking design questions, findings keep landing outside the goal — is discussion work. Say so, and let the user decide whether to stop: the phase stays where the files say, and `/orca:open` continues it.
