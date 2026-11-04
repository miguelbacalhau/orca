---
description: Re-open an orca objective — the long-lived unit `/orca:new` starts under `.orca/objectives/` — in this session, and carry it forward from wherever it stands. Picks one (the newest by default, or the slug named), claims it for this session and arrives in its worktree with secrets and `.orca/setup` in a background `orca:worktree` agent, then loads only a bounded digest of it — never the objective's files — and routes by its derived state: open or blocking decisions go to the discussion, an unaccepted plan back to the planning gate, a confirmed plan to the phase loop, an interrupted phase to a fresh implementer that resumes it, a finished objective to what's next (its open follow-ups, new decisions, `/orca:review`, `/orca:pr`, `/orca:archive`). One session drives an objective at a time: another live session's claim is never taken, a provably dead one only with the user's yes. Requires the bare-repo-with-worktrees layout; needs no bypass mode.
args: <optional objective slug or directory>
user-invocable: true
disable-model-invocation: true
---

# Orca: open

An objective keeps every piece of its state in files under `<repo-root>/.orca/objectives/<YYYYMMDD-HHMMSS>-<slug>/`, so any session can carry it forward. This skill picks one, claims it for this session, and continues it from where its files say it stands — the discussion, the planning gate, or the phase loop.

**Minimal context.** The objective's bounded digest is this session's whole starting context. Never read `objective.md`, `decisions.md`, `phases.md`, `report.md`, or any phase directory here: read one decision, phase, or follow-up entry only when the conversation turns to it (`sed` on its heading or id — `sed -n '/^## D3 — /,/^## /p' <dir>/decisions.md`, `grep -F -- '- F4 · ' <dir>/report.md` — never the file), and pass paths, not contents, to every agent. The instructions are split the same way: the discussion, planning, and loop live in `${CLAUDE_PLUGIN_ROOT}/skills/new/{worktree,discussion,planning,loop}.md`, each read only when the routed state needs it.

You keep what needs the conversation; workspace setup runs in `orca:worktree`. Every spawn runs in the background: wait for its notification, and never fabricate a result. Shell calls go through `bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh` with your own Bash tool — the work loop's verb hook plays no part, so this skill needs no bypass mode.

## Step 1: Pick the objective

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective list "$PWD"
```

One `OBJECTIVE:` line per objective, oldest first: `<dir>`, slug, state, `open:<n>` decisions, `pending:<n>` / `blocked:<n>` phases, `followups:<n>`, `owner:<verdict>`. (`FAIL: NOT_GIT` → nothing to open here; say so and stop.)

- **No lines** → there is no objective to open: point at `/orca:new <idea>`, and stop.
- **An argument** → match it against the slugs and directories (exact slug first, then a fragment). One match → that objective. Several → list them and ask which. None → run `objective list "$PWD" --all` before declaring the miss: an archived or abandoned one is restored with `/orca:archive --undo <slug>` first — say that. Otherwise list the objectives, and never guess.
- **No argument** → offer the newest (the last line), naming its slug and state, and list the others in one line; the user can name another. Never force the choice: an objective this session already owns (`owner:mine`) is offered first instead.

Then, by the chosen line's owner and state:

- `owner:live` or `owner:unknown` → another session holds it. Say which — the `session=` and `host=` lines of `<dir>/owner`, nothing else — and stop. Never steal a live claim; the user ends that session first.
- `owner:stale` → its owner is provably gone. Offer to take it over; on yes, open with `--steal` below, else stop.
- `landed` → its branch is merged into the trunk. Say so and offer `/orca:archive`; open it only if the user wants more work on it.

## Step 2: Open

Spawn **`orca:worktree` in `open` mode**. Its task message: `open <dir>` (plus `--steal` when the user agreed above), and the plugin root — `${CLAUDE_PLUGIN_ROOT}`, substituted. It claims the objective for this session, arrives in the worktree (re-adding it when it is gone), provisions it, and checks the config and the reviewer.

When it lands, read `${CLAUDE_PLUGIN_ROOT}/skills/new/worktree.md` and follow its worktree result. A `status: failed` whose `cause` is one of these stops first:

- `OWNED_ELSEWHERE` → another live session claimed it since the list: say which, and stop.
- `OWNER_STALE` → offer `--steal` as in Step 1, and spawn once more on yes.
- `ARCHIVED` → restore it first with `/orca:archive --undo <slug>`, and stop.
- `NO_SESSION_ID` → this session has no id to claim with: relay it, and stop.

Any other cause is a worktree or provisioning failure: the claim stands, and the shared `status: failed` rule holds.

## Step 3: The digest

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh objective digest <dir>
```

At most 40 lines: the title and one-line outcome, the derived `State:`, the worktree and whether it is dirty, the decision counts with the open ones listed, one line per phase, the active phase's last action, the open follow-ups by count, and the last report entry's heading. Show the user the gist in a few lines — where the objective stands and what comes next — and route.

## Step 4: Route by state

The digest's `State:` line decides where this session goes:

- **`discussing`** / **`blocked`** → the discussion: read `${CLAUDE_PLUGIN_ROOT}/skills/new/discussion.md` and follow it, the open decisions first — a `blocked` objective's blocking decision (the phase line's `blocked on D<n>`) before anything else. When the user says go, hand off as below.
- **`planning`** → a proposal awaits its confirmation: read `${CLAUDE_PLUGIN_ROOT}/skills/new/planning.md` and follow it — it starts from where the gate stopped. On its confirmation, the loop.
- **`ready`** → a confirmed plan with pending phases: list them from the digest and ask once — **run them now?** Yes → the loop. Changes → the discussion.
- **`active`** → a phase was interrupted mid-loop: say which, from the digest's phase and `Action:` lines, and run the loop — it resumes that phase with a fresh implementer and the resume handoff, and `rounds next` continues from its files.
- **`idle`** → every phase is done. Offer what's next: the open follow-ups by count — the user can pull any into the discussion, where a decision citing it (`**Source:** F4`) takes it — new decisions, then plan and loop; or `/orca:review`, `/orca:pr`, `/orca:archive`.
- **`landed`** → the user chose in Step 1 to keep working on it: as `idle`.

**The hand-off** from the discussion, when the user says go, is the one in `${CLAUDE_PLUGIN_ROOT}/skills/new/worktree.md`: confirm no decision is open, then planning, then the loop. A decision that blocked a phase is settled this way too.

**The loop** is `${CLAUDE_PLUGIN_ROOT}/skills/new/loop.md`, read and followed with `<dir>`, `worktree`, and `reviewer` in hand.

A user who stops anywhere needs nothing from you: the files already say where the objective is, and `/orca:open` picks it up again from any session.

## Guidelines

- The digest is the starting context. Reading an objective's files whole — even "just to check" — is exactly what this skill exists to avoid; read the one entry the conversation needs.
- Never steal a live session's claim, and never steal a stale one without the user's yes.
- You never edit code and never touch the worktree. `objective.md` and `decisions.md`, through the discussion and the loop's rulings, are the only files this skill writes.
- Never read `.orca/config`, `.orca/setup`, or a setup log into the conversation; the worktree agent reports them, and `/orca:doctor` owns fixing them.
