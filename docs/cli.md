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
| `triage discover\|status\|snapshot` | Read-only discovery: interrupted and unlaunched runs with resume handles, lease state, queued briefs (`discover`); the git-footprint join (`status`); both combined with a ranked `ACTION:` list and `--run` fragment matching (`snapshot`). `--reports` adds the report-body `BLOCKED:`/`FOLLOWUP:` lines. |
| `triage claim\|release` | The per-run lease: `claim [--steal] [--runid]` (atomic mkdir) and `release`. |
| `triage archive\|unarchive` | Run retirement: `archive --scan` reports the gate, `archive <run-dir>` re-checks it and removes the run's landed worktrees and branches, `unarchive` recreates them. |
| `decisions render` | Rebuilds `.orca/decisions.md` from trunk commit history. |
| `init-convert check\|convert\|cleanup\|recover` | `/orca:init`'s conventional-to-bare conversion: gates, NUL-safe untracked moves, a crash journal, recovery, and the manifest-checked cleanup. |
| `init-link check\|apply` | `/orca:init`'s root-linking of `.claude` and `CLAUDE.md`. |
| `codex` | The Codex reviewer's transport: `codex exec` read-only over a prompt file, the findings schema enforced, the payload written straight to the artifact path, under an 18-minute process-group watchdog. A failed review writes nothing and returns a retryable status. `--schema council` swaps in the claims schema and `--model` pins a Codex model — both for `/orca:council`'s `astra` seat; reviews use neither. |
| `council resolve` | `/orca:council`'s roster: the `council` key or the default, Codex detection (a default `astra` seat is dropped without Codex; a pinned one fails `NO_CODEX`), the checkout the seats explore, and a scratch directory for the Codex seat. |
| `review discover\|open\|probe\|wait\|notes` | `/orca:review`'s deliverable discovery, editor/terminal resolution, probes, launch, and notes. |
| `secrets place\|remove` | Links `.orca/secrets/` into a worktree as relative symlinks, or strips them. |
| `setup run\|verify\|status\|install` | Sole owner of `.orca/setup`: `run` executes it (closed stdin, captured output, 9-minute process-group watchdog), `verify` proves a candidate in a throwaway worktree, `status` is the cheap drift read, `install` writes it with its fingerprint. |
| `provision` | Worktree arrival: `secrets place`, then `setup run`. Advisory — a failed install is reported, not fatal. |
| `worktree-item` | The full worktree-arrival ritual for one item. |
| `commit-prepare`, `commit-verify` | Whether the integration-fixes pass left anything to commit; the commit decision table, including the attribution check. |
| `merge-prepare`, `merge-finalize` | Self-heals the integration worktree before a merge (`merge --abort`, falling back to `reset --hard`); finalizes the squash. |
| `salvage` | Turns a blocked item's worktree into a `wip:` commit and removes it. |
| `archive attempt` | Archives a superseded attempt's plan and reviews to the first free `round<N>` / `prev<N>` slot. |
| `spec mark\|changed` | Hashes `spec.md`, and reports whether it moved since a mark. |
| `notes write` | Persists the integration fixer's notes into the run directory. |
| `self-test` | Smoke verb: proves dispatch, lib loading, and the frame path without touching a repository. |

Opaque values the prepare verbs and `spec mark` return are passed back unread by the work loop; the receiving verb rejects a malformed one.
