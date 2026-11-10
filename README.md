<p align="center">
  <img src=".github/logo.png" width="280" alt="Orca logo">
</p>

<h1 align="center">orca</h1>

A [Claude Code](https://claude.com/claude-code) plugin for autonomous, multi-agent development. Set a repository up once, then **`/orca:run`** takes an idea to a committed feature branch: an interview captures your intent as a brief, and a deterministic workflow plans, implements, independently reviews, fixes, commits, merges, and verifies it. After the interview you are asked one question (two, if you opt into a checkpoint). For work you expect to come back to, **`/orca:new`** starts an *objective* instead: a recorded discussion, a reviewed plan of sequential phases, and each phase built and reviewed round by round until clean — re-opened with **`/orca:open`** whenever there is more to do.

```text
/orca:run <idea>         # interview → brief → spec → work loop → report
/orca:new <idea>         # an objective: discussion → decisions → reviewed phase plan → phase loop
/orca:open [objective]   # re-open an objective and carry it forward from where it stands
/orca:review             # review the deliverable in your editor; comments round-trip
/orca:pr                 # publish a delivered run or objective as a draft GitHub pull request
/orca:retry              # finish a run's blocked items, after resolving them with you
/orca:followup           # turn a run's optional follow-ups into the next brief
/orca:loop [change]      # one small phase in this session's objective: implement, review, fix until clean, commit
/orca:status             # read-only dashboard: what's in flight and what to do next
/orca:archive            # retire landed runs, and objectives landed or abandoned
/orca:council <question> # one question to several models at once, answers merged
/orca:init               # one-time repository layout setup
/orca:doctor             # machine and repository readiness checks
/orca:config             # per-repo reviewer and model/effort overrides
```

A run's deliverable is a `feature/<slug>` branch in its own worktree. You review it with `/orca:review` and land it yourself with `git merge --no-ff`, or publish it with `/orca:pr`. Runs never touch your own worktree, and no commit they produce mentions Claude, AI, agents, or orca.

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Commands](#commands)
- [What a run does](#what-a-run-does)
- [Objectives](#objectives)
- [Configuration](#configuration)
- [Permissions](#permissions)
- [Recovery](#recovery)
- [Troubleshooting](#troubleshooting)
- [Further documentation](#further-documentation)
- [Development](#development)

## How it works

**Isolation.** Every stage (spec, plan, implement, review, fix, commit, merge, integrate) runs in its own subagent with its own context, and every work item gets its own git worktree off a shared bare repository. Parallel items can't touch each other's files; overlap surfaces as a merge conflict, resolved by a merge agent that has both items' plans.

**Independent review.** Claude implements; a separate reviewer attacks each result, tests included, before it is committed. By default that reviewer is [Codex](https://openai.com/codex/), a different model family with different blind spots. Where Codex isn't installed, or with `reviewer=claude`, a fresh-context Claude agent does the same review — still independent, but same-model.

**A deterministic work loop.** The autonomous part of a run is a script executed by Claude Code's Workflow tool. Scheduling, retry limits, review throttling, merge ordering, and the commit-attribution check are code; judgment calls are agent calls whose reasons are written to the run's files. Every agent call is journaled, so an interrupted run resumes where it stopped.

**State lives in files** under `.orca/` in your repository — the brief, the spec, one plan per item, the review findings, and the final report — never in conversation memory.

## Requirements

| | |
|---|---|
| **Claude Code** | With the Workflow tool and function hooks (mods) — 2.1.290 or later. Function hooks must be enabled (`CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` in a settings `env` block where they are off by default), the session not started with `--bare`, and no `disableAllHooks` in any settings file. |
| **Permission mode** | `bypassPermissions` for the session running the run; objectives don't need it. See [Permissions](#permissions). |
| **git** | ≥ 2.31; ≥ 2.42 for `/orca:init` to create a brand-new repository. |
| **Repository layout** | Bare repository with worktrees (`.bare/` plus peer worktrees). `/orca:init` sets it up, including converting an existing checkout. |
| **Codex CLI** *(codex reviewer only)* | The global `codex` binary ≥ 0.142.5, authenticated with `codex login`. Install with `brew install codex` or the official release binaries — **never via npm**. Plus `BASH_MAX_TIMEOUT_MS=1200000` in a settings `env` block, which `/orca:doctor` writes for you. |

The twenty-four agents and the CLI ship inside the plugin; nothing else is installed per repository.

## Installation

Inside Claude Code:

```
/plugin marketplace add miguelbacalhau/orca
/plugin install orca@orca
```

Start a fresh session afterwards — plugins load at session start. Update with `/plugin marketplace update orca` (or enable auto-update under `/plugin` → Marketplaces); remove with `/plugin marketplace remove orca`.

To have teammates prompted to install it, commit this to the project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "orca": { "source": { "source": "github", "repo": "miguelbacalhau/orca" } }
  },
  "enabledPlugins": { "orca@orca": true }
}
```

To work on the plugin itself, load a checkout for one session with `claude --plugin-dir /path/to/orca`.

## Quick start

```bash
# 1. Once per repository: set up the bare-repo-with-worktrees layout.
#    Converting an existing checkout keeps untracked files but changes every path.
/orca:init

# 2. Once per machine, if the pre-flight complains: Codex install/auth and
#    the review timeout. Skip if you'll use the Claude reviewer.
/orca:doctor

# 3. Switch the session to bypass permissions (Shift+Tab), then describe the feature.
#    The interview writes a brief; after one confirmation the run is autonomous.
/orca:run add rate limiting to the public API

# 4. Review the result in your editor, then land it — or open a draft PR instead.
/orca:review
git merge --no-ff feature/<slug>
/orca:pr

# 5. If the report lists blocked items, resolve and finish them in the same run.
/orca:retry
```

If secrets or a build step are needed for tests to pass in a fresh worktree, see [Worktrees, secrets, and provisioning](docs/worktrees.md).

## Commands

Full detail for each is in [docs/commands.md](docs/commands.md).

**`/orca:run <idea>`** — Resumes an interrupted run, runs a queued brief from `.orca/feat-briefs/`, or interviews a new idea. The interview researches the code the idea touches and pushes back on scope until the brief — outcome, features, non-goals, constraints, and a *doubt rule* for ambiguities — is unambiguous. You then confirm the brief once, and the run goes to a report without further questions. Anything it can't resolve becomes a `blocked` item in the report, with the options for you to choose between. You can decline the run and leave the brief queued.

**`/orca:new <idea>`** — Starts an objective under `.orca/objectives/`. Its files and worktree are created at once, and the worktree is provisioned in the background while the code the idea touches is researched. The discussion then writes the outcome, non-goals, and constraints into `objective.md`, and every question into `decisions.md` as it is raised or settled. When no decision is open and you say go, a planner proposes sequential phases, an independent reviewer attacks the plan, and you confirm it once. Each phase then runs in the objective's worktree: one agent implements it, fixes every round, and commits; a fresh reviewer attacks each round; a deterministic round engine decides every next step until a round has no Critical/High. Disputes, stalls, and questions come to you and are recorded as decisions — or block the phase until you decide. Each phase adds its entry and follow-ups to the objective's report. See [Objectives](docs/objectives.md).

**`/orca:open [objective]`** — Re-opens an objective in this session (one session drives an objective at a time) and loads only a bounded digest of it, then continues where its files say it stands: the discussion, the planning gate, the phase loop — resuming an interrupted phase with a fresh implementer — or what's next once every phase is done.

**`/orca:review [branch]`** — Opens the deliverable's diff — a run's, or an objective's — in your editor: Neovim via [orca.nvim](https://github.com/miguelbacalhau/orca.nvim) in a new tmux window, or VS Code via [orca.vscode](https://github.com/miguelbacalhau/orca.vscode). Comments you leave are saved; when you close the review, orca proposes how it will handle each one (fix, answer, decline, or defer), and on your consent fixes and answers them in the integration worktree, with the resolutions showing inline next time you review.

**`/orca:pr [run]`** — Pushes a delivered run's or objective's branch and opens a **draft** pull request via `gh`, with a short plain-language description built from its report (or your repo's PR template). Refused unless the work is verified and nothing is blocked — for an objective, no phase still pending or active. You see the exact title and body first.

**`/orca:retry [run]`** — Finishes a run's blocked or cut items inside the same run and branch. It audits the run against git, resolves each blocked decision with you, records your answers in the spec, and relaunches the work loop over just those items.

**`/orca:followup [run]`** — Lets you pick from a finished run's optional follow-ups (deferred findings, known gaps) and writes them into a new brief for `/orca:run`.

**`/orca:loop [instructions]`** — For a change too small to plan, inside the objective this session has open: your session writes it as one short phase from the conversation, without asking you to confirm it, and runs it through the objective's phase loop — implemented, independently reviewed round after round until no Critical/High finding remains, and committed in the objective's worktree. Outside an objective it refuses and points at `/orca:new` and `/orca:open`; work it can't describe in a few lines goes to the objective's discussion.

**`/orca:status [run]`** — A read-only dashboard combining `.orca/` state and git: interrupted runs, queued briefs, objectives by state, unmerged deliverables, leftover branches and worktrees, each naming the command that handles it. It suggests cleanup commands where deletion is provably safe but never runs them.

**`/orca:archive [run]`** — Retires finished runs whose branches have all merged into the trunk, removing their worktrees and branches so triage stays short. Objectives retire here too, landed or not: abandoning one saves its uncommitted work as a `wip:` commit and keeps its branch tip under a hidden ref. Run and objective directories are kept, and `--undo` recreates the branches.

**`/orca:council <question>`** — Puts one read-only question about the repository to several independent agents on different models at once — by default Opus, Fable, and Codex on `gpt-6-astra` — then merges their answers in your session: matching claims grouped with how many models back each, contradictions settled against the code. A plain question goes to the models as typed; an instruction like "validate what we just worked out" has your session summarize the conversation into a question and context brief, which you approve before the council convenes, and the answer scores each of the session's conclusions. Nothing is edited or saved. Without Codex installed, the default council sits with its two Claude seats.

**`/orca:init [path or clone URL]`** — Creates, clones, or converts a repository into the bare-repo-with-worktrees layout, asking before each step. Conversion keeps untracked and ignored files (`.env`s, caches) and is reversible until the final cleanup.

**`/orca:doctor`** — Checks and fixes what runs depend on: the Codex CLI (installed, authenticated, compatible), `BASH_MAX_TIMEOUT_MS`, which reviewer runs will use, the editor companions, and whether the repository has a worktree provisioning script — offering to derive and test one. Every change is confirmed first.

**`/orca:config [assignments | reset]`** — Pins the reviewer and overrides per-stage model and effort; see [Configuration](#configuration).

## What a run does

```text
triage → pre-flight → confirm → spec → spec review → [checkpoint] → work loop → integrate → report
```

1. **Pre-flight** checks the layout, the plugin install, the reviewer, and (for codex) the Codex CLI. Any failure stops the run before it starts.
2. **Spec** — an agent explores the codebase and writes `spec.md`: interfaces between work items and a 2–8 item work breakdown with dependencies, file ownership, and acceptance criteria. The run's reviewer reviews it against the brief; serious findings get one revise round.
3. **Work loop** — each item, as soon as its dependencies have merged: plan → implement → review → fix (at most 2 rounds) → commit → merge onto the integration branch. Plans of the same wave are checked against each other. Problems that can be fixed without changing what was agreed are fixed and recorded in the spec's Decisions log; the rest block the item without stopping unrelated ones.
4. **Integrate** — an agent builds, tests, and exercises each feature end to end on the assembled branch.
5. **Report** — `report.md`: what shipped, what was cut or blocked and why, deviations, integration results, follow-ups, and how to land it.

While it runs, the session shows a live band above the prompt with each item's state:

```text
── orca ─ staged-typecheck-overlay · build · 3/6 merged ────────────
  W1  Overlay view layers      ✓ done
  W3  CLI flag wiring          ● review r2
  W5  Docs + config            ◌ waiting on W3, W4
  W6  Telemetry hook           ✕ blocked: <escalation reason>
```

The full lifecycle — pre-flight gates, escalation rules, the run band, the decision log, and the stage agents — is in [docs/anatomy.md](docs/anatomy.md).

## Objectives

```text
/orca:new <idea> → files + worktree ∥ research → discussion → decisions → phase plan → plan review → confirm → phase loop
```

1. **Discussion** — the outcome, non-goals, and constraints land in `objective.md`; every question lands in `decisions.md` as `open`, `decided`, or `deferred`, the moment it is raised or settled.
2. **Planning** — with no decision open, `orca:phases` proposes sequential phases (goal, acceptance lines, the decisions each realizes), a verb validates the proposal, and the reviewer attacks it; Critical/High findings get one revise round. You confirm the plan once.
3. **Phase loop** — each phase, in order, on `feature/<slug>` in one worktree: one implementer, kept alive for the phase, implements, fixes every round, and commits; a fresh reviewer attacks each round; `orca.sh rounds next` reads the phase's files and decides every next step until a round has no Critical/High. What only you can decide comes to you and is recorded as a decision; deciding later blocks the phase and stops the pass until a replan.
4. **Report** — each phase adds its entry (review rounds, declines, checks) and its follow-ups to `report.md`, which `/orca:review` and `/orca:pr` read like a run's.

Everything is a file under `.orca/objectives/`, so `/orca:open` continues an objective from any session, and the objective band shows its decisions or phases above the prompt:

```text
── orca ─ rate-limit-public-api · P2/4 · 2 follow-ups ──────────────────
  P1  Token bucket + store                 ✓ done a1b2c3d
  P2  Middleware on public routes          ● review r2
  P3  429 responses + headers              ◌ pending
```

The files, states, and every step are in [docs/objectives.md](docs/objectives.md).

## Configuration

**`.orca/config`**, written by `/orca:config`, holds flat `key=value` overrides, applied at the next run launch:

```
reviewer=claude
editor=nvim
terminal=tmux
council=opus,fable,astra
agents.plan.effort=high
agents.implement.model=opus
```

- **`reviewer`** — `codex` or `claude`. When absent, each launch detects: codex if it's installed at the minimum version, otherwise claude. Setting it pins the choice, so a broken Codex fails the pre-flight instead of silently falling back.
- **`editor`** (`nvim`|`vscode`|`none`) and **`terminal`** (`tmux`|`none`) — for `/orca:review`. Absent means detect; `none` prints the command to run instead.
- **`council`** — the seats `/orca:council` convenes: 2 to 5 of `haiku`|`sonnet`|`opus`|`fable`|`astra` (Codex on `gpt-6-astra`), comma-separated, repeats allowed. Absent means `opus,fable,astra`, dropping `astra` when Codex isn't installed; a pinned `astra` with Codex missing fails instead.
- **`agents.<stage>.model|effort`** — models `haiku`|`sonnet`|`opus`|`fable`, efforts `low` through `max`. `spec`, `research`, and `plan` default to `fable`; if your plan doesn't offer it, run `/orca:config spec.model=opus research.model=opus plan.model=opus`. Defaults are listed in [Stage agents](docs/anatomy.md#stage-agents).

**`BASH_MAX_TIMEOUT_MS`** (codex reviewer only) — Codex reviews run through the Bash tool, whose default timeout is too short. `/orca:doctor` writes `{ "env": { "BASH_MAX_TIMEOUT_MS": "1200000" } }` into `.claude/settings.local.json` or `~/.claude/settings.json`; restart the session afterwards. orca itself stops a review at 18 minutes, inside that limit.

orca runs whichever `codex` is first on your `PATH`, with the review's permissions — keep your `PATH` trustworthy.

## Permissions

A run must never hit a permission prompt: one prompt stalls it mid-run, and an auto-denied call makes an agent fail confusingly. Agents choose commands at runtime (installs, builds, test variants, git), so no allow-list can cover them — **runs require `bypassPermissions`**. orca's [verb hook](docs/verb-hook.md), which runs the work loop's shell steps, also refuses to run outside bypass mode.

Enable it with Shift+Tab until the footer shows "bypass permissions", by launching with `claude --dangerously-skip-permissions`, or with `"permissions": { "defaultMode": "bypassPermissions" }` in `.claude/settings.local.json` (which `/orca:doctor` offers).

Bypass mode applies to the **whole session**, not just the run, so a dedicated session is the clean choice. If you decline, `/orca:run` doesn't start the run and leaves the brief queued.

## Recovery

`/orca:status` shows where everything stands. Otherwise:

- **Interrupted run** (session died, killed, restarted) — run `/orca:run` again; it finds the run and resumes from the journal. Completed work replays instantly.
- **Blocked items** — kept on their branches with any work in progress saved as a `wip:` commit. `/orca:retry` resolves them with you and finishes them in the same run.
- **Follow-ups you want** — `/orca:followup` turns them into a new brief.
- **More changes before landing** — on a run's deliverable, by hand or through `/orca:review`'s address flow; on an objective, `/orca:open` for more decisions and phases, or `/orca:loop` for a small one.
- **Interrupted objective** — `/orca:open` in any session; an interrupted phase resumes with a fresh implementer from its files.
- **Landed runs piling up, or an objective you're done with** — `/orca:archive`.
- **Abandoned run** — prefer resuming; otherwise remove its `orca-*` worktrees (`git worktree list`) and `feature/<slug>*` branches. `/orca:status` prints the safe commands.
- **Plugin upgrades** — finish a run on the plugin version that started it. Resuming across an upgrade is best-effort.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `BARE_REPO: FAIL: conventional checkout` | Run `/orca:init` to convert the repository. |
| `CODEX: FAIL: codex not on PATH` or version too old | Install or upgrade Codex (`brew install codex` or release binaries, never npm). `/orca:doctor` walks you through it. |
| `CODEX: FAIL: not authenticated` | Run `codex login`, then check with `codex login status`. |
| `CODEX: FAIL: BASH_MAX_TIMEOUT_MS not set` | Run `/orca:doctor`, then start a fresh session. |
| `CODEX: FAIL: codex … has no 'codex exec' …` | Codex's CLI changed. Upgrade Codex if it's behind; otherwise update orca. Meanwhile, `/orca:config reviewer=claude`. |
| The run used the Claude reviewer unexpectedly | Codex wasn't detected. Fix it with `/orca:doctor`, or pin `reviewer=codex` so a broken Codex fails loudly. |
| `REVIEWER: FAIL: invalid reviewer` | Fix the `reviewer` key with `/orca:config`. |
| `PLUGIN_ROOT: FAIL: NO_PLUGIN_ROOT` | The plugin install is incomplete. Reinstall it. |
| `/orca:run` says there is no Workflow tool | Your Claude Code build lacks workflows; there is no fallback. |
| Run fails at `run-lease: no answer from orca's verb hook` | orca's hooks module isn't loaded. Enable function hooks, don't use `--bare`, remove any `disableAllHooks`, then resume. See [the verb hook](docs/verb-hook.md#failures). |
| Run fails at `run-lease: orca's verb hook refused … permission mode is …` | The session wasn't in bypass mode. Switch (Shift+Tab) and launch the run **fresh** — a resume would replay the refusal. |
| An item blocks with `orca.sh provision` / `worktree-item` `timed out in orca's verb hook` | Worktree setup took over ten minutes. Make `.orca/setup` faster (`/orca:doctor` can re-derive it), then `/orca:retry`. |
| An agent reports an unprovisioned tree, or `Provisioning: FAILED` | Missing or broken `.orca/setup`. Run `/orca:doctor` to derive one. See [provisioning](docs/worktrees.md#provisioning). |
| `git fetch` does nothing in a hand-made bare clone | Bare clones have no fetch refspec. Set `remote.origin.fetch`, or re-clone through `/orca:init`. |
| The status bar shows `FAIL: UNKNOWN_VERB` | A leftover `orca.sh statusline` block from an old version. `/orca:doctor` removes it. |

## Further documentation

- [Commands](docs/commands.md) — every skill in detail.
- [Anatomy of a run](docs/anatomy.md) — pre-flight gates, spec review, the work loop, escalation, the run band, the decision log, stage agents.
- [Objectives](docs/objectives.md) — the files and their formats, derived states, planning and plan review, the phase loop, follow-ups, archive, the objective band.
- [Worktrees, secrets, and provisioning](docs/worktrees.md) — the repository layout, `.orca/secrets/`, and the `.orca/setup` contract.
- [The verb hook](docs/verb-hook.md) — how the work loop runs shell steps, its guards, and its failure modes.
- [The orca CLI](docs/cli.md) — the `orca.sh` verbs.

## Development

| Path | Contents |
|---|---|
| `skills/<name>/SKILL.md` | The fourteen skills. |
| `agents/<stage>.md` | The twenty-four agents, loaded as `orca:<stage>`. |
| `scripts/orca.sh`, `scripts/lib.sh`, `scripts/verbs/` | The [orca CLI](docs/cli.md). |
| `scripts/*.workflow.js` | Workflow scripts: the work loop, the spec gate, research. |
| `hooks/` | The function-hooks module: the run band, the objective band, and the verb hook. `$.state` types in `types/index.d.ts`. |
| `tests/` | Bats suite (`bats tests/`) and hook tests (`claude plugin test .`). |

Commit with Conventional Commit messages and don't edit the version in `.claude-plugin/plugin.json`: CI bumps it on every push to `main` that changes shipped files, sized from the commit types.

Companion editors live in separate repositories: [orca.nvim](https://github.com/miguelbacalhau/orca.nvim) and [orca.vscode](https://github.com/miguelbacalhau/orca.vscode).

## License

[MIT](LICENSE)
