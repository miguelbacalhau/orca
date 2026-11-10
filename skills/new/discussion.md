# Orca: objective — the discussion

This file is read by `/orca:new` once its research returns, and by `/orca:open` when an objective's state routes to the discussion. The discussion is where an objective's intent gets captured — unhurried, adversarial about scope, free to span as many rounds and sessions as the idea needs. Its product is two files in the objective directory `<dir>`: `objective.md` — the outcome, the non-goals, the constraints — and `decisions.md` — one entry per question the discussion raises, written the moment it is settled, and written `open` while it is not. There is no single document at the end: each answer lands as it is given, so a discussion that stops mid-way leaves the files saying exactly where it stopped.

The files are *what and why* — human intent, including the direction choices the discussion settles. They are not *how it maps onto the codebase*: phases, interfaces, and file ownership belong to the planner (`orca:phases`), which grounds them in its own exploration. A breakdown written here would be a guess. The discussion is not forbidden from knowing the system — the opposite: good questions come from friction between the idea and the code as it is, so `/orca:new` researches first and asks from that picture.

## The files

**`objective.md`.** Its header lines — `**Base:**`, `**Base commit:**`, `**Branch:**`, `**Worktree:**` — belong to the verbs: never edit them. Write only:

- `# <title>` — the first line starts as the slug; replace it with a short human title once the idea has one.
- `## Idea` — the user's idea verbatim, written by `objective new` when the objective is created; leave it as it is.
- `## Outcome` — what exists when this is done that does not exist now. **The first line is a one-sentence outcome** (it is the line `/orca:open`'s digest shows); one or two paragraphs may follow.
- `## Non-goals` — bullets of explicitly excluded scope, each with its why where one was discussed.
- `## Constraints` — bullets: code it must integrate with, compatibility or performance expectations, bounds on scope — each with its why.

Rewrite a section whenever the discussion changes it; the file is small.

**`decisions.md`.** One entry per question, appended under `# Decisions`:

```markdown
## D3 — <the question, one line>
**State:** open | decided | deferred
**Source:** discussion
**Options:** <A> · <B>
**Decision:** <the chosen option>
**Why:** <the reason>
```

- **Ids** continue the sequence — one past the highest `## D<n>` in the file — and are never reused or renumbered.
- **State.** `open` — raised, not settled; planning cannot start while one remains. `decided` — settled; `**Decision:**` and `**Why:**` are filled. `deferred` — the user chose to leave it out of this pass: `**Why:**` says why, and the planner plans nothing that depends on it. A decision a blocked phase waits on is never deferred: while a phase is blocked no phase runs, so deferring it stops the objective. Settle it — dropping or undoing that phase's work is a decision too. `**Decision:**` is written only on a decided entry.
- **Source** is `discussion` for anything raised here. A decision that takes up a follow-up from the report cites it instead — `**Source:** F4` — and that is what marks the follow-up taken; never edit the report's list.
- **Options** are the real shapes the question had, on one line, separated by ` · `.
- **One line per key**, nothing else between them but the entry's own lines: the verbs read only headings and `**Key:**` lines, and only each key's first line.

Write an entry the moment its question is raised (`open`) or settled (`decided`) — not in a batch after the round. Append new entries with a heredoc; to settle or change one, read only that entry (`sed -n '/^## D3 — /,/^## D/p'` on its heading — never the whole file, which grows with the objective) and edit it in place. A decided entry that a done phase realizes is history: a change of mind about it is a new entry whose `**Why:**` names the one it overturns.

**What is a decision and what is not.** A question with options the user chose between — a direction, an overturned project decision, an unknown neither the idea nor the code settles — is a D-entry. The outcome, a non-goal, or a constraint the user simply states goes into `objective.md`. When in doubt, a choice between named alternatives is a decision; a fact about the goal is not.

**What never lands in the files:** the research report, or anything quoted from it, and anything about *how* — phases, work items, interfaces, file lists. Whatever mattered in the research lands as the user's answer to a question it raised.

## Opening

**From `/orca:new`, open with an informed reflection, not a batch of questions.** The first message reflects the idea back against the research:

- what the system does *today* in the touched area, stated explicitly — the correctability valve: if the research got it wrong, the user sees it here and fixes it in one reply;
- the two or three shapes the idea could take against that reality, and what each implies ("the current middleware has no user identity at that layer — extend it, or hang this elsewhere?");
- the tensions the research found, named plainly.

If the research shows the codebase fights the idea — an approach the architecture resists, an interface the code refuses — say so now, where changing course is cheap. Without a research report (it died, or there was nothing to explore), open with the intent-only version: the idea restated and its most load-bearing unknown.

**From `/orca:open`,** open with what the digest says is unsettled: the open decisions first, each read from its own entry when the conversation reaches it. An open decision the loop raised (`**Source:** P2 …`) blocked a phase; once it is decided, the pending and blocked phases are replanned before the loop resumes, so say so when it settles.

Then ask about the single most load-bearing unknown. The research is the question generator, and it yields three kinds of questions — each one a D-entry, `open` the moment it is asked:

- **Direction questions** — which of the possible shapes the user actually wants, and why.
- **Decision questions** — "the decision log says X was chosen deliberately — does this idea overturn that?" An overturned project decision becomes a D-entry here, never an edit to the log.
- **Unknown questions** — what neither the idea nor the code decides; every one settled here is one the planner and the implementers will not have to guess at.

## Pacing — hard form constraints, not suggestions

- At most 2–3 open-ended questions per round, each grounded in the previous answer. The discussion is multi-round by design; it ends when the files state the intent with no gaps and the user has nothing to add, not when a topic list is exhausted.
- Never batch the coverage topics into one round. The list below is coverage to have reached *by the end*; administering it as a form is exactly the failure this discussion is designed against.
- **AskUserQuestion is banned.** Its canned options turn an open discussion into multiple choice, and a decision's options are the discussion's to find, not a menu's.
- Depth proportional to what's missing: a rich idea gets the reflection plus a couple of sharp questions; a one-liner gets the full multi-round discussion. Never re-ask what the idea or the files already answer.

Coverage to reach by the end — through conversation, not as a checklist:

- The outcome: what exists when this is done that does not exist now.
- What it must do, and explicitly what it must not — the non-goals.
- Direction: which shape the idea takes against the current system, wherever there were shapes to choose between — with the *why* behind each choice.
- Inputs and outputs: what data, events, or actions go in; what results, side effects, or artifacts come out.
- Constraints: existing code it must integrate with, compatibility or performance expectations, bounds on scope.

Push back throughout. Play devil's advocate on scope, hunt for unstated non-goals, and use the research to make ambiguities concrete: a named tension the user must resolve beats a generic "any non-goals?" every time.

Stay at intent level in what you write down. If the conversation turns into walking the user through source at length, it has drifted from *what* into *how*; steer it back — the planner explores the code with fresh context.

## The quality bar

The planner must be able to act on the files without guessing. Every tension and unknown the research surfaced appears either *settled* — a decided entry, a constraint, or a non-goal — or *explicitly left* — an `open` entry still to discuss, or a `deferred` one the user chose to leave out. Nothing is left silent. The files carry reasoning, not just conclusions: a non-goal with its why survives contact with an autonomous implementer; a bare bullet invites reinterpretation.

## Ending

The discussion ends when the user says go, or when they stop. Either way, return to the skill that loaded this file — it checks that no decision is open before planning, and tells a user who stops how to pick the objective up again. Do not read the files back first: the planning gate shows the user the plan built from them, and that is the one confirmation.

## Guidelines

- One objective is one outcome. If the discussion uncovers two independent efforts, say so: the second is its own `/orca:new`.
- The files are written as the discussion goes. Never keep a settled answer only in the conversation — a session that ends loses it.
- The research report is disposable: never persisted, never pasted to the user.
