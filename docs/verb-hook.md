# The verb hook

The work loop runs a few dozen `orca.sh` verbs per run: the lease, worktree arrival, commit verification, merge preparation and finalization, salvage, archiving. The Workflow sandbox has no shell, so orca ships a function hook, `hooks/relay.ts`, that runs them without a model.

**In short: it runs orca's own verbs, requested by orca's own work loop, without a permission prompt — only in `bypassPermissions` sessions, and only from an allow-list.**

## How a call travels

1. The work loop makes an agent call whose model name carries the request: `orca:{"v":1,"verb":"spec","args":["mark","<run-dir>"]}`.
2. The hook sees it at `turn.step`, before anything reaches the API, and runs `bash <plugin-root>/scripts/orca.sh <verb> <args…>` as an argv (no shell; always through `orca.sh`, so the repository's git hooks still run).
3. It returns `b64:` + base64 of `{v, rc, stdout, stderr}`.

No model sees the request or the output, and no tokens are spent. A call takes about a tenth of a second.

## Guards

Each guard refuses with `{v, refused}`, which the work loop raises as an error:

- **Bypass mode only.** The hook tracks the session's permission mode from `UserPromptSubmit`, `PostToolUse`, `SubagentStop`, and `Stop` events and runs nothing unless it is `bypassPermissions`. An unknown mode counts as not bypass. Events from inside a subagent can close the gate but never open it.
- **Allow-list:** exactly the verbs the work loop calls — `triage claim|release`, `spec mark|changed`, `secrets place|remove`, `archive attempt`, `notes write`, `worktree-item`, `provision`, `commit-verify`, `merge-prepare`, `merge-finalize`, `commit-prepare`, `salvage`, `self-test`. A bats test keeps it in sync with the work loop.
- **Workflow agents only**, protocol version `1` only, arguments an array of strings.

An `orca:` request is always answered by the hook, refused or not; it is never passed on to the API.

## Failures

There is no fallback. The run's first verb is the lease claim (`run-lease`), so a session that can't run verbs stops there, before any agent runs:

- **No answer** (`run-lease: no answer from orca's verb hook …`) — the hooks module isn't loaded: function hooks off, `--bare`, `disableAllHooks`, or a module that failed to load. Fix the session and resume.
- **Refused** (`orca's verb hook refused …`) with the guard's reason — usually a session not in bypass mode.
- **Failed, timed out, or malformed** — the verb couldn't start, ran past ten minutes, or the answer is unreadable (a version mismatch between the loaded plugin and the run's workflow).

Hook answers, including refusals and errors, are journaled like any agent result, so a resume replays them. **After fixing a refusal at launch, launch the run fresh instead of resuming.** A hook failure after launch blocks the item that hit it, starts no further items (each blocked as `run stopped: orca's verb hook failed: …`), and skips integration verification; once fixed, `/orca:retry` relaunches the unfinished items.

## Limits

- **Ten minutes per verb** (`$.process.run`'s maximum). `.orca/setup` is capped at nine so its own timeout fires first and the item continues with a `TIMED OUT` provisioning note.
- **Version skew.** The hook runs the `orca.sh` of the plugin version loaded now, while the work loop is the version that launched the run. Finish a run on the version that started it.
- **Without the hook, the request leaves the machine.** The verb request — its verb and arguments (run-directory paths, the slug and branch) — is sent to the API as an unknown model name and rejected. At launch, only the first verb gets that far.

Tests: `tests/relay.test.ts` (`claude plugin test .`) for the hook, `tests/work-loop.bats` for the work loop's side.
