# orca

A Claude Code plugin for autonomous multi-agent development: `/orca:feature` takes an idea to a committed integration branch, `/orca:debug` takes a symptom to a verified diagnosis and fix. Runs happen in isolated git worktrees, every stage runs in its own subagent, and an independent reviewer (Codex by default, Claude as fallback) attacks each result before it is committed. The README is the authoritative deep description.

**`/orca:debug` is abandoned for now** — it is not being used or worked on. Its skill, agents (`reproduce`, `hypothesize`, `verify`, `diagnose`), and `debug-loop.workflow.js` remain in the tree but should not receive new work unless explicitly asked.

## Layout

- `skills/<name>/SKILL.md` — the thirteen user-facing skills (`feature`, `debug`, `review`, …). Interview instructions live beside them (`skills/feature/interview.md`).
- `agents/<stage>.md` — the twenty stage agents, loaded as `orca:<stage>`.
- `scripts/` — the deterministic core:
  - `orca.sh` + `lib.sh` + `verbs/*.sh` — the orca CLI: one case-statement dispatcher, a shared lib, one sourced file per verb. Every shell operation the plugin performs goes through this.
  - `*.workflow.js` — the Workflow-tool scripts (work loop, debug loop, spec gate, research, prototype). Plain JS, no Node APIs, no TypeScript.
- `tests/*.bats` — Bats suite with hermetic git fixtures (`tests/helpers.bash`). Run with `bats tests/`.
- `plans/` — design docs for features of orca itself; not shipped.
- `.claude-plugin/plugin.json` — the manifest.

## Design rules

- **Determinism in scripts, judgment in agents.** Scheduling, retries, gating, and git plumbing are code (workflow scripts, shell verbs); anything requiring judgment is a schema'd agent call whose reasoning lands in run artifacts. Don't move logic from scripts into prose instructions or vice versa.
- **State lives in files** under the target repo's `.orca/` (brief, spec, plans, findings, report), never in conversation memory.
- **Shell conventions** (see the header comment in `scripts/lib.sh`): typed failures via `fail`, framed output, base64 relay encoding, absolute-path sourcing, sentinel guard against double-sourcing. Runtime envelope is bash 3.2 + git ≥ 2.31 + coreutils — nothing else.
- No commit produced by an orca run may mention Claude, AI, agents, or orca (`is_banned` in `lib.sh` enforces this).

## Workflow

- Commit directly to `main` — no feature branches in this repo.
- **Never edit the `version` in `plugin.json`.** CI (`.github/workflows/version-bump.yml`) bumps it on every push to main that touches shipped files, sized by Conventional Commits. Pull after pushing to pick up the bot's bump commit.
- Use Conventional Commit messages (`feat:`, `fix:`, `chore:`, …) — CI sizes version bumps from them. Never reference Claude, AI, or co-authorship trailers in commit messages.
- When changing shell scripts or workflows, run the relevant `tests/*.bats` file; add coverage for new verbs or lib functions.
