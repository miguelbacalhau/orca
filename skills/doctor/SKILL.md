---
description: Diagnose and fix the machine and session tooling orca runs depend on — the Codex CLI (presence, version, authentication), the `MCP_TOOL_TIMEOUT` settings write, the reviewer resolution (codex or claude, pinned or detected), the optional `bypassPermissions` default-mode write, and the optional orca.nvim / orca.vscode install checks/prescriptions for reviewing deliverable branches in the user's editor. Use when orca:feature's pre-flight fails a machine gate, when codex install/auth/timeout problems need walking through, or when the user wants to check or understand which reviewer runs will use. Not for repository layout — the bare-repo-with-worktrees conversion is orca:init's job — and does not start runs. Interactive and consent-per-step: diagnosis is free, every write is confirmed first.
args: <optional focus, e.g. "codex" or "timeout">
user-invocable: true
disable-model-invocation: true
---

# Orca: doctor

Make the *machine* ready for orca runs. Repository layout is orca:init's job and stays out of scope here; everything else the pre-flight checks — the Codex CLI, its auth, the MCP tool timeout, plus the run-environment extras (`bypassPermissions`) — is this skill's. The temperament is like init's: interactive, diagnosis free, consent before every mutating step. Doctor mostly *prescribes* — codex installs come from brew or release binaries by the user's hand, and auth is inherently the user's interactive action; the only things it writes are settings blocks, each confirmed.

## Step 1: Diagnose

**Inside a git repository**, run orca:feature's pre-flight from the project root — read-only, and its output is the work list:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh
```

Report every gate in plain language: `BARE_REPO` (`PASS | FAIL`), the `REVIEWER:` line (which reviewer, pinned by `.orca/config.json` or detected from the machine), and `CODEX` (`PASS | FAIL | SKIPPED` — skipped means the resolved reviewer is claude and the codex checks deliberately did not run). A `REVIEWER: FAIL` means the config key is invalid — point at orca:config; nothing here edits that file.

Whenever the resolved reviewer is codex, add the one probe the script cannot run — the **live MCP probe**, from this session: call ToolSearch with `select:mcp__plugin_orca_orca-codex__codex`. Missing while the codex gates pass means review agents cannot reach codex, and the cause is one of two. First check whether the project carries MCP config of its own — a `.mcp.json` at the repo root, or local-scope servers (`claude mcp list` shows both): a known harness bug (present as of Claude Code 2.1.202) loads none of a plugin's bundled MCP servers when any such config exists. A leftover `codex` registration is redundant — the plugin bundles the server — so prescribe removing it, never remove it yourself; if the project genuinely needs its own MCP servers, the workaround is pinning `reviewer=claude` via orca:config, trade-off stated. Otherwise the session predates the plugin's install or enablement. Both remedies end in a fresh session, so name that alongside the other restart caveats.

**Outside a git repository**, run in machine-only mode: say up front that the layout gate and reviewer pinning are per-repo and unchecked here. Probe codex directly with the same checks the pre-flight runs — binary on PATH, `codex --version` against the minimum version the preflight names (read `codex_min_version` from `${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh` rather than reciting a remembered one), `codex login status`, and `MCP_TOOL_TIMEOUT` in a settings env block. Treat the resolved reviewer as detected-only, offer the timeout write to `~/.claude/settings.json` only (there is no project settings file to offer), and skip the `bypassPermissions` offer (also per-repo).

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

## Step 4: Optional — offered, never defaulted

**`bypassPermissions` default mode.** For a repo where orca runs are always unattended, offer to write `"permissions": { "defaultMode": "bypassPermissions" }` into `<repo-root>/<branch>/.claude/settings.local.json`. State the tradeoff plainly: it disables the approval gate for every session opened in that worktree, not just orca runs. Declining is fine — the mode can be toggled per session with Shift+Tab instead. (Per-repo, so skipped entirely in machine-only mode.)

**The orca.nvim install check.** Per-machine (offered in machine-only mode too — the probe subcommand needs no git repository). The Neovim companion lives in its own repository, [`miguelbacalhau/orca.nvim`](https://github.com/miguelbacalhau/orca.nvim); its `:OrcaReview` opens a deliverable branch's merge-base diff in the user's own editor. This same probe gates **orca:review** — the skill that opens that review in a tmux window — so a failed prescription here is what turns orca:review into its print-only fallback (or a loud FAIL, when `editor=nvim` is pinned). Doctor prescribes; it never edits the user's nvim config. Probe with the exact check orca:review runs:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/review.sh probe nvim
```

- `PROBE_OK: nvim` → installed and reachable; nothing to do — report it.
- `PROBE_FAILED: nvim  nvim not on PATH` → no Neovim on this machine; skip silently.
- Any other `PROBE_FAILED` → prescribe installing `miguelbacalhau/orca.nvim` with the user's plugin manager — one lazy.nvim line as illustration (`{ "miguelbacalhau/orca.nvim" }`), no manager detection, and never write into their nvim config. For users who run no plugin manager, offer — consented like every write — a clone into Neovim's native packpath: `git clone https://github.com/miguelbacalhau/orca.nvim <stdpath('data')>/site/pack/orca/start/orca.nvim` (resolve the path by asking nvim itself: `nvim --headless "+lua io.write(vim.fn.stdpath('data'))" +q`), then `nvim --headless "+helptags <clone>/doc" +q` and re-probe. Caveat to state when the clone path is chosen: native packages require `packpath` intact — configs that reset it (plugin managers commonly do) ignore the clone silently, so if the re-probe still says `no`, the manager route is the fix.

Updates ride the manager's own update flow, or `git -C <clone> pull` for clone installs — doctor can run the pull on request. Uninstall is symmetric: remove via the manager, or `rm -rf` the clone.

Machine hygiene, pre-release only: the never-shipped symlink design left links on dev machines (`site/pack/orca/start/orca.nvim` → a checkout's `nvim/`). A *symlink* at the clone path is one of those — offer to replace it with a real install. No user-facing migration story is needed; v1 was never released.

Verification is in-editor: `:checkhealth orca`.

**The orca.vscode install check.** Per-machine (offered in machine-only mode too — the probe subcommand needs no git repository). The VS Code companion lives in its own repository, [`miguelbacalhau/orca.vscode`](https://github.com/miguelbacalhau/orca.vscode); its "Orca: Review" opens a deliverable branch's merge-base diff in the user's own VS Code. This same probe gates **orca:review**'s vscode tier — a failed prescription here is what turns orca:review into its print-only fallback (or a loud FAIL, when `editor=vscode` is pinned). Doctor prescribes; it never installs. Probe with the exact check orca:review runs:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/review.sh probe vscode
```

- `PROBE_OK: vscode` → installed; nothing to do — report it.
- `PROBE_FAILED: vscode  code CLI not on PATH` → skip silently (`code` not being on PATH on a machine with VS Code installed usually means the "Install 'code' command in PATH" palette action hasn't been run; mention that only if the user asks about VS Code).
- `PROBE_FAILED` naming the extension → prescribe the VSIX from the [latest GitHub release](https://github.com/miguelbacalhau/orca.vscode/releases):

  ```bash
  code --install-extension <path-to-downloaded>/orca-vscode-<version>.vsix
  ```

  Marketplace publish is deferred until the extension stabilizes, so the release VSIX is the install path. Updates are the same command with a newer VSIX; uninstall is `code --uninstall-extension miguelnjacinto.orca-vscode`. Forks that alias `code` (Cursor, VSCodium, code-insiders) are not probed for — one binary, one id, on purpose.

## Step 5: Verify

Re-run the pre-flight (inside a repository) or the direct codex probes (machine-only) and report gate by gate. Name what remains on the user rather than glossing it: a `codex login` not yet done, a session restart pending before the settings env loads. Close by pointing at the workflow the machine is now ready for: `/orca:feature` to capture a feature's intent and run it — or `/orca:init` first if the layout gate is the one still failing.

## Guidelines

- Diagnosis is free; every write is announced and confirmed first. Binaries and auth remain the user's actions — surface the command, never run installs or logins autonomously.
- Never touch repository layout, history, refs, or remotes — that is orca:init's territory.
- Never edit `.orca/config.json` — pinning or clearing the reviewer belongs to orca:config; recommend it by name instead.
- A codex gate failing while the reviewer is codex is a failure to fix, never a reason to suggest silently switching the reviewer — swapping the reviewer out from under a codex user is a decision, so it goes through orca:config with the trade-off stated.
