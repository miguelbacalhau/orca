# Orca: debug — the interview

This file is read by the orca:debug skill when its triage finds no open case to resume or re-run: the symptom at hand has no captured case yet, so capture it as a durable case directory. Every debug run starts from a case, discovered on disk and confirmed once. The interview is where the bug gets pinned down — unhurried, skeptical about certainty, and free to span as many rounds as the symptom needs. The product is a case file in exactly the shape the run's opening confirmation (Step 1 of `SKILL.md`) restates, so the run starts with a single yes.

The case is *what is broken and how we know* — observed behavior, not diagnosis. It is not *why it is broken*: hypotheses, verification, and root cause belong to the run, grounded in a deterministic reproduction and fresh-context exploration. A cause written here would be a guess — record the user's suspicions under Ruled out or as evidence notes, never as conclusions.

## Input

The user provides a symptom, usually as the `<symptom>` argument to `/orca:debug`. If none was provided, ask what is broken.

## Step 1: Discuss — and read the evidence

Interview the user, in as many rounds as it takes. The case is the run's entire intent — the run asks nothing beyond one confirmation — so cover:

- **The symptom, verbatim.** What actually happens, in the user's own words — keep their phrasing in the case; paraphrase drift loses detail the run may need.
- **Expected behavior.** What should happen instead, and how the user knows (spec, docs, it-used-to-work).
- **Reproduction, as known.** Exact steps if the user has them; "none known" is a legitimate answer — establishing the repro is the run's first job and its hard gate, so anything that raises the odds (timing, data, load, sequence) is worth a question.
- **Last known good.** A commit, version, or date when the behavior was correct — this single fact unlocks automated `git bisect` during verification; "unknown" is fine but worth one genuine attempt to pin down.
- **Environment.** OS, runtime versions, configuration, flags — whatever plausibly matters.
- **What is already ruled out.** Causes the user has eliminated and *how* — an eliminated cause with evidence saves the run a hypothesis; a hunch without evidence is recorded as a hunch.
- **The scope rule.** `diagnose-and-fix` (the default): the run continues past the diagnosis into a nested work loop and lands a fix with a regression test on `fix/<slug>`. `diagnose-only`: the run ends after the judge with a root-cause report — right when the fix is someone else's call, touches code the user wants to change by hand, or needs a decision the diagnosis should inform first.

**One deliberate divergence from the feature interview: read the evidence the user points at.** A stack trace, a failing CI log, a screenshot of wrong output, an error message — the symptom *lives* in artifacts, not in intent, and reading them here sharpens every question above. Copy what you read (or an excerpt that preserves the load-bearing detail) into the case's `evidence/` directory so the run's agents see the same artifacts without asking. What stays out of bounds is deep *codebase* exploration — chasing the cause through source is the run's job, with fresh context and a real repro; if the discussion drifts from *what is broken* into *why*, steer it back.

Push back. Symptoms arrive pre-diagnosed ("the cache is corrupting X") — separate the observation from the theory, record the observation as the symptom and the theory as a note. Vague symptoms ("it's flaky") get concretized: how often, observed where, since when.

If the machine-local project context exists — `<repo-root>/.orca/decisions.md` and `.orca/map.md` — read it before the later rounds and interview decision-aware: a recorded decision near the symptom may mean the behavior is chosen, not broken ("the decision log says errors on that endpoint are deliberately swallowed — is this that, or something new?"). The files are hints from a snapshot, not ground truth; what they surface becomes questions and case notes, never conclusions.

## Step 2: Early pre-flight (optional, never blocking)

Run the run's environment pre-flight now, from the project root:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orca.sh preflight
```

An early warning, not a gate: a `FAIL` is something to fix before the *run*, at leisure — it never blocks writing the case. If the case runs now, the run's own pre-flight reuses this output. Report failing gates and point at the right fixer — orca:init for `BARE_REPO`, orca:doctor for the codex machine gates (which matter to the fix tail; under a diagnose-only scope they are only a warning), orca:config for an invalid `REVIEWER` — then continue.

## Step 3: Write the case

Resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir`, and create the case directory:

```text
<repo-root>/.orca/bug-cases/<slug>/
├── case.md        # the case file below
├── ledger.md      # append-only cross-run memory, created now with just its header
└── evidence/      # the artifacts read during the interview, copied in
```

Make `<slug>` a short kebab-case description of the bug, 3-5 words max — it names the case in triage listings, the run directories, and the `bug/<slug>` / `fix/<slug>` branches, so the name alone must identify the bug. Location is status: a directory under `bug-cases/` **is** an open case, and the run that closes it moves the whole directory into its run dir.

```markdown
# Case: <title>

**Created:** <YYYY-MM-DD HH:MM>
**Scope:** diagnose-and-fix | diagnose-only

## Symptom

<What happens, verbatim from the user.>

## Expected behavior

<What should happen instead, and how we know.>

## Reproduction steps

<Numbered steps, or "none known" plus anything that raises the odds.>

## Last known good

<Commit, version, or date — or "unknown".>

## Environment

- <OS / runtime / config that plausibly matters>

## Evidence

- `evidence/<file>` — <what it shows>

## Ruled out

- <Eliminated cause — and the evidence that eliminated it. "Nothing yet" is fine.>
```

Use `date +"%Y-%m-%d %H:%M"` for the `Created` line. Seed `ledger.md` with only a header:

```markdown
# Ledger: <title>

Append-only. Every hypothesis ever tested against this case (verdict and
evidence pointer, per run) and every fix attempt (diff ref, repro outcome).
Runs append; nothing here is ever rewritten.
```

Read the written case back to the user in summary and incorporate corrections until they approve it. Their approval is what makes the file authoritative — the run treats it as the whole account of the bug.

## Step 4: Hand back

The case is written and approved. Return to `SKILL.md`'s run-now-or-leave-open question (the end of Step 0). The run's own pre-flight and confirmation gates live in the same skill, so there is nothing to hand off.

## Guidelines

- One case is one bug. Two symptoms with no demonstrated common cause get two cases — if the run proves them linked, one case closes citing the other.
- Never write hypotheses, a suspected root cause, or fix ideas into the case as fact. The Ruled out section holds eliminated causes with their evidence; everything else the user suspects is a note, clearly marked as theirs.
- Cases may pile up; that is fine. Each is closed by the run that resolves it and archived in that run's directory, ledger and all.
