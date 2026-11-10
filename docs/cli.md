# The orca CLI

Every shell operation the plugin performs goes through one dispatcher:

```bash
bash <plugin-root>/scripts/orca.sh <verb> [args...]
```

`scripts/orca.sh` is a case statement that sources `scripts/lib.sh` (typed failures, framed output, base64 encoding, repository resolution, the config parser, the banned-attribution check) and then one file per verb from `scripts/verbs/`. The runtime envelope is bash 3.2, git ≥ 2.31, and coreutils.

Skills call verbs through the Bash tool; the work loop calls its subset through [the verb hook](verb-hook.md).

| Verb | What it does |
|---|---|
| `preflight` | Read-only environment validation — the [gate lines](anatomy.md#pre-flight). |
| `config show\|validate\|set\|clear\|reset` | Sole reader/writer of `.orca/config`: parsing, validation, merges, atomic writes. |
| `triage discover\|status\|snapshot` | Read-only discovery: interrupted and unlaunched runs with resume handles, lease state, queued briefs (`discover`); the git-footprint join (`status`) — an objective's branch and worktree join its directory under `.orca/objectives/` and get no housekeeping action; both combined with a ranked `ACTION:` list and `--run` fragment matching (`snapshot`). `--reports` adds the report-body `BLOCKED:`/`FOLLOWUP:` lines. |
| `triage claim\|release` | The per-run lease: `claim [--steal] [--runid]` (atomic mkdir) and `release`. |
| `triage archive\|unarchive` | Run retirement: `archive --scan` reports the gate, `archive <run-dir>` re-checks it and removes the run's landed worktrees and branches, `unarchive` recreates them. Both refuse an objective directory (`BAD_ARGS`): objectives retire through `objective archive`. |
| `decisions render` | Rebuilds `.orca/decisions.md` from trunk commit history. |
| `init-convert check\|convert\|cleanup\|recover` | `/orca:init`'s conventional-to-bare conversion: gates, NUL-safe untracked moves, a crash journal, recovery, and the manifest-checked cleanup. |
| `init-link check\|apply` | `/orca:init`'s root-linking of `.claude` and `CLAUDE.md`. |
| `codex` | The Codex reviewer's transport: `codex exec` read-only over a prompt file, the findings schema enforced, the payload written straight to the artifact path, under an 18-minute process-group watchdog. A failed review writes nothing and returns a retryable status. `--schema council` swaps in the claims schema and `--model` pins a Codex model — both for `/orca:council`'s `astra` seat; reviews use neither. |
| `council resolve` | `/orca:council`'s roster: the `council` key or the default, Codex detection (a default `astra` seat is dropped without Codex; a pinned one fails `NO_CODEX`), the checkout the seats explore, and a scratch directory for the Codex seat. |
| `loop snapshot\|check` | The commit step of an objective's phase loop: `snapshot` records the tree `git add -A` would commit against the latest review round and returns that same tree until a new review round exists; `check` judges the implementer's commit against it — `accepted`, `needs_commit`, `incomplete`, `diverged`, or a soft reset (`violation_reset` for a banned message, `content_reset` for content that differs from the snapshot). |
| `rounds next\|tree\|facts\|summary\|record` | The round engine over a phase directory's `reviews/` and `responses/`: `next` prints the phase loop's one next action (`implement`, `review`, `fix`, `fix-minor`, `fix-checks`, `ask-questions`, `ask-disputes`, `stalled`, `infeasible`, `drifted`, `commit`) with its round and that review's counts, guarding the work tree against changes made outside the loop; `tree` prints the tree a response's checks were of; `facts` gives `objective phase-done` the phase's findings, classed as `next` classes them; `summary` frames a findings file's severities and titles; `record` appends a user ruling (`checks-override`, `continue`, `decline`, `rereview`). The rules are in [Objectives](objectives.md#the-phase-loop) and the verb's header. |
| `objective new\|open\|current\|idle\|list\|digest\|plan-accept\|phase-add\|phase-start\|phase-done\|phase-block\|archive\|unarchive` | An objective's files under `.orca/objectives/`: creation with its branch (`new`), the session claim and worktree arrival, without provisioning (`open`, `current`, `idle`), the derived-state listing and the bounded digest (`list`, `digest`), the plan gate (`plan-accept`), the phase transitions with their report entries and follow-ups (`phase-add`, `phase-start`, `phase-done`, `phase-block`), and retirement (`archive`, `unarchive`). The files, rules, and typed failures are in [Objectives](objectives.md) and the verb's header. |
| `review discover\|open\|probe\|wait\|notes` | `/orca:review`'s deliverable discovery, editor/terminal resolution, probes, launch, and notes. `discover` follows each `DELIVERABLE:` with an `OBJECTIVE_DIR:` line when a live objective's `objective.md` names the branch (report or not), and a `REPORT:` line (`<report.md>`, `run` or `objective`) when a report names the branch as its deliverable — a live objective's first, else a run's. |
| `secrets place\|remove` | Links `.orca/secrets/` into a worktree as relative symlinks, or strips them. |
| `setup run\|verify\|status\|install` | Sole owner of `.orca/setup`: `run` executes it (closed stdin, captured output, 9-minute process-group watchdog), `verify` proves a candidate in a throwaway worktree, `status` is the cheap drift read, `install` writes it with its fingerprint. |
| `provision` | Worktree arrival: `secrets place`, then `setup run`. Advisory — a failed install is reported, not fatal. |
| `worktree-item` | The full worktree-arrival ritual for one item; `--no-provision` arrives without `provision` (the objective verbs' arrival). |
| `commit-prepare`, `commit-verify` | Whether the integration-fixes pass left anything to commit; the commit decision table, including the attribution check. |
| `merge-prepare`, `merge-finalize` | Self-heals the integration worktree before a merge (`merge --abort`, falling back to `reset --hard`); finalizes the squash. |
| `salvage` | Turns a blocked item's worktree into a `wip:` commit and removes it. |
| `archive attempt` | Archives a superseded attempt's plan and reviews to the first free `round<N>` / `prev<N>` slot. |
| `spec mark\|changed` | Hashes `spec.md`, and reports whether it moved since a mark. |
| `notes write` | Persists the integration fixer's notes into the run directory. |
| `self-test` | Smoke verb: proves dispatch, lib loading, and the frame path without touching a repository. |

Opaque values the prepare verbs and `spec mark` return are passed back unread by the work loop; the receiving verb rejects a malformed one.
