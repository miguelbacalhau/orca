# Worktrees, secrets, and provisioning

## Repository layout

What a repository looks like mid-run. `/orca:init` creates the top three entries; runs create the rest and clean up their transient worktrees.

```text
<repo-root>/
├── .bare/                        # the bare repository (shared object store)
├── .git                          # one line: gitdir: ./.bare
├── main/                         # your worktree(s) — never touched by runs
├── orca-<slug>/                  # integration worktree (branch feature/<slug>)
├── orca-<slug>-W1/               # one worktree per in-flight item (branch feature/<slug>-W1)
└── .orca/
    ├── config                         # optional per-repo overrides (/orca:config)
    ├── setup                          # optional worktree provisioning script
    ├── decisions.md                   # decision log, rendered from trunk history
    ├── secrets/                       # worktree secrets, linked into every run worktree
    ├── doctor/                        # scratch for /orca:doctor's provisioning pass
    ├── feat-briefs/                   # queued briefs (drafts/ for parked ones)
    ├── review-notes/<key>.json        # review comments per deliverable branch
    └── YYYYMMDD-HHMMSS-feat-<slug>/   # one directory per run
        ├── brief.md                   # the consumed brief
        ├── spec.md                    # spec, work breakdown, Decisions log, workflow runId
        ├── report.md                  # final run report
        ├── merged.tsv                 # one <ID>	<sha> row per landed item
        ├── plans/                     # one plan per item (<ID>.round<N>.md = superseded)
        └── reviews/                   # raw findings JSON per review round
```

- `orca-*` **directory** names are local and never enter git. **Branch** names (`feature/<slug>[-<ID>]`) carry no orca trace.
- `.orca/` sits outside every worktree, so nothing in it can be committed by accident. It is machine-local.
- Everything in `.orca/` is safe to delete **except `secrets/`**, which holds your only copy of those files, and `review-notes/`, which holds your unaddressed comments.

## Secrets

`git worktree add` only materializes tracked files, so a fresh worktree lacks your `.env`s and local credentials. Drop a file into `<repo-root>/.orca/secrets/` and every worktree a run creates from then on has it. **The tree is the mapping** — a file's path inside `secrets/` is its path inside each worktree:

```text
.orca/secrets/.env               →  <worktree>/.env
.orca/secrets/apps/api/.env      →  <worktree>/apps/api/.env
.orca/secrets/config/local.json  →  <worktree>/config/local.json
```

- Each file is placed as a **relative symlink** to the one canonical copy: rotate a token once and every worktree sees it; removing a worktree removes only links.
- A destination git would track is skipped (`UNIGNORED:` in the run's logs) — keep the paths in `.gitignore`. An existing real file is never overwritten.
- Secrets are linked in for implement, fix, and integrate, and stripped before every review (with codex, that keeps them away from a second model provider).
- Stage agents can read placed secrets: keep **development** credentials here, never production ones, and only what runs actually need.

Populating the tree is manual — one `mv` per secret. After an `/orca:init` conversion, move the preserved files from your worktree:

```bash
mkdir -p .orca/secrets/apps/api && mv main/apps/api/.env .orca/secrets/apps/api/.env
```

Runs never write into your own worktree. Link it yourself, by hand (`ln -s ../.orca/secrets/.env main/.env`) or with:

```bash
bash <plugin-root>/scripts/orca.sh secrets place <repo-root>/main
```

## Provisioning

The other half of what `git worktree add` leaves out is everything a repository builds rather than tracks: `node_modules`, generated code, compiled artifacts. One optional script covers it: **`<repo-root>/.orca/setup`**, machine-local and never committed.

It runs on **every worktree arrival**, right after secrets are placed, and again on the integration worktree before integration verification. Reviews don't run it.

### The contract

| | |
|---|---|
| Invocation | `bash .orca/setup` — the exec bit is irrelevant |
| Working directory | the worktree being provisioned |
| `stdin` | `/dev/null` — a prompting package manager fails instead of hanging |
| Output | both streams captured; on failure the tail reaches the agent |
| `ORCA_WORKTREE` | absolute path of the worktree (= cwd) |
| `ORCA_REPO_ROOT` | the directory holding `.orca/` — for sharing caches or build outputs |
| `ORCA_ARRIVAL` | `created` \| `branch_resumed` \| `reused` \| `integrate` |
| Wall-clock cap | 9 minutes, then the whole process group is killed |

The script must be:

- **Idempotent and cheap when warm** — `npm install`, not `npm ci`.
- **Safe with eight copies running at once** — package managers are; a hand-rolled write to one shared path is not.
- **Non-interactive** — no servers, watchers, fixed ports, or shared-database migrations.

Dependency installs, codegen, and compiling to artifacts belong in it. Test suites don't — that's the stage agents' job.

**Provisioning is advisory.** A failing script doesn't stop the item: the failure and the last 4 KB of output reach the agent as a `Provisioning: FAILED` line.

### Getting a script

Write it by hand, or run `/orca:doctor`, whose consented deep pass has the `orca:doctor` agent derive one from the repo's own evidence — an existing worktree-spawn script, then `devcontainer.json`, then CI steps, then manifests and lockfiles — and prove it in a throwaway worktree by running the repo's build. You read the script before it is installed. `/orca:init` offers the same pass.

"Needs nothing" is a valid answer: a body of `exit 0` under a header recording what was inspected. The installed script carries a fingerprint of the repo's manifests, lockfiles, task runners, toolchain pins, and CI, so `orca.sh setup status` can report `drifted` and name what changed.

To provision your own worktree the way runs do (secrets, then setup):

```bash
bash <plugin-root>/scripts/orca.sh provision <repo-root>/main reused
```
