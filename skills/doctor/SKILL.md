---
description: Diagnose and fix what orca runs depend on, on two axes. Machine readiness — the Codex CLI (presence, version, authentication), the `MCP_TOOL_TIMEOUT` settings write, stale orca status line settings cleanup (the verb is retired; leftover blocks break the status bar), the reviewer resolution (codex or claude, pinned or detected), and the optional orca.nvim / orca.vscode install checks for reviewing deliverable branches in the user's editor. Repo readiness — whether fresh worktrees are provisioned: the `.orca/setup` script that installs dependencies and builds artifacts in every run worktree, whether it is absent, current, or drifted since the repo's manifests moved, and an offered deep pass that derives one from the repo's own evidence and proves it in a throwaway worktree. Use when orca:feature's pre-flight fails a machine gate, when codex install/auth/timeout problems need walking through, when an implement agent reports an unprovisioned tree or a `Provisioning: FAILED` line, or when the user wants to check which reviewer runs will use. Not for repository layout — the bare-repo-with-worktrees conversion is orca:init's job — and not for run state, which is /orca:status's. Does not start runs. Interactive and consent-per-step: diagnosis is free, every write is confirmed first.
args: <optional focus, e.g. "codex" or "timeout">
user-invocable: true
disable-model-invocation: true
---

# Orca: doctor

Make things ready for orca runs, on two axes: the **machine** (the Codex CLI, its auth, the MCP tool timeout, the editor companions) and the **repository** (whether a fresh worktree arrives provisioned). Repository *layout* — the bare-with-worktrees conversion — is orca:init's job and stays out of scope; repository *readiness* is this skill's.

The line between doctor and `/orca:status` is one test: **would the answer change if no run had ever happened?** If no, it is readiness and belongs here. If it depends on what a run did — a blocked item, a missing branch, a stale lease — it is status's, or triage's, or retry's. `.orca/setup` passes that test: it is configuration, the third thing beside `.orca/config` and `.orca/secrets/` that makes a repo ready, and missing-or-stale is true or false with no run in sight. Provisioning failures *manifest* during runs and are caused by static readiness; they resolve here.

The temperament is like init's: interactive, diagnosis free, consent before every mutating step. Doctor mostly *prescribes* — codex installs come from brew or release binaries by the user's hand, and auth is inherently the user's interactive action; the only things it writes are settings blocks and, through the consented deep pass, one file under `.orca/`.

## Step 1: Diagnose

**Inside a git repository**, run orca:feature's pre-flight from the project root — read-only, and its output is the work list:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh preflight
```

Report every gate in plain language: `BARE_REPO` (`PASS | FAIL`), the `REVIEWER:` line (which reviewer, pinned by `.orca/config` or detected from the machine), and `CODEX` (`PASS | FAIL | SKIPPED` — skipped means the resolved reviewer is claude and the codex checks deliberately did not run). A `REVIEWER: FAIL` means the config key is invalid — point at orca:config; nothing here edits that file.

Then the repo axis, two cheap reads. First, whether worktrees get provisioned:

```bash
cd <repo-root> && bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh setup status
```

Read-only, milliseconds, creates nothing. Render its `SETUP:` verdict in plain language, using the `SETUP_LINES:`/`SETUP_SOURCES:`/`SETUP_VERIFIED:` lines for the detail:

- `absent` → "worktrees are not provisioned — every run worktree starts with tracked files and secrets only, so each implement agent rediscovers the package manager or skips it." Offer Step 4.
- `current <fp>` → healthy. An `exit 0` body (`SETUP_LINES: 1`) is the needs-nothing case: "checked <the date from `SETUP_VERIFIED:`>, this repo needs no install step". Anything larger: "an N-line setup script, verified <the record>".
- `drifted <fp>` plus `CHANGED:` lines → name the paths that moved ("a `pnpm-lock.yaml` appeared since this was derived") and offer Step 4 to re-derive.
- `unstamped` → the script was written by hand or edited past `setup install`, so its drift check is dead. Say that, and offer Step 4 to verify and re-stamp it.

Second, one glance at the secrets tree — `ls <repo-root>/.orca/secrets/` — reported as a fact, not a judgment: absent, empty, or N files. Orca cannot know which untracked files this repo's build needs; the number is context for the user, and the deep pass's report says what the install actually reached for.

Whenever the resolved reviewer is codex, add the one probe the script cannot run — the **live MCP probe**, from this session: call ToolSearch with `select:mcp__plugin_orca_orca-codex__codex`. Missing while the codex gates pass means review agents cannot reach codex, and the cause is one of two. First check whether the project carries MCP config of its own — a `.mcp.json` at the repo root, or local-scope servers (`claude mcp list` shows both): a known harness bug (present as of Claude Code 2.1.202) loads none of a plugin's bundled MCP servers when any such config exists. A leftover `codex` registration is redundant — the plugin bundles the server — so prescribe removing it, never remove it yourself; if the project genuinely needs its own MCP servers, the workaround is pinning `reviewer=claude` via orca:config, trade-off stated. Otherwise the session predates the plugin's install or enablement. Both remedies end in a fresh session, so name that alongside the other restart caveats.

**Outside a git repository**, run in machine-only mode: say up front that the layout gate, the reviewer pinning, and the whole repo axis (provisioning, secrets) are per-repo and unchecked here — Step 4 does not apply either. Probe codex directly with the same checks the pre-flight runs — binary on PATH, `codex --version` against the minimum version the preflight names (read `codex_min_version` from `${CLAUDE_PLUGIN_ROOT}/scripts/verbs/preflight.sh` rather than reciting a remembered one), `codex login status`, and `MCP_TOOL_TIMEOUT` in a settings env block. Treat the resolved reviewer as detected-only, and offer the timeout write to `~/.claude/settings.json` only (there is no project settings file to offer).

## Step 2: Route layout failures away

`BARE_REPO: FAIL` is not this skill's work: point at **orca:init**, which converts interactively and preserves untracked files. Never restructure a repository from here — not even a "quick" conversion the user asks for mid-diagnosis; hand them to init where the confirmations live.

## Step 3: Fix the machine gates — consent per step, reviewer-aware

What there is to fix depends on the resolved reviewer:

**Reviewer codex (pinned or detected).** The run's review path is the global codex binary's MCP server, so every codex gate must pass. Fix only what the diagnosis flagged, in order:

- **Binary missing or stale** — codex is **never installed via npm**: no `npm i -g @openai/codex`, no vendored binary. Surface the official non-npm install (`brew install codex`, or the GitHub release binaries) and let the user run it; re-check the version after.
- **Not authenticated** — authentication is interactive and the user's own action: suggest they run `! codex login` in this session, then verify with `! codex login status`.
- **`MCP_TOOL_TIMEOUT` unset** — the reviewer runs through the codex MCP server the orca plugin bundles, but the timeout that governs MCP tool calls is a *client-side* env setting a plugin cannot ship: write `"MCP_TOOL_TIMEOUT": "1200000"` (~20 minutes) into the `env` block of `.claude/settings.local.json` (or the user's `~/.claude/settings.json`, their choice), merged into any existing file rather than overwriting. Not larger: the workflow retries reviews at two levels, so this value multiplies into the worst case per item; at ~20 minutes that worst case stays around 80 minutes, where 1 hour would balloon it to several hours. Caveat to state after writing: settings env loads at **session start** — a fresh session is needed before the value takes effect.

**Reviewer claude (detected — codex absent).** Nothing to fix: runs will use the Claude reviewer (`orca:review-claude`), which keeps fresh-context independence — a separate agent, only the artifacts and the diff, an adversarial contract — but is same-model. Say that installing codex enables cross-model review, the stronger design: a different model family does not share the implementer's blind spots. Offer to pin either choice via **orca:config** (`reviewer=claude` to make the fallback explicit, `reviewer=codex` after installing); the write itself belongs to orca:config, not here.

**Reviewer claude (pinned) with codex present.** The codex gates were skipped by choice; nothing to do. Mention that `orca:config reviewer=codex` (or `reviewer=default`) re-enables cross-model review if the pin has outlived its reason.

## Step 4: Repo readiness — the deep pass, offered and never defaulted

This is the one expensive thing doctor does, so it is offered with its cost stated and never started on its own. Offer it when Step 1's `SETUP:` line was `absent`, `drifted`, or `unstamped` — or when the user arrived with a provisioning symptom (an implement agent that reported an unprovisioned tree, a `Provisioning: FAILED` line in a run, "builds don't work in orca worktrees"). A `current` verdict needs nothing; say so and move on.

State the cost before asking, in one sentence: *it creates a throwaway worktree under `.orca/doctor/`, runs a candidate install inside it under your permissions, removes it afterwards, and takes a few minutes.* That sentence is the consent — it covers executing the candidate during verification, which is the design's point: routing every repair round back through the user turns the agent into a proposal writer and the user into the verifier.

On consent, spawn the **`orca:doctor`** agent with a task message carrying: the repository root, the trunk branch (the preflight's `TRUNK_CANDIDATE:`), the scratch directory `<repo-root>/.orca/doctor/`, the **plugin root** — the substituted value of `${CLAUDE_PLUGIN_ROOT}`, spelled out, because that substitution does not reach a subagent's shell and the agent runs the verb itself — the current `.orca/setup` **verbatim with its header** when one exists, the `orca.sh setup status` output from Step 1, and which skill is asking (doctor). One report contract serves doctor and init alike.

It returns a report and leaves a candidate at `<scratch>/candidate`. Then:

1. **Present the candidate body verbatim**, followed by the report — the `What it excluded, and why` section especially. A script that would run migrations against a shared database, launch servers, or write to a path eight worktrees share is exactly what the user is here to catch, and they can only catch it by reading it.
2. **Re-run the verification yourself**, on the final candidate, rather than trusting the agent's account of it:

   ```bash
   cd <repo-root> && bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh setup verify <scratch>/candidate --check '<the check the report names>'
   ```

   Report the frame. The approval gate rests on a frame this skill produced — the same discipline as orca:audit checking a report against git rather than against its own claims.
3. **Ask once.** On consent, install through the verb — never `cp` the file by hand, because only `install` computes the fingerprint and writes the provenance header the drift check reads:

   ```bash
   cd <repo-root> && bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh setup install <scratch>/candidate \
     --sources '<the paths the report's Source used names, space-separated, or ->' \
     --verified 'rc=0 check_rc=0 seconds=94 check="<cmd>"'
   ```

Three outcomes, three endings. **`derived`** installs the candidate as above. **`needs-nothing`** installs the `exit 0` candidate under the same consent — the file's presence is what records that the repo was checked, and its fingerprint is what will notice a `package.json` appearing next year. **`undetermined`** installs nothing: relay the report's Open questions, ask the rank-7 question in the user's own terms ("what do you run in a fresh clone before you can build?"), and offer to re-run the pass with their answer.

Two things this step never does. It never writes into `.orca/secrets/` or proposes moving files there — that tree is the one thing in `.orca/` whose deletion is data loss, and it has its own consent story; the report's `Secrets it expects` section is an observation for the user to act on. And it never installs anything on the machine: the deep pass writes one file under `.orca/`, which is why init's "never install tooling" guideline survives it.

## Step 5: Optional — offered, never defaulted

**`bypassPermissions`.** Runs need it, but per-session gating stays a per-session decision: never prescribe writing `bypassPermissions` into `settings.local.json` or any settings file — a persistent default disables the approval gate for every session opened in that worktree, not just orca runs. When it comes up, say the mode is toggled per session with Shift+Tab and the run skills gate on it conversationally.

**The orca.nvim install check.** Per-machine (offered in machine-only mode too — the probe subcommand needs no git repository). The Neovim companion lives in its own repository, [`miguelbacalhau/orca.nvim`](https://github.com/miguelbacalhau/orca.nvim); its `:OrcaReview` opens a deliverable branch's merge-base diff in the user's own editor. This same probe gates **orca:review** — the skill that opens that review in a tmux window — so a failed prescription here is what turns orca:review into its print-only fallback (or a loud FAIL, when `editor=nvim` is pinned). Doctor prescribes; it never edits the user's nvim config. Probe with the exact check orca:review runs:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh review probe nvim
```

- `PROBE_OK: nvim` → installed and reachable. One more check before calling it healthy — the **version handshake**: orca.nvim's review comments (`:OrcaComment`) round-trip through `.orca/review-notes/<key>.json`, and plugin and skill ship separately, so either side refuses a schema version it doesn't speak. Diagnose the skew *before* a review session, not after one:

  ```bash
  nvim --headless "+lua io.write(require('orca.notes').VERSION)" +qa!
  ```

  Compare against the version orca speaks — `NOTES_VERSION_SPOKEN` in `${CLAUDE_PLUGIN_ROOT}/scripts/verbs/review.sh` (read it rather than reciting a remembered one). Equal → healthy, report it. The plugin's number higher → prescribe updating the orca plugin; lower (or the probe errors — a pre-comments orca.nvim has no `orca.notes` module) → prescribe updating orca.nvim via the manager's update flow or `git -C <clone> pull`. A skew doesn't break opening reviews — orca.nvim disables commenting rather than clobber a newer file, and orca:review refuses to touch a version it doesn't know — but comments won't round-trip until the older side updates.
- `PROBE_FAILED: nvim  nvim not on PATH` → no Neovim on this machine; skip silently.
- Any other `PROBE_FAILED` → prescribe installing `miguelbacalhau/orca.nvim` with the user's plugin manager — one lazy.nvim line as illustration (`{ "miguelbacalhau/orca.nvim" }`), no manager detection, and never write into their nvim config. For users who run no plugin manager, offer — consented like every write — a clone into Neovim's native packpath: `git clone https://github.com/miguelbacalhau/orca.nvim <stdpath('data')>/site/pack/orca/start/orca.nvim` (resolve the path by asking nvim itself: `nvim --headless "+lua io.write(vim.fn.stdpath('data'))" +q`), then `nvim --headless "+helptags <clone>/doc" +q` and re-probe. Caveat to state when the clone path is chosen: native packages require `packpath` intact — configs that reset it (plugin managers commonly do) ignore the clone silently, so if the re-probe still says `no`, the manager route is the fix.

Updates ride the manager's own update flow, or `git -C <clone> pull` for clone installs — doctor can run the pull on request. Uninstall is symmetric: remove via the manager, or `rm -rf` the clone.

Machine hygiene, pre-release only: the never-shipped symlink design left links on dev machines (`site/pack/orca/start/orca.nvim` → a checkout's `nvim/`). A *symlink* at the clone path is one of those — offer to replace it with a real install. No user-facing migration story is needed; v1 was never released.

Verification is in-editor: `:checkhealth orca`.

**The orca.vscode install check.** Per-machine (offered in machine-only mode too — the probe subcommand needs no git repository). The VS Code companion lives in its own repository, [`miguelbacalhau/orca.vscode`](https://github.com/miguelbacalhau/orca.vscode); its "Orca: Review" opens a deliverable branch's merge-base diff in the user's own VS Code. This same probe gates **orca:review**'s vscode tier — a failed prescription here is what turns orca:review into its print-only fallback (or a loud FAIL, when `editor=vscode` is pinned). Doctor prescribes; it never installs. Probe with the exact check orca:review runs:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh review probe vscode
```

- `PROBE_OK: vscode` → installed; nothing to do — report it.
- `PROBE_FAILED: vscode  code CLI not on PATH` → skip silently (`code` not being on PATH on a machine with VS Code installed usually means the "Install 'code' command in PATH" palette action hasn't been run; mention that only if the user asks about VS Code).
- `PROBE_FAILED` naming the extension → prescribe the VSIX from the [latest GitHub release](https://github.com/miguelbacalhau/orca.vscode/releases):

  ```bash
  code --install-extension <path-to-downloaded>/orca-vscode-<version>.vsix
  ```

  Marketplace publish is deferred until the extension stabilizes, so the release VSIX is the install path. Updates are the same command with a newer VSIX; uninstall is `code --uninstall-extension miguelnjacinto.orca-vscode`. Forks that alias `code` (Cursor, VSCodium, code-insiders) are not probed for — one binary, one id, on purpose.

**The stale orca status line check.** Per-user (runs in machine-only mode too — settings files need no repository). Earlier plugin versions offered a `statusLine` settings block invoking `orca.sh statusline`; the verb is retired, and a leftover block prints a `FAIL: UNKNOWN_VERB` frame into the status bar on every refresh. Read the `statusLine` key in `~/.claude/settings.json` and, inside a repository, the project's `.claude/settings.local.json`; if a command invoking `orca.sh statusline` is present, offer to remove the block (when it is chained inside the user's own script, point at the exact line to delete instead) — consented like every settings write. A `statusLine` that never mentions orca is not orca's business: never touch it.

## Step 6: Verify

Re-run the pre-flight (inside a repository) or the direct codex probes (machine-only) and report gate by gate, plus `orca.sh setup status` when Step 4 ran — a fresh `current <fingerprint>` is that step's deliverable. Name what remains on the user rather than glossing it: a `codex login` not yet done, a session restart pending before the settings env loads, a rank-7 question still unanswered. Close by pointing at the workflow the machine is now ready for: `/orca:feature` to capture a feature's intent and run it — or `/orca:init` first if the layout gate is the one still failing.

## Guidelines

- Diagnosis is free; every write is announced and confirmed first. Binaries and auth remain the user's actions — surface the command, never run installs or logins autonomously.
- Never touch repository layout, history, refs, or remotes — that is orca:init's territory.
- Never edit `.orca/config` — pinning or clearing the reviewer belongs to orca:config; recommend it by name instead. `.orca/setup` is the one file this skill writes, and only through `setup install`, only after the user has read the candidate.
- Never touch `.orca/secrets/` — it is the one thing in `.orca/` whose deletion is data loss. Observe and report; the user populates it.
- Readiness only, never run state. A missing branch, a blocked item, a stale lease, a leftover worktree: point at `/orca:status` and stop.
- A codex gate failing while the reviewer is codex is a failure to fix, never a reason to suggest silently switching the reviewer — swapping the reviewer out from under a codex user is a decision, so it goes through orca:config with the trade-off stated.
