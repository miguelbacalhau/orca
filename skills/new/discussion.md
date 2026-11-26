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
**Extends:** <what this adds beyond the idea, one line>
```

- **Ids** continue the sequence — one past the highest `## D<n>` in the file — and are never reused or renumbered.
- **State.** `open` — raised, not settled; planning cannot start while one remains. `decided` — settled; `**Decision:**` and `**Why:**` are filled. `deferred` — the user chose to leave it out of this pass: `**Why:**` says why, and the planner plans nothing that depends on it. A decision a blocked phase waits on is never deferred: while a phase is blocked no phase runs, so deferring it stops the objective. Settle it — dropping or undoing that phase's work is a decision too. `**Decision:**` is written only on a decided entry.
- **Source** is `discussion` for anything raised here. A decision that takes up a follow-up from the report cites it instead — `**Source:** F4` — and that is what marks the follow-up taken; never edit the report's list.
- **Options** are the real shapes the question had, on one line, separated by ` · `.
- **Extends** goes only on a decided entry whose decision takes on work the idea does not ask for (Scope, below), naming that work. A decision that keeps the scope, narrows it, or splits work out gets no `**Extends:**` line.
- **One line per key**, nothing else between them but the entry's own lines: the verbs read only headings and `**Key:**` lines, and only each key's first line.

Write an entry the moment its question is raised (`open`) or settled (`decided`) — not in a batch after the round. Append new entries with a heredoc; to settle or change one, read only that entry (`sed -n '/^## D3 — /,/^## D/p'` on its heading — never the whole file, which grows with the objective) and edit it in place. A decided entry that a done phase realizes is history: a change of mind about it is a new entry whose `**Why:**` names the one it overturns.

**What is a decision and what is not.** A question with options the user chose between — a direction, an overturned project decision, an unknown neither the idea nor the code settles — is a D-entry. The outcome, a non-goal, or a constraint the user simply states goes into `objective.md`. When in doubt, a choice between named alternatives is a decision; a fact about the goal is not.

**What never lands in the files:** the research report, or anything quoted from it, and anything about *how* — phases, work items, interfaces, file lists. Whatever mattered in the research lands as the user's answer to a question it raised.

## Scope

**The idea is the scope.** `## Idea` is what the user asked for. The discussion sharpens it; it does not grow it. Weigh everything the discussion touches against the idea:

- **Inside the idea** — a direction, an unknown, or a tension the idea meets on the way to its outcome. Discuss it.
- **Beside the idea** — something the research noticed nearby: a pre-existing bug, an inconsistent neighbour, stale docs, a cleanup the change would make easy. That is not a question. Write it into `## Non-goals` (`not fixed here: <it> — outside the idea`) and name it in one line, so the user can pull it in. It becomes a D-entry only when the outcome cannot be delivered without it; then it is inside, and the entry's `**Why:**` says why the outcome needs it.
- **Beyond the idea** — an answer, the user's or one you are about to recommend, that widens the outcome: a pivot, another surface, a second problem, an item an earlier answer left out. Before recording it, say so in one line — what the idea asked for, what this adds — and offer the split first: its own `/orca:new`, with this objective kept to the idea. The user decides. A widening the user takes in is a decided entry with an `**Extends:**` line, and the outcome is rewritten to include it.

**Lean narrow.** Recommend the option that delivers the idea with the least new work, unless the idea itself needs more. "We are touching it anyway", "polishing what will be replaced is wasted", and "so the docs ship with it" are reasons to name an extension, not to recommend one. Never offer back what the user already left out: a `deferred` entry, a non-goal, a follow-up they passed on.

**A widening's own questions** come only once the user has taken it in. Even then, ask only what the user must choose. What the planner can settle from the code (naming, wiring, which component carries it) is not a question.

## Opening

**From `/orca:new`, open with an informed reflection, not a batch of questions.** The first message reflects the idea back against the research:

- what the system does *today* in the touched area, stated explicitly — the correctability valve: if the research got it wrong, the user sees it here and fixes it in one reply;
- the two or three shapes the idea could take against that reality, and what each implies ("the current middleware has no user identity at that layer — extend it, or hang this elsewhere?");
- the tensions the research found, named plainly — those beside the idea (Scope, above) in one line as what this objective leaves alone, not as questions.

If the research shows the codebase fights the idea — an approach the architecture resists, an interface the code refuses — say so now, where changing course is cheap. Without a research report (it died, or there was nothing to explore), open with the intent-only version: the idea restated and its most load-bearing unknown.

**From `/orca:open`,** open with what the digest says is unsettled: the open decisions first, each read from its own entry when the conversation reaches it. An open decision the loop raised (`**Source:** P2 …`) blocked a phase; once it is decided, the pending and blocked phases are replanned before the loop resumes, so say so when it settles. New work brought to an objective whose phases are all done is beyond the idea unless it finishes what the idea asked for, so offer the split first.

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

Push back throughout. Play devil's advocate on scope (the user's own widenings included), hunt for unstated non-goals, and use the research to make ambiguities concrete: a named tension the user must resolve beats a generic "any non-goals?" every time.

Stay at intent level in what you write down. If the conversation turns into walking the user through source at length, it has drifted from *what* into *how*; steer it back — the planner explores the code with fresh context.

## The quality bar

The planner must be able to act on the files without guessing. Every tension and unknown the research surfaced inside the idea appears either *settled* — a decided entry, a constraint, or a non-goal — or *explicitly left* — an `open` entry still to discuss, or a `deferred` one the user chose to leave out. One beside the idea is a non-goal. Nothing is left silent. The files carry reasoning, not just conclusions: a non-goal with its why survives contact with an autonomous implementer; a bare bullet invites reinterpretation.

## Ending

The discussion ends when the user says go, or when they stop. Either way, return to the skill that loaded this file — it checks that no decision is open before planning, and tells a user who stops how to pick the objective up again. Do not read the files back first: the planning gate shows the user the plan built from them, and that is the one confirmation.

**Offer the start; don't wait to be told.** The moment the files meet the quality bar — no decision `open`, nothing the research raised left silent — say so in one line and ask once whether to start planning. Ask it in prose, never with AskUserQuestion. The offer carries the scope check. List the entries that extend the idea:

```bash
awk '/^## D/{h=$0} /^\*\*Extends:\*\*/{sub(/^\*\*Extends:\*\* */, ""); print h " — " $0}' <dir>/decisions.md
```

Name each in a few words, as what the objective has grown by beyond the idea. When the list is empty, say the objective stays within the idea. A yes is the go. A user who says go on their own is not asked again, but still gets the scope check, in one line; a go given while a decision is still open stands once that decision is settled, so the session goes on to planning without asking again. Anything else they add reopens the discussion, and the offer comes again once the bar is met again.

## Guidelines

- One objective is one outcome: the idea's. If the discussion uncovers two independent efforts, say so: the second is its own `/orca:new`, and that is the option you recommend.
- The files are written as the discussion goes. Never keep a settled answer only in the conversation — a session that ends loses it.
- The research report is disposable: never persisted, never pasted to the user.
