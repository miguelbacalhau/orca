---
description: Set up a repository's layout for orca runs — the bare-repo-with-worktrees structure with a default-branch worktree that orca:feature's pre-flight requires — plus an optional final step seeding the machine-local project context (.orca/map.md and decisions.md). Use when the user wants to prepare a new repository, an existing conventional checkout, or a fresh clone for orca runs, or when the pre-flight's layout gate (BARE_REPO) failed. Layout only: machine and session tooling (Codex CLI, MCP timeout, permissions) is orca:doctor's job. Interactive and consent-per-step — it restructures repositories, so every mutating action is confirmed first. Do not use to write a brief or run a feature.
args: <path or clone URL, optional>
user-invocable: true
disable-model-invocation: true
---

# Orca: init

Give a repository the layout orca:feature's pre-flight requires — fixed once per repo. The feature skill itself refuses to do this autonomously — converting a repo is the user's decision — and this skill is where that decision gets made: invoking it is the consent, and each mutating step confirms once more before acting.

The temperament is the opposite of an orca:feature run's: interactive throughout, consent per step, no autonomy. It runs once, so there is nothing to gain by not asking.

Layout only: machine and session tooling — the Codex CLI, the MCP tool timeout, permission modes — belongs to **orca:doctor**, and the subagent definitions and codex MCP server registration ship inside the orca plugin itself, so any session with the plugin has them.

## Step 1: Diagnose

If inside a git repository, run orca:feature's pre-flight first — it is read-only:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh preflight
```

The layout gate — `BARE_REPO` — is this skill's work list; fix it with Step 2 below. The machine lines (`REVIEWER`, `CODEX` — `PASS | FAIL | SKIPPED`) are reported but not fixed here: on a machine-gate `FAIL`, point at **orca:doctor**. If `BARE_REPO` already passes, say so and stop — anything else the pre-flight flagged is doctor's, not this skill's.

If not inside a repository, ask which case applies: initialize a new repository here, convert an existing checkout elsewhere, or clone a remote URL into the layout. A URL or path argument answers this without asking.

## Step 2: Repository layout

The target, in every case — including the **default worktree**, named after the default branch, which every case must end with:

```text
<repo-root>/
├── .bare/              # the bare repository (shared object store)
├── .git                # one line: gitdir: ./.bare
└── <default-branch>/   # the default worktree, e.g. main/
```

### New repository

Ask for the default branch name (default `main`), then:

```bash
mkdir -p <repo-root>
git init --bare <repo-root>/.bare -b <branch>
printf 'gitdir: ./.bare\n' > <repo-root>/.git
git -C <repo-root> worktree add --orphan -b <branch> <repo-root>/<branch>
```

`worktree add --orphan` needs git ≥ 2.42; on older git, create the worktree after an empty initial commit instead (`git -C <repo-root> commit --allow-empty -m "initial commit"` via a temporary worktree is not possible on a bare repo — upgrade git or use `git -C <repo-root>/.bare commit-tree` plumbing only if the user insists; upgrading is the sane path).

### Clone from a URL

```bash
git clone --bare <url> <repo-root>/.bare
printf 'gitdir: ./.bare\n' > <repo-root>/.git
git -C <repo-root> config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git -C <repo-root> fetch origin
```

The fetch-refspec line matters: bare clones get none, so `git fetch` silently updates nothing until it is set. Then resolve the default branch and create its worktree:

```bash
branch=$(git -C <repo-root> symbolic-ref --short HEAD)
git -C <repo-root> worktree add <repo-root>/$branch $branch
```

### Convert an existing conventional checkout

The delicate case: it restructures the repository in place, and **every path changes** — the working files move from `<repo-root>/` into `<repo-root>/<branch>/`, so open editors, terminal cwds, and IDE project configs all need re-pointing. The mechanical core — including the plugin's one data-loss step, moving every untracked file into the new worktree — is the bundled script's, NUL-safe so filenames with spaces or newlines survive; the consent gates stay here, one per mutating subcommand.

First the preconditions, read-only:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/init-convert.sh check
```

One typed line per gate — `CLEAN:` (no staged or unstaged changes; untracked files are fine, they are preserved below), `NO_WORKTREES:` (only the main checkout exists), `NO_SUBMODULES:` (worktrees and submodules interact badly; a submodule repo needs a manual plan, not this recipe) — plus informational `BRANCH:` and `UNTRACKED_COUNT:` lines for the restatement. On any `FAIL` — these gates or a typed `FAIL:` like `LINKED_WORKTREE` or `BRANCH_UNSAFE` (a namespaced branch such as `feature/foo` cannot be the default worktree's name — the layout needs a single path segment) — stop and tell the user how to clear it (commit or stash, remove the worktrees, check out a single-segment branch), never work around.

Present the before/after layout, naming the branch and the untracked count the check reported, and get explicit confirmation. Then:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/init-convert.sh convert
```

The script re-verifies the gates, then converts: records the untracked manifest (`git ls-files --others -z` — ignored files included, the `.env`s and caches a fresh checkout would lose), moves `.git` to `.bare`, sets `core.bare`, writes the `gitdir:` pointer file, creates the default worktree, and moves every manifest file into it preserving relative paths. It emits `MOVED:` and a `VERIFY:` summary (tracked files clean, untracked files arrived) and stops **before** the final top-level deletion — relay both lines to the user, and stop on any `VERIFY:` that is not clean-and-arrived rather than proceeding to the deletion.

The deletion is its own consent, exactly as before: what remains at the top level besides `.bare`, `.git`, `<branch>`, and `.orca` is the old tracked content, which the worktree now owns. Confirm with the user once more, then:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/init-convert.sh cleanup
```

It refuses — deleting nothing — unless the worktree exists and every manifest file reconciles (`MANIFEST_MISMATCH` names the count), then removes the leftovers with one `REMOVED:` line each.

Nothing in this touches history, refs, remotes, or config beyond `core.bare` — the conversion is layout-only and reversible until the cleanup (the script's `FAIL` details carry the exact reversal commands).

## Step 3: Verify

Re-run the pre-flight. `BARE_REPO` must now pass — that is this skill's deliverable. Report the machine lines too (`REVIEWER`, and `CODEX` as `PASS | FAIL | SKIPPED`): they cost nothing to relay, but a failing machine gate is fixed by **orca:doctor**, not here. Close by pointing at what comes next: `/orca:doctor` if a machine gate failed, then `/orca:feature` to capture a feature's intent and run it — after the optional seeding below.

## Step 4: Seed the project context (optional, consented)

Offer — never default — to seed the machine-local project context the runs consume: two files at `<repo-root>/.orca/` top level, outside every worktree and never committed. `map.md` is a codebase map at architecture altitude (module boundaries, entry points, build/test commands, conventions, known gotchas — no function-level detail), hard-capped at ~200 lines, headed by a commit stamp; `decisions.md` is the decision log, which starts empty. Both are caches over what git already shares — the map over the code, the log over commit-message history — so they are safe to delete and rebuild, and runs refresh them automatically; seeding here just spares the first run the sweep. State that and get consent; declining is fine — the first run seeds lazily instead.

On consent, spawn **one deep exploration subagent** — the only full-project sweep the design ever performs — to explore the default worktree read-only and write `<repo-root>/.orca/map.md`:

```markdown
# Codebase map

**As of:** <short-sha of the default branch tip>

<sections at the author's discretion: modules, entry points,
build & test, conventions, gotchas — file paths welcome, line
numbers and function bodies not>
```

Then create `<repo-root>/.orca/decisions.md` yourself, header only, same stamp:

```markdown
# Decision log

**As of:** <short-sha>
```

An empty repository (the new-repository case) has nothing to map — skip the offer and say why.

## Guidelines

- Every mutating action is announced and confirmed first; diagnosis is free.
- Never touch history, refs, or remotes. The conversion changes layout, not content.
- Layout only: never install tooling, write settings blocks, or change permission modes from here — that is orca:doctor's job, where each write has its own consent step.
- Stop rather than improvise on: a dirty tree, existing worktrees, submodules, or a repo whose layout is already bare-with-worktrees but differs from the target shape (report the difference instead).
- The default worktree is not optional: a bare store with no worktree strands the user, and orca:feature's deliverable — a branch to land — assumes they have a working copy to land it from.
