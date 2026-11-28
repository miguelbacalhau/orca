# Worktrees, secrets, and provisioning

## Repository layout

What a repository looks like mid-run. `/orca:init` creates the top three entries; runs create the rest and clean up their transient worktrees.

```text
<repo-root>/
├── .bare/                        # the bare repository (shared object store)
├── .git                          # one line: gitdir: ./.bare
├── main/                         # your worktree(s) — never touched by runs; where you work and start sessions
├── orca-<slug>/                  # a run's integration worktree, or an objective's worktree (branch feature/<slug>)
├── orca-<slug>-W1/               # one worktree per in-flight item (branch feature/<slug>-W1)
└── .orca/
    ├── config                         # optional per-repo overrides (/orca:config)
    ├── setup                          # optional worktree provisioning script
    ├── decisions.md                   # decision log, rendered from trunk history
    ├── secrets/                       # worktree secrets, linked into every run worktree
    ├── doctor/                        # scratch for /orca:doctor's provisioning pass
    ├── feat-briefs/                   # queued briefs (drafts/ for parked ones)
    ├── review-notes/<key>.json        # review comments per deliverable branch
    ├── objectives/<YYYYMMDD-HHMMSS>-<slug>/  # one directory per objective (see objectives.md)
    └── YYYYMMDD-HHMMSS-feat-<slug>/   # one directory per run
        ├── brief.md                   # the consumed brief
        ├── spec.md                    # spec, work breakdown, Decisions log, workflow runId
        ├── report.md                  # final run report
        ├── merged.tsv                 # one <ID>	<sha> row per landed item
        ├── plans/                     # one plan per item (<ID>.round<N>.md = superseded)
        └── reviews/                   # raw findings JSON per review round
```

- `main/` (the default worktree) is where you work **and** where Claude Code sessions start: it loads the repository's own `CLAUDE.md` and `.claude/`, and orca's [pin hook](pin-hook.md) starts each stage agent in its own `orca-*` worktree. A session started there reaches the `orca-*` worktrees and `.orca/` once the repository root is in `permissions.additionalDirectories` — `/orca:doctor` writes it. Starting sessions at `<repo-root>` still works and needs no setting.
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

- Each entry is placed as a **relative symlink** to it: rotate a token once and every worktree sees it; removing a worktree removes only links.
- A destination git would track is skipped (`UNIGNORED:` in the run's logs) — keep the paths in `.gitignore`. An existing real file is never overwritten.
- Secrets are linked in for implement, fix, and integrate, and stripped before every review (with codex, that keeps them away from a second model provider).
- Stage agents can read placed secrets: keep **development** credentials here, never production ones, and only what runs actually need.

### Link the store to your own files

An entry can be the file itself or **a link to your real copy in the default worktree**. A link is the recommended setup: runs read your `.env` as it is right now, and there is no second copy to fall behind when you add a variable or re-pull your environment. `/orca:doctor` and `/orca:init` list the env files your default worktree has and the store doesn't link, ask once which of them runs should get, and link those:

```bash
bash <plugin-root>/scripts/orca.sh secrets link .env apps/api/.env
```

`secrets link` writes only what `secrets status` offers: an ignored, untracked `.env`, `.env.*`, or `.envrc` in the default worktree with no entry (`UNLINKED`), or a store copy of such a file whose bytes are identical (`LINKABLE`), which it replaces with the link. An entry already linked is reported `OK` only while its file is still there and still offered. Every other path is refused by name and left alone — a tracked or unignored file, any other file name, a copy that has drifted (`COPY_DIFFERS`), a path whose directory inside the store is itself a symlink (`IRREGULAR_PARENT`). It works from the default worktree, the repository root, or any directory inside the repository.

Placement links point at the entry, never past it, so a tool that rewrites your `.env` by replacing the file (most do) keeps every run worktree current. Placing into the worktree that holds the real file reports it as `SOURCE` and writes nothing. If the linked file is gone, the entry is skipped (`SKIPPED_DANGLING`) and its links in run worktrees are removed.

Because every worktree's placed file is a link that ends at your own file, an agent that **edits** a placed `.env` in its worktree edits your default worktree's file. That has always been so for a linked entry, and the [pin hook](pin-hook.md)'s edit guard does not change it: it judges the path an agent names, not where a link leads.

A plain file in the store still works. Use one for a file no worktree of yours holds, such as dev-only credentials kept apart from what your own environment uses. Keep in mind that whatever an entry links to is what stage agents read: if you point `main/.env` at staging while debugging, runs get staging too.

To see where the store stands, `/orca:doctor` runs the read-only:

```bash
bash <plugin-root>/scripts/orca.sh secrets status
```

It lists every entry; a store copy of a file the default worktree also holds (`COPY`, `SAME` or `DIFFERS`, the drift case), followed by `LINKABLE` when `secrets link` accepts it; ignored `.env`, `.env.*`, and `.envrc` files in the default worktree with no entry (`UNLINKED`); and entries whose linked file is gone (`DANGLING`). `secrets link` takes the `UNLINKED` and `LINKABLE` files; a drifted copy or a dangling entry is yours to settle by hand, and each comes with the `ln -s` target to use.

If you followed the older setup, with the real file in the store and `main/.env` linking to it, flip it once:

```bash
rm main/.env && mv .orca/secrets/.env main/.env && ln -s ../../main/.env .orca/secrets/.env
```

## Provisioning

The other half of what `git worktree add` leaves out is everything a repository builds rather than tracks: `node_modules`, generated code, compiled artifacts. One optional script covers it: **`<repo-root>/.orca/setup`**, machine-local and never committed.

It runs on **every worktree arrival**, right after secrets are placed, and again on the integration worktree before integration verification. An objective's worktree is provisioned the same way, by the `orca:provision` agent after the session's `objective phase-start` — and, as a warm-up, after `orca:objective-open`'s `objective open` when the session is not heading straight into the phase loop; both verbs arrive without it. Reviews don't run it.

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
