---
description: Convene a council on one read-only question about the repository — the same prompt put to several independent agents on different models in parallel (by default Opus, Fable, and Codex on gpt-6-astra), each blind to the others, then merged in this session into one answer with every claim's agreement counted and every contradiction settled against the code. Use for questions, investigations, and design critiques where a second and third opinion from a different model is worth the cost — "why does X happen", "what breaks if we change Y", "is this design sound". Never edits anything, never persists the result. The roster comes from the `council` key in `.orca/config` (orca:config); not part of a run.
args: <the question, verbatim>
user-invocable: true
disable-model-invocation: true
---

# Orca: council

One question, several minds. Every seat gets the identical prompt in a fresh context and never sees another seat's answer; the council's diversity is its models, not its instructions. Then you — this session — merge what came back. The seats answer in evidence-anchored claims precisely so the merge is a matching and adjudication job, not a reading-of-three-essays job.

Read-only end to end: the seats can't write, Codex runs sandboxed read-only, and you write nothing to `.orca/` or the repository. The answer lives in this conversation; if the user wants it saved, they will say so.

## Step 1: The question

`<args>` is the question, verbatim — never paraphrase, expand, or "improve" it before it reaches the seats; a rewritten question gives the seats your framing instead of theirs. Empty `<args>` → ask for the question and stop.

A question that asks for changes ("implement…", "fix…", "refactor…") is outside the council's reach: the seats are read-only. Say so in one line and offer to put the read-only half to the council instead ("how should X be fixed?"); never strip the ask silently.

## Step 2: Seat the council

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh council resolve
```

TAB-separated lines: `ROOT:` (the checkout the seats explore), `SOURCE:` (`pinned` from the config or `default`), one `MEMBER: <seat> <name> <kind> <model>` per sitting seat, a `DROPPED: <seat> <name> <reason>` per vacated astra seat, and — when a Codex seat sits — `SCRATCH:` (the astra courier's staging directory).

A typed `FAIL:` stops the council — translate it, never work around it:

- `NO_CODEX` — the pinned roster seats `astra` and Codex is missing or too old. Point at `/orca:doctor` to install it, or `/orca:config council=…` to drop the seat.
- `CODEX_UNUSABLE` — Codex is installed but unauthenticated or speaks the wrong `codex exec` interface; the detail names which. Point at `/orca:doctor`.
- Config errors (`PARSE_ERROR`, `BAD_COUNCIL`, …) — the config file is mangled; point at `/orca:config`.
- `NOT_GIT` — the council answers questions about a repository; there isn't one here.

## Step 3: Deliberate

Invoke the Workflow tool with `scriptPath: "${CLAUDE_PLUGIN_ROOT}/scripts/council.workflow.js"` — the substituted value is already absolute; never pass `~` or an unsubstituted variable — and:

```
args: { prompt, root, members: [{ seat, name, kind, model }], pluginRoot, scratch }
```

`prompt` is the question verbatim, `root` the `ROOT:` value, `members` one object per `MEMBER:` line (seat as an integer, the rest verbatim), `pluginRoot` the substituted `${CLAUDE_PLUGIN_ROOT}`, and `scratch` the `SCRATCH:` value — omitted when there is none. Tell the user in one line who is sitting (and who was dropped, with the reason) while it runs. The workflow runs in the background: wait for its task notification, and never fabricate a seat's answer. The runId is throwaway — never persist or resume it.

It returns `{ members: [...] }` in seat order. Each has `status`:

- `ok` — a Claude seat's answer is inline as `result`; a Codex seat's is on disk at `artifact`. `Read` that file: it is Codex's own bytes, and you are the first to read them.
- `died` / `failed` (with `reason`) — the seat did not answer.

Fewer than two answers is not a council: say which seats failed and why, show the one answer that landed as that single seat's view (labelled as such), and offer to reconvene. Never relaunch on your own.

## Step 4: Merge

This is the judgment, and it is yours. Work only from what the seats returned plus the code you open to settle disputes.

- **Group** claims that assert the same thing, however differently worded. Similar is not same: two claims about the same function that reach different conclusions are a contradiction, not a group.
- **Count** each group's support as `n/N` over the seats that answered, naming them (`3/3 — opus, fable, astra`).
- **Settle contradictions against the code.** Open the cited evidence on both sides and say which holds, with the `path:line` that decides it. Unsettleable from the code → present both sides and what would decide it.
- **Weigh evidence, not votes.** An anchored `1/3` claim that checks out outranks an unanchored `3/3`. Never drop a single-seat claim for being outvoted; mark it unconfirmed, and check it when it matters to the answer.
- **Favor no seat** — including whichever model this session runs on. Seats are names in a count, not authorities.
- **Spot-check** the claims the answer rests on before stating them as established; an anchor that does not say what the claim says is a finding about that seat's claim.

## Step 5: The answer

In this order, compact:

1. **Who sat** — one line: the seats that answered, any dropped or failed and why.
2. **The answer** — the direct answer to the question, synthesized from the merge; where the seats' summaries disagree, say so here, not only below.
3. **Claims** — grouped, strongest support and most consequential first, each with its count, seats, and the anchor that carries it. Unconfirmed single-seat claims marked as such.
4. **Contradictions** — each with how it was settled (or why it couldn't be).
5. **Open questions** — merged and deduplicated across the seats.

Then remove the scratch directory, if there was one: `rm -rf <SCRATCH>` — only the exact `SCRATCH:` path the resolve printed, never anything derived from it.

## Guidelines

- Never edit anything, and never write the result to a file unasked.
- The roster is configuration: `/orca:config council=opus,fable,astra` (2 to 5 seats from haiku, sonnet, opus, fable, astra; repeats allowed). Never reshuffle the seats yourself.
- A council costs every seat a full-depth exploration. It is worth it for questions where a wrong answer is expensive; say so briefly if the question is a one-line lookup, and convene anyway if the user wants it.
