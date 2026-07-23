---
description: View and set per-repository overrides for orca runs — which Claude model and reasoning effort each stage agent (spec, plan, implement, review, fix, commit, merge, integrate for feature runs; reproduce, hypothesize, verify, diagnose for debug runs) runs with, which independent reviewer (codex or claude) the work loop uses, and how orca:review hands deliverables to the human (`editor`, `terminal`). Writes `.orca/config` at the repo root; orca:feature and orca:debug read it at launch and thread the overrides into every stage agent they spawn, orca:review reads it per invocation. Use when the user wants runs cheaper (smaller models, lower effort), stronger (bigger models, higher effort), wants to pin or switch the reviewer, wants to pin or opt out of the editor hand-off, or wants to see the current configuration. Does not start a run and never edits the plugin's own agent definitions.
args: <assignments like plan.model=sonnet review.effort=high reviewer=claude editor=vscode, or "reset"; optional>
user-invocable: true
disable-model-invocation: true
---

# Orca: config

Tune orca runs per repository: which model and reasoning effort each stage agent runs with, and which independent reviewer the work loop uses. Every stage agent ships a default in its own definition — the frontmatter of `agents/<stage>.md` inside the plugin — and this skill never touches those files: it writes overrides to `<repo-root>/.orca/config`, which orca:feature and orca:debug read at launch and apply on top of the defaults. An override file survives plugin updates; deleting an override returns that stage to whatever the plugin's current default is.

The config has three surfaces:

- **`reviewer`** — a top-level key, `"codex"` or `"claude"`, selecting the work loop's independent reviewer — for feature runs and for the fix tail of diagnose-and-fix debug runs alike. When the key is **absent**, the run detects at launch: codex binary on PATH at the minimum version → codex, else claude. A written key **pins** the choice against detection.
- **`editor`** and **`terminal`** — flat top-level keys beside `reviewer`, read by **orca:review** (the human walk-through of a deliverable branch, not the runs' adversarial review stage). Same three-state contract as `reviewer`: **absent → detect** (`editor`: nvim on PATH with orca.nvim installed, else `code` with the orca.vscode extension listed — nvim wins when both probe clean, so a both-installed user pins `editor=vscode` to switch; `terminal`: `$TMUX` set), **pinned → loud fail** when the pinned thing is missing (never a silent fallback), **`none` → opt out** (orca:review prints the command instead of opening anything). Valid values today: `editor: nvim|vscode|none`, `terminal: tmux|none` — the enum grows when real support does. `terminal` only applies to the nvim path; the vscode launch is a detached GUI open that never consults it. These are machine preferences living in a repo file — accepted trade-off: `.orca/` sits outside the worktrees (effectively personal), and detection means most users never set them.
- **`agents`** — per-stage `{model, effort}` overrides. One block serves both verbs: the feature stages (`spec` through `integrate`) and the debug stages (`reproduce`, `hypothesize`, `verify`, `diagnose`) live side by side, and each run applies its own verb's keys — plus, for a debug run's nested fix tail, the feature stages except `spec` (the fix contract is written by the diagnose agent, so a `spec` override never applies to debug runs) — ignoring the rest.

One stage comes with a caveat worth stating whenever it is configured:

- **review** tunes whichever reviewer agent is active, and what that means depends on the reviewer. With reviewer **codex**, the review stage is a courier that drives Codex: configuring it changes the courier's cost and care, never the quality of Codex's review. With reviewer **claude**, the review stage IS the reviewer (`orca:review-claude`, default opus/high): configuring it changes actual review quality.

The workflow's internal helper agents — the shell relay, reconciliation, escalation — are not configurable: their cost/judgment profile is part of the loop's design, not a per-repo preference.

## Step 1: Read the current state

The bundled script is the sole reader and writer of `<repo-root>/.orca/config` — never read, author, or repair the file directly:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config show
```

One typed TAB-separated line per fact: `REVIEWER:` (the pinned value, or `absent`), `EDITOR:` and `TERMINAL:` (value or `absent`), one `OVERRIDE:` line per set stage field, and one `DEFAULT: <stage> <model> <effort>` line per stage — read fresh from the plugin's own agent definitions, so they track the installed plugin version. The review stage appears twice, as `review-codex` and `review-claude`; render the row for the effective reviewer. A `FAIL:` line names what is wrong — translate it: `NOT_GIT` means the config is per-repository, so explain that and stop; a mangled file (`PARSE_ERROR`, `DUPLICATE_KEY`, an unknown key or value) is fixed by a targeted `set`/`clear`, or by `orca.sh config reset` — the full reset is the recovery path and works even when the file cannot be parsed.

If a legacy `<repo-root>/.orca/config.json` exists, mention that it is obsolete — nothing has read it since the flat-file migration (the preflight emits a `CONFIG: OBSOLETE:` signpost while it lingers) — and offer to delete it. Never parse or migrate it: the values are retyped in seconds with `set`.

To resolve the **effective** reviewer when the key is absent, run the bundled preflight (`bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh preflight`) and read its `REVIEWER:` line — the config script never detects; compose the two outputs.

## Step 2: Show the state

Always show the effective configuration before changing anything — with no arguments, showing it may be the whole job.

First the reviewer, with provenance — e.g. `Reviewer: codex (pinned)` or `Reviewer: claude (detected — codex not on PATH)` — then `editor` and `terminal` in the same shape when set (e.g. `Editor: none (pinned — orca:review prints instead of opening)`); when absent, one line noting both detect at orca:review time, without probing here. Then the stage table:

| Stage | Role | Model | Effort |
|-------|------|-------|--------|
| spec | explores the codebase, writes the spec and work breakdown | fable | high |
| plan | … | … | … |

One line per stage, role in a few words (spec: writes the spec and breakdown; plan: plans one item; implement: builds one item; review: drives the Codex review *or* performs the Claude review, per the effective reviewer — say which; fix: applies review findings; commit: commits one item; merge: merges into the integration branch; integrate: verifies the assembled feature; reproduce: turns a bug case into a deterministic repro script; hypothesize: writes ranked root-cause candidates; verify: adversarially tests one hypothesis; diagnose: judges the verdicts into a diagnosis and fix contract). Group the table by verb — the first eight stages run in feature runs (and, `spec` excepted, in a debug run's fix tail — debug runs never spawn a spec agent), the last four in debug runs. Show the effective value, marking overrides — e.g. `sonnet (override; default opus)` — so defaults and overrides are distinguishable at a glance. The review row's defaults come from the `DEFAULT:` line matching the effective reviewer — `review-claude` with reviewer claude, `review-codex` (the courier) with codex.

## Step 3: Apply changes

Arguments like `plan.model=sonnet review.effort=high reviewer=claude editor=none` apply directly. `reset` clears every override — the reviewer, editor, and terminal keys included; `reset <stage>` clears one stage; the value `default` clears a single field (`plan.model=default`, `reviewer=default`, `editor=default`, `terminal=default` — for the top-level keys, back to detection). With no arguments, show the state and ask what to change in plain conversation — do not march through all twelve stages unless asked.

Validation is the script's, not yours: it checks every assignment against the same stage/model/effort/reviewer/editor/terminal vocabulary the workflow scripts enforce at launch (the literal lists live in the config verb beside the workflow scripts' copies, under one lockstep comment), rejects a bad batch whole — one typed `FAIL:` line per bad assignment, nothing written. Your job is translation and advice, not re-checking: relay what each `FAIL:` line names, and add the one warning the script cannot know — `fable` is accepted but only works on plans whose harness offers it, and it is the *default* for `spec` and `plan`: a harness whose plan does not offer fable must pin them back with `spec.model=opus plan.model=opus`. Volunteer that remedy whenever you are relaying a fable-related spawn failure — a default failing looks like a bug to the user, not a configuration choice.

On `reviewer=claude`, state the trade-off in one sentence: the Claude reviewer keeps fresh-context independence (a separate agent, only the artifacts and the diff, an adversarial contract) but is same-model — cross-model codex review does not share the implementer's blind spots. On `reviewer=codex`, note that the codex machine gates (binary, auth, `MCP_TOOL_TIMEOUT`) must pass at run time — run the preflight to check, and point at orca:doctor if they currently fail.

An override equal to today's default is still meaningful — it pins the stage against future plugin-default changes — so keep it if the user asked for it explicitly, and say that is what it does. The same holds for pinning `reviewer=codex` on a machine where codex would be detected anyway: the pin protects the choice from a future broken PATH turning into a silent claude run (it turns into a loud preflight FAIL instead). Likewise `editor=nvim`: a later broken orca.nvim install becomes a loud orca:review FAIL instead of a silent fall-through. And `editor=vscode` is how a user with both editors installed switches — detection tries nvim first, so the pin is the designed mechanism, not a workaround.

## Step 4: Write and confirm

Apply the changes with one script call — a batch is all-or-nothing, so a partial write can never happen:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config set plan.model=sonnet reviewer=claude editor=default
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config clear review.effort     # same as review.effort=default
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh config reset [stage]
```

The mechanics are the script's: merge into the existing file rather than overwriting unrelated keys, store only overridden fields in a canonical compact shape, remove cleared fields, empty stage objects, and an empty `agents` block (never writing `null` or `"default"`), delete a file left empty, and — in a conventional checkout, where `<repo-root>` **is** the working tree — keep `.orca/` listed in `<git-common-dir>/info/exclude` (the per-clone ignore file) so a stray `git add -A` never commits per-machine model preferences; the repo's tracked `.gitignore` stays untouched. On success it emits the resulting state (the same typed lines as `show`) plus a `WROTE:` or `DELETED:` line.

Render that resulting state back to the user as Step 2 does, and state when it takes effect: the **next orca run launch** (feature or debug) — except `editor`/`terminal`, which orca:review reads fresh on every invocation. A run already in flight keeps the configuration it launched with, and a resume (`resumeFromRunId`) does too — orca:feature records the launch-time Workflow args in the run's `spec.md`, orca:debug in the case's `case.md`, and resumes replay that record verbatim, never this file — so editing overrides here affects only future launches.

## Guidelines

- Never edit `${CLAUDE_PLUGIN_ROOT}/agents/*.md` — plugin files are replaced on update, and the defaults are the plugin's to set. Overrides live only in the repo's `.orca/config`, and every read and write of that file goes through `orca.sh config` — the canonical shape it guarantees is what lets the preflight and orca:review scripts read the file with grep.
- This skill configures the reviewer choice, the orca:review `editor`/`terminal` keys, and models/effort only. The codex machine setup (binary, auth, MCP timeout) and the orca.nvim / orca.vscode installs belong to orca:doctor; repository layout belongs to orca:init; run behavior belongs to orca:feature and orca:debug; opening the review itself belongs to orca:review.
- Advise, don't moralize: if an override looks self-defeating (haiku for plan or merge, where judgment failures cost whole items; max effort on commit, which formats a message), say so in one sentence and write what the user chose.
