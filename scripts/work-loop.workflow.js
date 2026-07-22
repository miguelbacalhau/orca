// orca work loop — Step 4 of the skill (work loop + integration
// verification) as a deterministic workflow.
//
// The main conversation runs Steps 1-3 (brief confirmation, pre-flights, spec,
// checkpoint, integration worktree) and Step 5 (report), then invokes this
// script via the Workflow tool with `scriptPath` and the args below. Everything
// the conversational loop enforced with prose is code here: a completion-driven
// scheduler (an item launches the moment its own dependencies merge — it never
// waits for an unrelated sibling), the 2-round fix cap, the commit-attribution
// check verified against `git log` itself, the 2-slot review throttle (codex
// reviews only — they contend for one codex auth; claude reviews ride the
// normal concurrency cap), and the serialized merge queue with a merge-abort
// safety net. Resume comes from the workflow journal (`resumeFromRunId`); the
// token ceiling comes from `budget`.
//
// args: {
//   runDir            .orca/<timestamp>-feat-<slug> — spec.md, plans/, reviews/ (absolute)
//   repoRoot          parent of the bare repo; all worktrees live here (absolute)
//   slug              run slug; integration worktree is <repoRoot>/orca-<slug>
//   integrationBranch feature/<slug> — item branches derive from it (${integrationBranch}-${id})
//   items             [{ id, title, deps: [ids], files: [paths], taskId?, retryNote? }]
//                     from the Work Breakdown; taskId is the id of the item's
//                     session task (created by the main conversation before
//                     launch), updated by the stage agents for live display —
//                     absent, the item simply gets no status lines. retryNote
//                     is set only by orca:retry's relaunch over a finished
//                     run's unmet items: a per-item note the planner receives
//                     naming the prior round's blocked reason and archived
//                     evidence — absent, prompts stay byte-identical to
//                     pre-retry journals
//   agents            optional { <stage>: { model?, effort? } } — per-stage
//                     overrides from <repo-root>/.orca/config.json (written by
//                     the orca:config skill, read by the run skill at launch),
//                     applied on top of each stage agent's own frontmatter
//                     defaults; an absent stage or field keeps the default
//   reviewer          'codex' | 'claude' — which independent reviewer this run
//                     uses. REQUIRED: the run skill resolves it before launch
//                     (pinned in .orca/config.json, else detected from the
//                     preflight); this script never detects — it has no shell
//                     and must stay deterministic for resume
//   updateContext     optional boolean, default true — run the orca:context
//                     agent over <repoRoot>/.orca/{map.md,decisions.md} after
//                     the Integrate phase. The debug loop passes false into
//                     its nested fix call: the debug run maintains the
//                     context itself, with the diagnosis in hand
//   pluginRoot        optional absolute path of the installed plugin root
//                     (the launching skill substitutes ${CLAUDE_PLUGIN_ROOT}
//                     — this script has no environment to resolve it from);
//                     when present, secrets.sh place runs after every
//                     worktree add, linking <repoRoot>/.orca/secrets/ into
//                     the fresh worktree. Absent (a resume of a pre-secrets
//                     launch) skips placement and keeps the worktree
//                     commands byte-identical to the old journal
// }
//
// Review prompts are not inputs: the reviewer agent (orca:review-codex driving
// Codex through the plugin-bundled orca-codex MCP server, or orca:review-claude
// reviewing itself) carries the adversarial review contract in its own
// definition, receiving only the run directory, artifact paths, and owned
// files — nothing has to be written into <runDir>/reviews/ before this
// workflow starts, and there is no review script or shell relay anywhere in
// the review path.

export const meta = {
  name: 'orca-work-loop',
  description: 'Plan, implement, review, commit, and merge every work item, then verify integration',
  phases: [
    { title: 'Plan', detail: 'planners per readiness wave, then cross-plan reconciliation' },
    { title: 'Build', detail: 'worktree setup and implementation, pipelined per item' },
    { title: 'Review', detail: 'independent review (codex or claude per config) and fix rounds (max 2)' },
    { title: 'Merge', detail: 'commit, then serialized merges into the integration branch' },
    { title: 'Integrate', detail: 'full-feature verification in the integration worktree' },
    { title: 'Context', detail: 'fold the run into the machine-local project context' },
  ],
}

// A launcher that JSON-encodes args delivers one big string here, every
// destructured field reads undefined, and the crash surfaces deep in the
// scheduler ("undefined is not an object (evaluating 'items.map')"). Recover
// the stringified case, then fail fast — at launch, not mid-run — on anything
// still missing or mis-shaped.
let parsedArgs = args
if (typeof parsedArgs === 'string') {
  try { parsedArgs = JSON.parse(parsedArgs) }
  catch { throw new Error('args arrived as a string that is not valid JSON — pass args as a real JSON object') }
}
if (typeof parsedArgs !== 'object' || parsedArgs === null)
  throw new Error(`args must be a JSON object (got ${JSON.stringify(args)}) — pass it as a real object, not a JSON-encoded string`)
const { runDir, repoRoot, slug, integrationBranch } = parsedArgs
let items = parsedArgs.items
if (typeof items === 'string') {
  try { items = JSON.parse(items) } catch { /* fall through to the array check */ }
}
for (const [k, v] of Object.entries({ runDir, repoRoot, slug, integrationBranch }))
  if (typeof v !== 'string' || !v)
    throw new Error(`args.${k} must be a non-empty string (got ${JSON.stringify(v)})`)
// Absolute paths only: every stage agent and the review artifacts resolve
// these from their own working directories, so a relative path silently
// points each consumer somewhere different.
for (const [k, v] of Object.entries({ runDir, repoRoot }))
  if (!v.startsWith('/'))
    throw new Error(`args.${k} must be an absolute path (got ${JSON.stringify(v)})`)
if (!Array.isArray(items) || items.length === 0)
  throw new Error(`args.items must be a non-empty array of work items (got ${JSON.stringify(items)})`)
const badItems = items.filter(i => !i || typeof i.id !== 'string' || typeof i.title !== 'string' ||
  !Array.isArray(i.deps) || !Array.isArray(i.files))
if (badItems.length)
  throw new Error(`malformed work items (need string id, string title, array deps, array files): ${JSON.stringify(badItems)}`)
const badTaskIds = items.filter(i => i.taskId !== undefined && (typeof i.taskId !== 'string' || !i.taskId))
if (badTaskIds.length)
  throw new Error(`malformed work items: taskId, when present, must be a non-empty string: ${JSON.stringify(badTaskIds)}`)
// retryNote: composed by the retry skill per unmet item on a retry launch —
// a fresh run over the old run directory. Absent, prompts stay byte-identical
// to current journals, so existing resumes still replay.
const badRetryNotes = items.filter(i => i.retryNote !== undefined && (typeof i.retryNote !== 'string' || !i.retryNote))
if (badRetryNotes.length)
  throw new Error(`malformed work items: retryNote, when present, must be a non-empty string: ${JSON.stringify(badRetryNotes)}`)
// "integration" is the reserved id of the integration-fixes review pass — a
// work item with that id would collide with its artifact paths even though
// the review mode is now passed explicitly.
if (items.some(i => i.id === 'integration'))
  throw new Error('invalid work breakdown: "integration" is a reserved item id')

// Grammar validation at the deterministic boundary: slug, item ids, the
// integration branch, and file entries are interpolated into shell
// commands, git refs, worktree paths, and prompts by every stage — a
// malformed value must fail here with a typed error, not deep in the run.
//
// slug — worktree/branch path segment.
//   valid:   "auth", "retry-2", "a1-b2-c3"
//   invalid: "Auth", "a_b", "-x", "x-", "a--b" is valid, "a/b", "", "a."
const SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
if (!SLUG_RE.test(slug))
  throw new Error(`args.slug must match ${SLUG_RE} (got ${JSON.stringify(slug)})`)
// item ids — W-numbered from the Work Breakdown, or F-numbered for the
// debug loop's synthesized fix item (its nested call lands here).
//   valid:   "W1", "W12", "F2"
//   invalid: "W0", "W01", "w1", "H1", "W1a", "integration"
const ITEM_ID_RE = /^[WF][1-9][0-9]*$/
const badIds = items.filter(i => !ITEM_ID_RE.test(i.id))
if (badIds.length)
  throw new Error(`invalid work breakdown: item ids must match ${ITEM_ID_RE}: ${badIds.map(i => JSON.stringify(i.id)).join(', ')}`)
const badDepIds = items.flatMap(i => i.deps.filter(d => typeof d !== 'string' || !ITEM_ID_RE.test(d))
  .map(d => `${i.id} depends on ${JSON.stringify(d)}`))
if (badDepIds.length)
  throw new Error(`invalid work breakdown: dependency ids must match ${ITEM_ID_RE}: ${badDepIds.join('; ')}`)
// integrationBranch — conservative git ref class (mirrors review.sh's
// notes-key character class plus '/'), rejecting the ref-syntax traps.
//   valid:   "feature/auth", "fix/login-crash", "feature/v1.2"
//   invalid: "-x", "a..b", "a//b", "/a", "a/", "a.lock", "a b", "a~1"
const REF_RE = /^[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*$/
if (!REF_RE.test(integrationBranch) || integrationBranch.includes('..') ||
    integrationBranch.split('/').some(seg => seg.startsWith('-') || seg.startsWith('.') || seg.endsWith('.lock')))
  throw new Error(`args.integrationBranch is not a safe branch name (got ${JSON.stringify(integrationBranch)})`)
// files — must be strings: an object here renders "[object Object]" into
// every stage prompt and the owned-files contract silently dissolves.
const badFiles = items.filter(i => i.files.some(f => typeof f !== 'string' || !f))
if (badFiles.length)
  throw new Error(`invalid work breakdown: items[].files entries must be non-empty strings: ${badFiles.map(i => `${i.id}: ${JSON.stringify(i.files)}`).join('; ')}`)
const integrationWt = `${repoRoot}/orca-${slug}`

// Which independent reviewer this run uses. Required and pre-resolved: the run
// skill defaults an absent config key via the preflight's detection before
// launch, so the value here is always explicit — a resume must replay the
// launch-time reviewer, never re-detect.
const reviewer = parsedArgs.reviewer
if (reviewer !== 'codex' && reviewer !== 'claude')
  throw new Error(`args.reviewer must be "codex" or "claude" (got ${JSON.stringify(reviewer)}) — the run skill resolves it before launch`)

// Secrets placement needs the plugin root to find secrets.sh; optional so a
// resume of a launch that predates the arg still replays instead of failing.
const pluginRoot = parsedArgs.pluginRoot
if (pluginRoot !== undefined && (typeof pluginRoot !== 'string' || !pluginRoot.startsWith('/')))
  throw new Error(`args.pluginRoot, when present, must be an absolute path (got ${JSON.stringify(pluginRoot)}) — the launching skill substitutes \${CLAUDE_PLUGIN_ROOT}`)

// Post-run context maintenance is on unless the caller opts out (the debug
// loop's nested fix call does — the debug run maintains the context itself).
if (parsedArgs.updateContext !== undefined && typeof parsedArgs.updateContext !== 'boolean')
  throw new Error(`args.updateContext, when present, must be a boolean (got ${JSON.stringify(parsedArgs.updateContext)})`)
const updateContext = parsedArgs.updateContext !== false
// Machine-local project context: hints injected into judgment-stage prompts.
// The files live in .orca/ outside every worktree; the run skill's refresh
// step made them current (or seeded them) before launch, and stage agents
// treat a missing file as skippable, so this line is safe unconditionally.
const contextLine = `Project context: ${repoRoot}/.orca/map.md (codebase map) and ${repoRoot}/.orca/decisions.md (decision log) — hints from a snapshot at the commit stamped in each header, not ground truth: read them first for where to look, verify anything you rely on; file paths rot slower than implementation details. A missing file is skipped, not an error.`

// Per-stage model/effort overrides (args.agents). Only the seven
// workflow-spawned stages are tunable — spec is spawned conversationally
// before launch — and the internal helpers (the sh relay, reconcile,
// escalate) keep their fixed models: their cost/judgment profile is part of
// the loop's design, not a per-repo preference. Validated at launch like the
// rest of args: a typo'd stage or model must fail here, not surface mid-run
// as a dead agent call.
const TUNABLE = ['plan', 'implement', 'review', 'fix', 'commit', 'merge', 'integrate']
// 'spec' is a valid config key — the run skill passes the config block
// verbatim — but it is applied conversationally at spec-spawn time, before
// this workflow exists; here it is validated and otherwise ignored. The debug
// verb's stages get the same treatment: the config file has ONE agents block
// shared by both verbs (orca:debug passes it verbatim into its nested call to
// this script), so a debug override must be valid-and-ignored here, never a
// launch failure.
const STAGES = ['spec', ...TUNABLE, 'reproduce', 'hypothesize', 'verify', 'diagnose']
// The stage vocabulary is one shared 12-key list kept in lockstep across
// three code validators — scripts/config.sh (write time, and the run skills'
// launch validation via its validate subcommand), this script, and
// debug-loop.workflow.js — a value accepted anywhere but rejected here bricks
// every launch until the config file is hand-edited. MODELS/EFFORTS are part
// of the same lockstep. Workflow scripts run sandboxed with no filesystem
// access, so they cannot read a shared vocab file — the literal copies are
// the design.
const MODELS = ['haiku', 'sonnet', 'opus', 'fable']
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max']
let agentCfg = parsedArgs.agents ?? {}
if (typeof agentCfg === 'string') {
  try { agentCfg = JSON.parse(agentCfg) } catch { /* fall through to the object check */ }
}
if (typeof agentCfg !== 'object' || agentCfg === null || Array.isArray(agentCfg))
  throw new Error(`args.agents, when present, must be an object keyed by stage (got ${JSON.stringify(agentCfg)})`)
for (const [stage, cfg] of Object.entries(agentCfg)) {
  if (!STAGES.includes(stage))
    throw new Error(`args.agents.${stage}: unknown stage — configurable stages are ${STAGES.join(', ')}`)
  if (typeof cfg !== 'object' || cfg === null || Array.isArray(cfg))
    throw new Error(`args.agents.${stage} must be an object with optional model/effort (got ${JSON.stringify(cfg)})`)
  const badKeys = Object.keys(cfg).filter(k => k !== 'model' && k !== 'effort')
  if (badKeys.length)
    throw new Error(`args.agents.${stage}: unknown key(s) ${badKeys.join(', ')} — only model and effort`)
  if (cfg.model !== undefined && !MODELS.includes(cfg.model))
    throw new Error(`args.agents.${stage}.model must be one of ${MODELS.join(', ')} (got ${JSON.stringify(cfg.model)})`)
  if (cfg.effort !== undefined && !EFFORTS.includes(cfg.effort))
    throw new Error(`args.agents.${stage}.effort must be one of ${EFFORTS.join(', ')} (got ${JSON.stringify(cfg.effort)})`)
  if (stage === 'spec' && cfg.effort !== undefined)
    throw new Error('args.agents.spec.effort is not supported — the spec agent is spawned conversationally, where only model can be overridden')
}
// Merge overrides into agent() opts only when set: a run with no config keeps
// its opts byte-identical to pre-config journals, so resumes still replay.
const tuned = (stage, opts) => {
  const cfg = agentCfg[stage]
  if (!cfg) return opts
  const out = { ...opts }
  if (cfg.model) out.model = cfg.model
  if (cfg.effort) out.effort = cfg.effort
  return out
}

// ---------- structured-output schemas ----------
const MERGE ={ type: 'object', additionalProperties: false, required: ['merged', 'detail'],
  properties: { merged: { type: 'boolean' }, detail: { type: 'string' } } }
const RECONCILE = { type: 'object', additionalProperties: false, required: ['clean', 'issues'],
  properties: { clean: { type: 'boolean' }, issues: { type: 'array', items: { type: 'string' } } } }
const ITEM_REASON = { type: 'object', additionalProperties: false, required: ['id', 'reason'],
  properties: { id: { type: 'string' }, reason: { type: 'string' } } }
const DEP_AMEND = { type: 'object', additionalProperties: false, required: ['id', 'dependsOn'],
  properties: { id: { type: 'string' }, dependsOn: { type: 'array', items: { type: 'string' } } } }
const ESCALATE = { type: 'object', additionalProperties: false, required: ['replan', 'cut', 'blocked', 'addDeps'],
  properties: {
    replan: { type: 'array', items: { type: 'string' } },
    cut: { type: 'array', items: ITEM_REASON },
    blocked: { type: 'array', items: ITEM_REASON },
    addDeps: { type: 'array', items: DEP_AMEND } } }
const BUILD_ESCALATE = { type: 'object', additionalProperties: false, required: ['action', 'reason'],
  properties: {
    action: { type: 'string', enum: ['rebuild', 'cut', 'block'] },
    reason: { type: 'string' } } }
const IMPLEMENT = { type: 'object', additionalProperties: false, required: ['completed', 'summary'],
  properties: { completed: { type: 'boolean' }, summary: { type: 'string' } } }
// The review agent's whole report: written=false is a retryable failure (the
// gate never sees it); the counts are the merge gate. They are the agent's
// count of the findings it wrote — model-reported, a decided trade recorded
// in the skill; reason is "" when written is true.
const REVIEW = { type: 'object', additionalProperties: false, required: ['written', 'total', 'criticalHigh', 'reason'],
  properties: {
    written: { type: 'boolean' },
    total: { type: 'integer', minimum: 0 },
    criticalHigh: { type: 'integer', minimum: 0 },
    reason: { type: 'string' } } }
// The integration-fixes pass has no plan file to carry Deviations, so the
// fixer's declines and escalations come back structured and are persisted —
// the item pass keeps its free-text return (the plan file is the record).
const INTEGRATION_FIX = { type: 'object', additionalProperties: false,
  required: ['declines', 'escalations', 'summary'],
  properties: {
    declines: { type: 'array', items: { type: 'string' } },
    escalations: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' } } }
const CONTEXT = { type: 'object', additionalProperties: false,
  required: ['updated', 'promotions', 'summary'],
  properties: { updated: { type: 'boolean' },
    promotions: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' } } }
const INTEGRATION = { type: 'object', additionalProperties: false,
  required: ['features', 'fixesApplied', 'gaps'],
  properties: {
    features: { type: 'array', items: { type: 'object', additionalProperties: false,
      required: ['name', 'pass', 'detail'],
      properties: { name: { type: 'string' }, pass: { type: 'boolean' }, detail: { type: 'string' } } } },
    fixesApplied: { type: 'boolean' },
    gaps: { type: 'array', items: { type: 'string' } } } }

// ---------- helpers ----------
// agent() returns null when skipped or dead after retries; never dereference one.
const must = (result, what) => {
  if (result === null || result === undefined)
    throw new Error(`${what}: agent was skipped or returned no result`)
  return result
}

// The script has no shell access; deterministic commands run through a haiku
// agent. The command is wrapped so its exit status comes back as a short
// SH_RC marker the model cannot plausibly mangle — a failed command throws
// here instead of silently reading as success.
const sh = async (cmd, label, ph) => {
  const prompt = `Run exactly this command and return its complete output verbatim — plain text, no code fences, no commentary:\n{ ${cmd} ; } ; echo "SH_RC=$?"`
  const raw = await agent(prompt, { model: 'haiku', effort: 'low', label, phase: ph })
  if (raw === null || raw === undefined) throw new Error(`${label}: command agent was skipped or died`)
  const out = raw.split('\n').filter(l => !/^\s*`{3,}/.test(l)).join('\n')
  const marks = [...out.matchAll(/SH_RC=(\d+)/g)]
  if (!marks.length) throw new Error(`${label}: no exit-status marker in command output: ${out.trim().slice(-300)}`)
  const m = marks[marks.length - 1]
  // A nonzero exit is the command's own verdict, not relay flakiness — never retried.
  if (m[1] !== '0') throw new Error(`${label}: command exited ${m[1]}: ${out.slice(0, m.index).trim().slice(-300)}`)
  return out.slice(0, m.index).trim()
}

// sh() trims trailing text after the exit marker but keeps leading relay
// commentary. Any output that gets parsed (hashes) or attribution-checked
// (commit messages) must come from between explicit markers, never the raw
// transcript — a stray "Claude" in relay preamble would trip the banned regex
// against a clean commit. Marker lines are matched whole, so the echoed
// command text (where the markers appear quoted) can never match.
const shMarked = async (cmd, label, ph) => {
  const out = await sh(`echo "@@OUT@@" ; { ${cmd} ; } ; echo "@@OUT_END@@"`, label, ph)
  const lines = out.split('\n')
  const a = lines.findIndex(l => l.trim() === '@@OUT@@')
  const b = lines.map(l => l.trim()).lastIndexOf('@@OUT_END@@')
  if (a === -1 || b <= a)
    throw new Error(`${label}: output markers did not survive the relay: ${out.trim().slice(-300)}`)
  return lines.slice(a + 1, b).join('\n')
}

// Single-quote a value into a relayed shell command.
const sq = s => s.replace(/'/g, `'\\''`)

// Relay-read SHAs are interpolated into git reset/log commands — validate
// them like debug-loop's fix-base guard: full 40-hex or the command never
// runs. A garbled relay read must fail the item, never flow into
// `git reset --soft <garbage>`.
const SHA_RE = /^[0-9a-f]{40}$/
const mustSha = (sha, label) => {
  if (!SHA_RE.test(sha))
    throw new Error(`${label}: relay returned something that is not a commit sha (${String(sha).slice(0, 80)})`)
  return sha
}

// Codex reviews contend for one Codex auth — cap concurrency at 2 (SKILL:
// review throttling). Codex-only: claude reviews have no shared auth to
// contend for and ride the workflow's normal concurrency cap.
const reviewSlots = { free: 2, queue: [] }
const withReviewSlot = async fn => {
  if (reviewSlots.free > 0) reviewSlots.free--
  else await new Promise(resolve => reviewSlots.queue.push(resolve))
  try { return await fn() }
  finally {
    const next = reviewSlots.queue.shift()
    if (next) next()
    else reviewSlots.free++
  }
}

// Serialized sections: a promise chain per resource. Merges must land one at a
// time, and reconcile/escalate can edit spec.md, so waves take that section in
// turn too. A failed section never poisons the chain for the next caller.
const chain = () => {
  let tail = Promise.resolve()
  return fn => {
    const next = tail.then(fn)
    tail = next.catch(() => {})
    return next
  }
}
const serializedMerge = chain()
const serializedSpec = chain()

const state = Object.fromEntries(items.map(i => [i.id, 'pending']))
const shipped = [], blocked = [], cut = []
// A cut item's feature was amended out of the spec (prefer-smaller-scope):
// terminal like merged/blocked, and it satisfies dependents — the spec no
// longer requires the work they were waiting on.
const cutItem = (id, reason) => {
  state[id] = 'cut'
  cut.push({ id, reason })
  log(`${id} cut: ${reason}`)
}
const block = (id, reason) => {
  state[id] = 'blocked'
  blocked.push({ id, reason })
  log(`${id} blocked: ${reason}`)
}

// One review pass by the run's configured reviewer: with codex, an
// orca:review-codex agent drives Codex through the plugin-bundled orca-codex
// MCP server (its own
// definition carries the review template and the retry rules for transient
// failures and timeouts) and writes the findings JSON verbatim; with claude,
// an orca:review-claude agent performs the review itself and writes findings
// in the identical schema. Either way the agent writes the artifact and the
// round archive, counts the findings it wrote, and returns the counts via
// schema. written=false — a dead tool call, an unparseable payload, a tripped
// self-check — always lands in this retry loop, never in the merge gate; only
// written=true carries counts. Two workflow-level attempts on top of the
// agent's internal retries keeps overall resilience at the old SDK runner's
// level.
const reviewAgentType = reviewer === 'codex' ? 'orca:review-codex' : 'orca:review-claude'

// Least-privilege secrets staging: reviewers consume the run's most
// adversarial content (diffs, findings) and need no credentials, so their
// worktree is stripped of placement links before every review; the stages
// that do need them (implement at worktree add, fix, integrate via the
// skill's placement) re-place. Best-effort both ways — a failed
// place/remove degrades privilege separation, never the run.
const secretsStage = async (verb, wt, label) => {
  if (!pluginRoot) return
  try { await sh(`bash "${pluginRoot}/scripts/secrets.sh" ${verb} "${wt}"`, label, 'Review') }
  catch (err) { log(`secrets ${verb} failed (non-fatal) for ${wt}: ${String((err && err.message) || err)}`) }
}

const review = async (id, worktree, round, mode, ownedFiles = []) => {
  await secretsStage('remove', worktree, `secrets-remove:${id}#${round}`)
  const artifact = `${runDir}/reviews/${id}-${reviewer}.json`
  const archive = `${runDir}/reviews/${id}-${reviewer}.round${round}.json`
  // The integration pseudo-item has no entry in `items`, so the find misses
  // and the status line stays empty — no special-casing.
  // Rounds are 0-indexed internally; the label is 1-based because the subject
  // is user-visible ("review #0" reads like a bug).
  const status = statusLine(items.find(i => i.id === id), `review #${round + 1}`)
  let lastReason
  for (let attempt = 1; attempt <= 2; attempt++) {
    const call = () => agent(
      [`Worktree: ${worktree}`, `Run directory: ${runDir}`, `Item: ${id}`, `Mode: ${mode}`,
       `Artifact path: ${artifact}`, `Round archive path: ${archive}`,
       mode === 'item' ? `Owned files: ${ownedFiles.join(', ') || 'the files its plan names'}` : '',
       status]
        .filter(Boolean).join('\n'),
      tuned('review', { agentType: reviewAgentType, schema: REVIEW,
        label: `review:${id}#${round}${attempt > 1 ? '~retry' : ''}`, phase: 'Review' }))
    // The slot throttle exists only for the shared codex auth — claude
    // reviews run unthrottled.
    const r = reviewer === 'codex' ? await withReviewSlot(call) : await call()
    if (r === null || r === undefined) { lastReason = 'review agent was skipped or died'; continue }
    if (!r.written) { lastReason = r.reason || 'review agent reported written=false with no reason'; continue }
    // An impossible combination is a mis-report, not data — retry it like a
    // written=false: trusting {total: 0, criticalHigh: 2} would skip the fix
    // loop with Critical findings on record.
    if (r.criticalHigh > r.total) {
      lastReason = `review reported criticalHigh (${r.criticalHigh}) > total (${r.total}) — an impossible count`
      continue
    }
    return { total: r.total, criticalOrHigh: r.criticalHigh }
  }
  throw new Error(`${reviewer} review did not complete: ${lastReason}`)
}

// Live per-item display: the main conversation created one session task per
// item before launch and put its id in item.taskId; each stage prompt ends
// with one verbatim TaskUpdate instruction — computed here, executed as the
// first action of the agent that is already running, so the checklist ticks
// with no extra agents. Display-only and fail-soft: the line itself orders
// the agent to proceed on failure, and an item without a taskId (old resume,
// direct launch, the integration pseudo-item) gets no line — which also keeps
// taskId-less prompts byte-identical to the pre-taskId journal keys.
const subjectOf = item => `${item.id} — ${item.title}`
const statusLine = (item, stage, extra = '') => {
  if (!item || !item.taskId) return ''
  // The stage rides on the subject (" · implementing"): the collapsed task
  // panel renders only subjects, so activeForm alone never reaches the user.
  const subject = JSON.stringify(`${subjectOf(item)} · ${stage}`)
  // Every stage reasserts in_progress (idempotent when already correct): if
  // an earlier agent wrongly ticked the task completed, the next stage's
  // first action heals it instead of leaving the row done until run-end
  // reconciliation.
  const fields = `{status: "in_progress", subject: ${subject}, activeForm: "${item.id}: ${stage}"}`
  // Merge passes its completion grant as `extra`; every other stage is
  // mid-pipeline, so its line forbids completing the task — without the ban,
  // a stage agent's end-of-work habit ticks the item done while later
  // stages still run.
  const tail = extra ||
    ' Never set this task\'s status to "completed" — later stages of this item still run; only the merge stage completes it.'
  return `Status task: as your FIRST action, call TaskUpdate on task #${item.taskId} with ${fields}. ` +
    `If the call fails or the tool is missing, skip it and proceed.${tail}`
}

// A replan carries a note naming what failed and a distinct label tag; a
// first-round call passes neither, keeping its prompt and label byte-identical
// to pre-replan journals so resumes still replay. A retry launch rides the
// same seam: item.retryNote (composed by the retry skill) lands in the
// prompt exactly like a replan note — absent, nothing changes.
const planItem = (i, replanNote = '', labelTag = '') => agent(
  [`Run directory: ${runDir}`,
   `Item: ${i.id} — ${i.title}`,
   `Owned files: ${i.files.join(', ')}`,
   `Integration worktree: ${integrationWt}`,
   contextLine,
   i.retryNote || '',
   replanNote,
   statusLine(i, replanNote ? 'replanning' : 'planning')].filter(Boolean).join('\n'),
  tuned('plan', { agentType: 'orca:plan', label: `plan:${i.id}${labelTag}`, phase: 'Plan' }))

// A superseded plan left at plans/<ID>.md reads as finished work to a fresh
// planner — the W3 stall: the replan agent found its predecessor's plan on
// disk, endorsed it as "already complete", and returned without applying the
// spec amendment. Archive it review-style (<ID>.round0.md, first free slot)
// before replanning. Fail-soft: the replan note independently declares any
// surviving plan file superseded, so a failed mv degrades one guard, never
// the wave.
const archivePlan = async (i, tag) => {
  const p = sq(`${runDir}/plans/${i.id}`)
  try {
    await sh(`for n in 0 1 2 3 ; do [ -e '${p}.round'$n'.md' ] || { mv '${p}.md' '${p}.round'$n'.md' ; break ; } ; done`,
      `plan-archive:${i.id}${tag}`, 'Plan')
  } catch (e) { log(`${i.id}: superseded plan not archived (${String((e && e.message) || e)}) — replanning over it`) }
}

// Commit with the attribution rule enforced against the repository itself, not
// the agent's self-report: the actual `git log` message is what gets checked.
// Two agent attempts (reset between them), then a deterministic rewrite.
// The regex holds only unambiguous attribution markers: "ai" and "agent" are
// legitimate domain vocabulary ("user-agent header", "feat: add AI summarizer")
// that false-positives constantly; keeping them out of ordinary prose is the
// stage agents' own instruction, not something a regex can decide. "orca" is
// out for the same reason — dogfooding orca on the orca repo would rewrite
// honest subjects like "feat: orca:status …" into chore: fallbacks.
const banned = /claude|anthropic|co-authored-by|generated (with|by)/i
// The agent may have made several commits, so the banned check must read every
// message it created, never just the tip — a clean later commit would hide a
// banned trailer beneath it. One command returns both the tip message (the
// value reported for the item) and the whole span's messages (what is checked).
const tipAndSpan = async (wt, range, label) => {
  const out = await shMarked(
    `git -C "${wt}" log -1 --format=%B ; echo "@@SPAN@@" ; git -C "${wt}" log --format=%B "${range}"`,
    label, 'Merge')
  return { tip: out.split('@@SPAN@@')[0].trim(), clean: !banned.test(out) }
}
const commitItem = async (wt, id, title, extraLines = []) => {
  const head = async tag => mustSha(
    (await shMarked(`git -C "${wt}" rev-parse HEAD`, `head:${id}#${tag}`, 'Merge')).trim(), `head:${id}#${tag}`)
  const base = await head('base')
  const status = statusLine(items.find(i => i.id === id), 'committing')
  for (let attempt = 1; attempt <= 2; attempt++) {
    must(await agent(
      [`Worktree: ${wt}`, `Run directory: ${runDir}`, `Item: ${id} — ${title}`, ...extraLines,
       attempt > 1 ? 'A previous message violated the attribution rule; describe only the change itself.' : '',
       status]
        .filter(Boolean).join('\n'),
      tuned('commit', { agentType: 'orca:commit', label: `commit:${id}#${attempt}`, phase: 'Merge' })),
      `commit:${id}#${attempt}`)
    const now = await head(attempt)
    if (now === base) {
      if (attempt === 2) {
        // A rebuilt or resumed item may have nothing new to commit — its work
        // is already committed and only a later stage failed. That is success.
        const probe = await sh(
          `if [ -z "$(git -C "${wt}" status --porcelain)" ] && [ "$(git -C "${wt}" rev-list --count "${integrationBranch}..HEAD")" -gt 0 ]; then echo NOTHING_NEW; else echo NEEDS_COMMIT; fi`,
          `probe:${id}`, 'Merge')
        if (probe.includes('NOTHING_NEW')) {
          const prior = await tipAndSpan(wt, `${integrationBranch}..HEAD`, `message:${id}#prior`)
          if (prior.clean) {
            // A salvaged `wip:` tip passes the banned regex but marks a
            // blocked round's partial work, never a finished item — rewrite
            // it like an attribution violation. Amend, not reset+commit:
            // there is nothing to stage, and only the tip needs the new
            // message; a wip commit deeper in the span is honest history.
            if (!/^wip:/i.test(prior.tip)) return { hash: base, message: prior.tip }
            const fallback = banned.test(title) ? `chore: complete work item ${id}` : `chore: ${title}`
            await sh(`git -C "${wt}" commit --amend -m '${sq(fallback)}'`, `wip-rewrite:${id}`, 'Merge')
            return { hash: await head('wip-rewrite'), message: fallback }
          }
          // Prior commits carry a banned marker (they predate this run's
          // checks — e.g. an older plugin's round). The item IS built;
          // falling through to "commit agent made no commit" would block a
          // finished item on a false premise. Squash the span behind a
          // clean message instead — built, with rewritten attribution.
          const fallback = banned.test(title) ? `chore: complete work item ${id}` : `chore: ${title}`
          await sh(`git -C "${wt}" reset --soft "$(git -C "${wt}" merge-base "${integrationBranch}" HEAD)" && ` +
                   `git -C "${wt}" commit -m '${sq(fallback)}'`, `prior-rewrite:${id}`, 'Merge')
          return { hash: await head('prior-rewrite'), message: fallback }
        }
        throw new Error('commit agent made no commit')
      }
      continue
    }
    const msg = await tipAndSpan(wt, `${base}..HEAD`, `message:${id}#${attempt}`)
    if (msg.clean) return { hash: now, message: msg.tip }
    // ${base}, not HEAD~1: the agent may have made zero or several commits.
    if (attempt === 1) await sh(`git -C "${wt}" reset --soft ${base}`, `reset:${id}`, 'Merge')
  }
  const fallback = banned.test(title) ? `chore: complete work item ${id}` : `chore: ${title}`
  // reset + fresh commit, not --amend: the banned marker may sit in a commit
  // below the tip, and an amend rewrites only HEAD.
  await sh(`git -C "${wt}" reset --soft ${base} && git -C "${wt}" commit -m '${sq(fallback)}'`,
           `rewrite:${id}`, 'Merge')
  return { hash: await head('rewrite'), message: fallback }
}

// ---------- per-item pipeline: worktree → implement → review/fix loop → commit → merge ----------
const buildItem = async item => {
  const wt = `${repoRoot}/orca-${slug}-${item.id}`
  const branch = `${integrationBranch}-${item.id}`
  // Single leaf segment (…-W1, not …/W1): a git ref cannot be both a file and a directory.
  // An interrupted run's worktree survives on disk and is resumed in place; a
  // blocked item survives as its branch (worktree salvaged into a WIP commit
  // at block time), picked up by the branch arrival below.
  // -C ${integrationWt}, not ${repoRoot}: the repo root is only a git context
  // via its .git pointer file, and when that file is absent git discovery
  // walks up from it — possibly into an enclosing repo. The integration
  // worktree always resolves to the right bare repo.
  // Three arrivals: the directory survives from a previous run (resume it in
  // place); the directory is gone but its branch survived a half-finished
  // cleanup (re-add the worktree on that branch — `-b` would fail on the
  // collision); a fresh item. `worktree prune` before the re-add drops any
  // stale registration whose directory was deleted by hand, which would
  // otherwise fail the add as "already checked out".
  // Every arrival gets secrets placement — place is idempotent, so re-running
  // it over a resumed worktree's existing links is all-OK output.
  const placeCmd = pluginRoot ? ` && bash "${pluginRoot}/scripts/secrets.sh" place "${wt}"` : ''
  const wtCmd =
    `if [ -d "${wt}" ]; then echo WORKTREE_REUSED; ` +
    `elif git -C "${integrationWt}" rev-parse -q --verify "refs/heads/${branch}" >/dev/null; then ` +
    `git -C "${integrationWt}" worktree prune && git -C "${integrationWt}" worktree add "${wt}" "${branch}" && echo BRANCH_RESUMED; ` +
    `else git -C "${integrationWt}" worktree add "${wt}" -b "${branch}" "${integrationBranch}"; fi${placeCmd}`
  // Parallel items share one git dir; a sibling's ref update can hold
  // index.lock at exactly the wrong moment. One retry before the failure
  // blocks the item and its whole dependent subtree.
  let wtOut
  try { wtOut = await sh(wtCmd, `worktree:${item.id}`, 'Build') }
  catch (err) {
    const msg = String((err && err.message) || err)
    if (!/\.lock|another git process/i.test(msg)) throw err
    log(`${item.id}: worktree add hit a lock-shaped failure — retrying once`)
    wtOut = await sh(wtCmd, `worktree:${item.id}~lockretry`, 'Build')
  }
  if (wtOut.includes('WORKTREE_REUSED')) log(`${item.id}: resuming the worktree left by a previous run`)
  else if (wtOut.includes('BRANCH_RESUMED')) log(`${item.id}: re-created the worktree for the branch left by a previous run`)
  // A secret that could not be placed fails exactly where it fails today —
  // in the build — but with a breadcrumb in the run's logs instead of nothing.
  for (const line of wtOut.split('\n').map(l => l.trim()))
    if (/^(UNIGNORED|SKIPPED_EXISTS|SKIPPED_ERROR):/.test(line))
      log(`${item.id}: secrets ${line.replace(/\t/g, ' ')}`)

  const impl = must(await agent(
    [`Worktree: ${wt}`, `Run directory: ${runDir}`,
     `Item: ${item.id} — ${item.title}`, `Owned files: ${item.files.join(', ')}`,
     statusLine(item, 'implementing')].filter(Boolean).join('\n'),
    tuned('implement', { agentType: 'orca:implement', label: `implement:${item.id}`, phase: 'Build', schema: IMPLEMENT })),
    `implement:${item.id}`)
  // "I could not implement this as specified" is a signal, not noise — without
  // this gate an untouched worktree sails through review (empty diff, zero
  // findings) and only trips at commit time, with the real reason lost.
  if (!impl.completed) throw specRooted(`implementation infeasible: ${impl.summary}`)

  // Review → fix → re-review, max 2 fix rounds, gate on Critical/High (SKILL: bounded loops).
  // A first review with no findings at all has nothing to fix and skips the
  // loop. Keyed on BOTH counts: review() rejects criticalHigh > total as a
  // mis-report, but the gate still refuses to lean on that invariant.
  const first = await review(item.id, wt, 0, 'item', item.files)
  if (first.total > 0 || first.criticalOrHigh > 0) {
    for (let round = 1; ; round++) {
      // The fixer runs tests — it needs the credentials the review stripped.
      await secretsStage('place', wt, `secrets-place:${item.id}#${round}`)
      must(await agent(
        [`Worktree: ${wt}`, `Run directory: ${runDir}`, `Item: ${item.id} — ${item.title}`,
         statusLine(item, `fixing #${round}`)].filter(Boolean).join('\n'),
        tuned('fix', { agentType: 'orca:fix', label: `fix:${item.id}#${round}`, phase: 'Review' })),
        `fix:${item.id}#${round}`)
      const verdict = await review(item.id, wt, round, 'item', item.files)
      if (verdict.criticalOrHigh === 0) break
      if (round === 2) throw specRooted('fix rounds exhausted with Critical/High findings remaining')
    }
  }

  const commit = await commitItem(wt, item.id, item.title,
    item.files.length ? [`Files it owns: ${item.files.join(', ')}`] : [])

  const merge = await serializedMerge(async () => {
    // Self-heal before merging: a predecessor that died mid-conflict must not
    // leave the integration worktree in MERGING state for everyone after it.
    // One command with the tip read — this section is the run's serial
    // bottleneck, so every relay round-trip here is paid by every item.
    const tipBefore = mustSha((await shMarked(
      `git -C "${integrationWt}" merge --abort >/dev/null 2>&1 || true ; git -C "${integrationWt}" rev-parse HEAD`,
      `merge-reset:${item.id}`, 'Merge')).trim(), `merge-reset:${item.id}`)
    const m = must(await agent(
      [`Integration worktree: ${integrationWt}`, `Run directory: ${runDir}`,
       `Item: ${item.id} — ${item.title}`,
       `Item branch: ${branch}`, `Integration branch: ${integrationBranch}`,
       statusLine(item, 'merging', ' After the merge succeeds — only if you will report merged=true — ' +
         `call TaskUpdate once more on the same task with {status: "completed", subject: ${JSON.stringify(subjectOf(item))}, activeForm: "${item.id}: merged"}; ` +
         'the same skip-on-failure rule applies.')]
        .filter(Boolean).join('\n'),
      tuned('merge', { agentType: 'orca:merge', label: `merge:${item.id}`, phase: 'Merge', schema: MERGE })),
      `merge:${item.id}`)
    // The merge agent's commit message is repo state its schema never returns —
    // apply the same attribution backstop as commitItem. Inside the serialized
    // section (an amend must never rewrite a commit a later merge builds on),
    // and only on commits this merge created (tip moved), never pre-run history.
    if (m.merged) {
      // --first-parent: only the commits the merge agent itself created on
      // the integration branch — the item-branch commits it merged in were
      // already checked by commitItem and cannot be rewritten from here.
      // Tip and messages in one command; an unmoved tip yields an empty span.
      const post = await shMarked(
        `git -C "${integrationWt}" rev-parse HEAD ; echo "@@SPAN@@" ; ` +
        `git -C "${integrationWt}" log --first-parent --format=%B "${tipBefore}..HEAD"`,
        `merge-check:${item.id}`, 'Merge')
      const [tipAfter, msgs] = post.split('@@SPAN@@').map(s => (s || '').trim())
      // The rewrite subject keeps the structural `merge <ID>:` prefix —
      // audit's join key — even on the attribution fallback path.
      const safe = `merge ${item.id}: ${banned.test(item.title) ? `work item ${item.id}` : item.title}`
      if (tipAfter !== tipBefore && banned.test(msgs)) {
        const belowTip = await shMarked(
          `git -C "${integrationWt}" log --first-parent --skip=1 --format=%B "${tipBefore}..HEAD"`,
          `merge-below-tip:${item.id}`, 'Merge')
        if (!banned.test(belowTip)) {
          // Only the tip is banned — amend keeps the merge parents intact.
          await sh(`git -C "${integrationWt}" commit --amend -m '${sq(safe)}'`, `merge-amend:${item.id}`, 'Merge')
        } else {
          // A banned message below the tip (a post-merge fix commit sits on
          // top of it) cannot be amended away. Squash the span into one
          // clean commit: content and the attribution guarantee are kept,
          // only the merge topology is given up.
          await sh(`git -C "${integrationWt}" reset --soft ${tipBefore} && git -C "${integrationWt}" commit -m '${sq(safe)}'`,
                   `merge-squash:${item.id}`, 'Merge')
        }
      }
      // Structural join-key guarantee: audit finds an item's merge by the
      // `merge <ID>:` subject prefix on the first-parent log — guaranteed
      // here by the deterministic layer, never by prompt compliance. Read
      // the tip fresh (the attribution backstop may just have rewritten it).
      if (tipAfter !== tipBefore) {
        const prefix = `merge ${item.id}:`
        const info = await shMarked(
          `git -C "${integrationWt}" log -1 --format='%P%x09%s' ; echo "@@MS@@" ; ` +
          `git -C "${integrationWt}" log --first-parent --merges --format=%s "${tipBefore}..HEAD" | tail -1 ; echo "@@MS_END@@" ; ` +
          `git -C "${integrationWt}" log -1 --format=%b`,
          `merge-subject:${item.id}`, 'Merge')
        const [tipLine, mergeSubjRaw, tipBody] = info.split(/@@MS(?:_END)?@@/).map(s => (s || '').trim())
        const [tipParents = '', tipSubj = ''] = tipLine.split('\t')
        const mergeSubj = mergeSubjRaw || tipSubj
        if (!mergeSubj.startsWith(prefix)) {
          if (tipParents.includes(' ') && tipSubj === mergeSubj) {
            // The merge commit is the tip: prepend the prefix, keep the
            // agent's wording and the body's run-level decision bullets.
            const bodyArg = tipBody ? ` -m '${sq(tipBody)}'` : ''
            await sh(`git -C "${integrationWt}" commit --amend -m '${sq(`${prefix} ${mergeSubj}`)}'${bodyArg}`,
                     `merge-subject-amend:${item.id}`, 'Merge')
          } else {
            // The wrong-subject merge sits below later commits — squash the
            // span behind the guaranteed subject (same trade as the
            // attribution fallback: content kept, topology given up).
            await sh(`git -C "${integrationWt}" reset --soft ${tipBefore} && git -C "${integrationWt}" commit -m '${sq(safe)}'`,
                     `merge-subject-squash:${item.id}`, 'Merge')
          }
          log(`${item.id}: merge subject rewritten to carry the required "${prefix}" prefix`)
        }
      }
    }
    return m
  })
  if (!merge.merged) throw specRooted(`merge aborted: ${merge.detail}`)

  // Cleanup is best-effort: the item is already merged, so a dirty worktree
  // (stray build output) must never demote it to blocked.
  try {
    await sh(`git -C "${integrationWt}" worktree remove --force "${wt}" && git -C "${integrationWt}" branch -D "${branch}"`,
             `cleanup:${item.id}`, 'Merge')
  } catch (err) {
    log(`${item.id}: worktree cleanup failed (non-fatal): ${String((err && err.message) || err)}`)
  }
  return commit
}

// ---------- wave: plan in parallel → reconcile/escalate (serialized) → build survivors ----------
const reconcilePrompt = ids =>
  `Read ${runDir}/spec.md (the Interfaces section is the contract) and the plans ` +
  `${ids.map(id => `${runDir}/plans/${id}.md`).join(', ')}. Check each plan against that contract — a plan ` +
  `assuming an interface shape the spec does not define is a conflict even with no sibling — and check ` +
  `across plans for what no single planner could see: an undeclared cross-item dependency, two plans ` +
  `assuming different shapes for a shared contract, or heavy overlap in files both will edit. Report ` +
  `clean=true only on a genuinely clean pass.`

const escalatePrompt = issues =>
  `You are resolving plan-reconciliation issues for an orca run. Issues: ${issues.join('; ')}. ` +
  `Read ${runDir}/spec.md and the plans under ${runDir}/plans/ (files named <ID>.round*.md are ` +
  `superseded archives of failed plans — ignore them). For each issue: if a fix preserves the ` +
  `spec's outcome, features, and non-goals (it changes only how, not what), AMEND — edit spec.md's ` +
  `Interfaces yourself and append the decision to its "## Decisions" log as a one-line bullet tagged ` +
  `with the affected item ids ("- (W3) chose X over Y: <reason>"), citing the Doubt Rule where ` +
  `it applied; list the item ids whose plans must be regenerated in "replan". When the spec's doubt rule ` +
  `is prefer-smaller-scope and an item's feature can be cleanly cut rather than blocked, cutting it is an ` +
  `amendment: edit spec.md to remove the feature, record the cut in "## Decisions" (same tagged-bullet format), and list that item in ` +
  `"cut". If every fix would change what was agreed, list those items in "blocked" with a one-line reason ` +
  `and the options the user must choose between. When an amendment declares a dependency between work ` +
  `items that the breakdown lacked, also report it in "addDeps" as {id, dependsOn: [ids]} — the scheduler ` +
  `orders builds from addDeps alone, and a dependency written only into spec.md never changes build order. ` +
  `Report addDeps as [] when no dependencies changed. The run's item set is frozen: never add, split, ` +
  `merge, or rename work items in the breakdown — the scheduler executes only the items it was launched ` +
  `with plus the moves you report structurally (replan, cut, blocked, addDeps), and a restructure written ` +
  `into spec.md alone would silently never run. If the only real fix is a restructure, list the affected ` +
  `items in "blocked" instead. Never expand scope past a non-goal.`

// Replan prompts must differ from the round they replace: the planner needs
// to know the previous plan failed and why, or nothing stops it from
// reproducing the same answer — or endorsing the archived one. The note also
// re-points it at the Decisions log, where an amendment's operative
// instruction may live when the seam it governs is not in the Interfaces
// section.
const waveReplanNote = (id, issues) =>
  `Replan: this item's previous plan failed cross-plan reconciliation, and spec.md was amended in ` +
  `response — read its "## Decisions" log; bullets tagged ${id} are binding contract amendments, ` +
  `including where they constrain internals the Interfaces section leaves to you. Reconciliation ` +
  `issues: ${issues.join('; ')}. The superseded plan is archived at plans/${id}.round*.md — read it ` +
  `to see what must change, then write a fresh plan resolving every issue above. Never conclude the ` +
  `existing work is already correct: the previous plan FAILED, and a plans/${id}.md still on disk is ` +
  `superseded, not evidence of completion.`
const rebuildReplanNote = (id, failure) =>
  `Replan: this item was built once and failed mid-build ("${failure}"); an escalation judged the ` +
  `failure spec-rooted and amended spec.md in response — read its "## Decisions" log; bullets tagged ` +
  `${id} are binding contract amendments. The superseded plan is archived at plans/${id}.round*.md — ` +
  `read it to see what must change, then write a fresh plan that resolves the failure. The item's ` +
  `worktree is kept and will be rebuilt from your new plan.`

// Dependency amendments must land in the scheduler, not only in spec.md: pump()
// orders builds from the in-memory `items`, so a dependency the escalation
// agent writes into the breakdown alone would never change build order. It
// reports them structurally in "addDeps"; they are applied here. Only ids from
// the breakdown, only items not already building (pending, or this wave's —
// still held by the serialized section), and never an edge that would create a
// cycle: a cycle would leave items pending forever and hang the scheduler.
const reaches = (from, to) => {
  const seen = new Set(), stack = [from]
  while (stack.length) {
    const cur = stack.pop()
    if (cur === to) return true
    if (seen.has(cur)) continue
    seen.add(cur)
    const it = items.find(i => i.id === cur)
    if (it) stack.push(...it.deps)
  }
  return false
}
const applyDepAmendments = (addDeps, wave) => {
  for (const a of addDeps || []) {
    const it = items.find(i => i.id === a.id)
    if (!it) continue
    const eligible = state[it.id] === 'pending' ||
      (state[it.id] === 'active' && wave.some(w => w.id === it.id))
    for (const dep of a.dependsOn) {
      if (dep === a.id || it.deps.includes(dep) || !items.some(i => i.id === dep)) continue
      if (!eligible) { log(`dependency ${a.id} → ${dep} not applied: ${a.id} is already building or done`); continue }
      if (reaches(dep, a.id)) { log(`dependency ${a.id} → ${dep} not applied: it would create a cycle`); continue }
      it.deps.push(dep)
      log(`dependency added: ${a.id} now waits for ${dep}`)
    }
  }
}

// Mid-build escalation: a failure that smells spec-rooted gets one amend-vs-block
// judgment and, on amendment, one replan + rebuild in the item's kept worktree
// before it can block. Anything else blocks immediately. Spec-rooted failures
// are tagged where they are thrown, never pattern-matched from the message —
// rewording a message must not silently disable escalation for its class.
const specRooted = reason => Object.assign(new Error(reason), { escalatable: true })
const buildEscalatePrompt = (item, failure) =>
  `An orca work item failed mid-build. Item: ${item.id} — ${item.title}. Failure: ${failure}. ` +
  `Read ${runDir}/spec.md, the plan ${runDir}/plans/${item.id}.md, and this item's latest review artifact ` +
  `under ${runDir}/reviews/ if one exists. Apply the escalation rule. action="rebuild" when a spec-level ` +
  `fix preserves the spec's outcome, features, and non-goals (it changes only how, not what): edit spec.md's ` +
  `Interfaces yourself and append the decision to its "## Decisions" log as a one-line bullet tagged ` +
  `with the affected item ids ("- (W3) chose X over Y: <reason>"), citing the Doubt ` +
  `Rule where it applied — the item is then re-planned and rebuilt once in its existing worktree. ` +
  `Never restructure the breakdown (add, split, merge, or rename work items): the scheduler executes only ` +
  `the item set it was launched with, so a restructure written into spec.md would silently never run — ` +
  `if only a restructure would fix this, choose "block". ` +
  `action="cut" when the doubt rule is prefer-smaller-scope and this item's feature can be cleanly cut ` +
  `rather than blocked: edit spec.md to remove the feature and record the cut in "## Decisions" (same tagged-bullet format). ` +
  `action="block" when every fix would change what was agreed; reason = one line plus the options the ` +
  `user must choose between. Never expand scope past a non-goal.`

const runWave = async wave => {
  const tag = wave.map(i => i.id).join('+')
  const plans = await parallel(wave.map(i => () => planItem(i)))
  plans.forEach((p, idx) => { if (p === null || p === undefined) block(wave[idx].id, 'plan agent was skipped or died') })

  // Escalation edits spec.md, so waves take the reconcile section one at a time.
  await serializedSpec(async () => {
    let live = wave.filter(i => state[i.id] === 'active')
    if (!live.length) return
    let rec = must(await agent(reconcilePrompt(live.map(i => i.id)),
      { model: 'opus', effort: 'high', label: `reconcile:${tag}`, phase: 'Plan', schema: RECONCILE }),
      `reconcile:${tag}`)
    if (rec.clean) return
    log(`reconciliation issues: ${rec.issues.join('; ')}`)
    // Escalation, SKILL rules: amend when the fix changes only *how* (edit spec.md, replan);
    // block when any fix would change *what* the brief promised.
    const esc = must(await agent(escalatePrompt(rec.issues),
      { model: 'opus', effort: 'high', label: `escalate:${tag}`, phase: 'Plan', schema: ESCALATE }),
      `escalate:${tag}`)
    // Only ids actually in this wave — the schema cannot stop the model from
    // naming an item it was never asked about, and a stray id would corrupt
    // the state table and the final report.
    esc.blocked.filter(b => live.some(i => i.id === b.id)).forEach(b => block(b.id, b.reason))
    esc.cut.filter(c => live.some(i => i.id === c.id)).forEach(c => cutItem(c.id, c.reason))
    applyDepAmendments(esc.addDeps, wave)
    // Ordering constraint: the replan set is computed BEFORE the deferral
    // pass below — deferral flips items back to `pending`, and an item that
    // is both deferred and replanned would otherwise drop out of the replan
    // filter, leaving its superseded plan at plans/<ID>.md to stall the
    // fresh planner pump() spawns later (the W3 stall).
    const replanSet = live.filter(i => esc.replan.includes(i.id) && state[i.id] === 'active')
    // A wave item whose amended dependencies are not all merged has not started
    // building (the build loop runs after this serialized section) — send it
    // back to pending; pump() relaunches it the moment they are.
    wave.filter(i => state[i.id] === 'active' &&
        i.deps.some(d => state[d] !== 'merged' && state[d] !== 'cut'))
      .forEach(i => { state[i.id] = 'pending'; log(`${i.id} deferred: an amended dependency must merge first`) })
    // Deferred-and-replanned items get the archive now: their next planner
    // (spawned by pump() with no replan note) would otherwise find the
    // superseded plan on disk and endorse it as finished work. Only items
    // still active are replanned inside this wave.
    const deferredReplans = replanSet.filter(i => state[i.id] !== 'active')
    if (deferredReplans.length)
      await parallel(deferredReplans.map(i => () => archivePlan(i, '#deferred')))
    const replan = replanSet.filter(i => state[i.id] === 'active')
    if (replan.length) {
      await parallel(replan.map(i => () => archivePlan(i, '#2')))
      const second = await parallel(replan.map(i => () => planItem(i, waveReplanNote(i.id, rec.issues), '#2')))
      second.forEach((p, idx) => { if (p === null || p === undefined) block(replan[idx].id, 'plan agent was skipped or died') })
    }
    live = wave.filter(i => state[i.id] === 'active')
    if (!live.length) return
    // Always re-check after an amendment — even one that named no plans to
    // regenerate — so a fall-through never builds on plans that failed reconciliation.
    rec = must(await agent(reconcilePrompt(live.map(i => i.id)),
      { model: 'opus', effort: 'high', label: `reconcile#2:${tag}`, phase: 'Plan', schema: RECONCILE }),
      `reconcile#2:${tag}`)
    if (!rec.clean) {
      // Block only the items the unresolved issues actually name — a clean
      // sibling in the same wave must not be collateral. An issue naming no
      // live item cannot be attributed and keeps the conservative
      // whole-wave block.
      const mentioned = new Set()
      let unattributed = false
      for (const issue of rec.issues) {
        const ids = (issue.match(/\b[WF][1-9][0-9]*\b/g) || []).filter(id => live.some(i => i.id === id))
        if (ids.length) ids.forEach(id => mentioned.add(id))
        else unattributed = true
      }
      const victims = unattributed ? live : live.filter(i => mentioned.has(i.id))
      victims.forEach(i => block(i.id, `unresolved after amendment: ${rec.issues.join('; ')}`))
    }
  })

  // No barrier from here: each survivor pipelines through build → merge on its
  // own, and every completion re-pumps the scheduler so dependents launch the
  // moment their own deps are in — never when the whole wave is.
  for (const item of wave.filter(i => state[i.id] === 'active')) {
    // runItem resolves for every failure it can judge, but it can still reject
    // — e.g. the budget ceiling makes its re-plan agent() call throw. Without
    // a rejection handler the item would stay active forever and `drained`
    // would never resolve.
    runItem(item)
      .catch(err => { if (state[item.id] === 'active') block(item.id, String((err && err.message) || err)) })
      .then(() => pump())
  }
}

// Salvage a blocking item's worktree: commit whatever is in the tree as WIP
// on the item branch (skip the commit when the index stays empty), then
// remove the worktree — the branch is the recovery surface a retry round
// resumes via the branch arrival in buildItem; the directory is just
// clutter at the repo root. Best-effort under the same contract as the
// merged-path cleanup: a failure here logs and never demotes or re-throws,
// and an unfinished salvage leaves the worktree in place rather than
// removing unsaved work. The WIP message is deterministic and passes the
// `banned` regex; commitItem rewrites it if it ever surfaces as a tip.
const salvageWorktree = async item => {
  const wt = `${repoRoot}/orca-${slug}-${item.id}`
  try {
    await sh(
      `if [ -d "${wt}" ]; then git -C "${wt}" add -A && ` +
      `{ git -C "${wt}" diff --cached --quiet || git -C "${wt}" commit -m 'wip: ${item.id} — blocked, partial work' ; } && ` +
      `git -C "${integrationWt}" worktree remove --force "${wt}" ; else echo NO_WORKTREE ; fi`,
      `salvage:${item.id}`, 'Build')
  } catch (err) {
    log(`${item.id}: worktree salvage failed (non-fatal): ${String((err && err.message) || err)}`)
  }
}

// Build one item, with at most one escalation-backed retry: a spec-rooted
// failure (see `escalatable`) gets an amend-vs-block judgment, and an
// amendment replans and rebuilds the item once in its kept worktree.
const runItem = async item => {
  for (let attempt = 1; ; attempt++) {
    try {
      const commit = await buildItem(item)
      state[item.id] = 'merged'
      shipped.push({ id: item.id, title: item.title, hash: commit.hash, message: commit.message })
      log(`${item.id} merged (${commit.hash})`)
      return
    } catch (err) {
      const reason = String((err && err.message) || err)
      // A blocked item keeps its branch for a retry round (SKILL: escalation
      // rule); the worktree is salvaged into a WIP commit on that branch.
      if (attempt === 2 || !(err && err.escalatable)) { await salvageWorktree(item); return block(item.id, reason) }
      let esc = null
      try {
        // Escalation edits spec.md — same serialized section as wave reconciliation.
        esc = await serializedSpec(() => agent(buildEscalatePrompt(item, reason),
          { model: 'opus', effort: 'high', label: `escalate:${item.id}`, phase: 'Build', schema: BUILD_ESCALATE }))
      } catch (e) { /* fall through: a dead escalation agent means block */ }
      if (!esc || esc.action === 'block') { await salvageWorktree(item); return block(item.id, (esc && esc.reason) || reason) }
      // A cut is terminal like a block: the same salvage (WIP commit on the
      // kept branch, worktree removed) keeps partial work reachable and
      // stops a later same-slug run from hitting WORKTREE_REUSED for an
      // item the spec no longer contains.
      if (esc.action === 'cut') { await salvageWorktree(item); return cutItem(item.id, esc.reason) }
      log(`${item.id}: spec amended after "${reason}" — replanning and rebuilding once`)
      await archivePlan(item, '#rebuild')
      const p = await planItem(item, rebuildReplanNote(item.id, reason), '#rebuild')
      if (p === null || p === undefined) { await salvageWorktree(item); return block(item.id, 'plan agent was skipped or died during re-plan') }
    }
  }
}

// ---------- completion-driven scheduler ----------
// States: pending → active (planning/building) → merged | cut | blocked. pump()
// runs after every completion: it blocks items whose dependencies can no longer
// merge, launches a wave of the items whose dependencies are all satisfied
// (merged, or cut out of the spec), and resolves `drained` once nothing is
// pending or active. It loops to a fixpoint so a
// cascade (budget stop → dependents unrunnable) settles in one call.
let finishRun
const drained = new Promise(resolve => { finishRun = resolve })

const pump = () => {
  for (;;) {
    const depBlocked = items.filter(i => state[i.id] === 'pending' && i.deps.some(d => state[d] === 'blocked'))
    depBlocked.forEach(i => block(i.id, `dependency blocked: ${i.deps.filter(d => state[d] === 'blocked').join(', ')}`))

    const wave = items.filter(i => state[i.id] === 'pending' &&
      i.deps.every(d => state[d] === 'merged' || state[d] === 'cut'))
    if (!wave.length) { if (!depBlocked.length) break; continue }

    if (budget.total && budget.remaining() < 50_000) {
      log('token budget nearly exhausted — not starting further items')
      wave.forEach(i => block(i.id, 'run stopped: token budget exhausted'))
      continue
    }

    wave.forEach(i => { state[i.id] = 'active' })
    runWave(wave)
      .catch(err => wave.filter(i => state[i.id] === 'active')
        .forEach(i => block(i.id, String((err && err.message) || err))))
      .then(() => pump())
  }
  if (!items.some(i => state[i.id] === 'pending' || state[i.id] === 'active')) finishRun()
}

// Fail fast on a malformed breakdown. An unknown dependency id or a dependency
// cycle can never satisfy the wave filter or the blocked cascade, so its item
// would sit `pending` forever and `await drained` would hang the run — with
// every already-merged item's work left unreported.
const knownIds = new Set(items.map(i => i.id))
if (knownIds.size !== items.length)
  throw new Error('invalid work breakdown: duplicate item ids')
const unknownDeps = items.flatMap(i => i.deps.filter(d => !knownIds.has(d)).map(d => `${i.id} depends on unknown ${d}`))
if (unknownDeps.length)
  throw new Error(`invalid work breakdown: ${unknownDeps.join('; ')}`)
const cyclic = items.filter(i => i.deps.some(d => reaches(d, i.id))).map(i => i.id)
if (cyclic.length)
  throw new Error(`invalid work breakdown: dependency cycle through ${cyclic.join(', ')}`)

// ---------- per-run lease (codex F-03) ----------
// Two writers over one run dir — a second session launching the same run,
// a relaunch racing a workflow that is still alive — would interleave
// plans/, reviews/, and the integration worktree. Atomic mkdir is the
// lock; the owner file inside carries pid-less metadata (what took it,
// when). A resume (resumeFromRunId) replays this call from the journal
// without re-executing, so the holder's own resume never self-deadlocks;
// a FRESH launch over a live lease fails typed here, and the launching
// skill's stale-lock recovery (user-confirmed rm of .lock) handles a
// crashed holder. Released at the end of the run.
const leaseNote = `orca work loop; slug=${slug}; branch=${integrationBranch}`
const leaseOut = await sh(
  `if mkdir '${sq(runDir)}/.lock' 2>/dev/null ; then ` +
  `{ echo '${sq(leaseNote)}' ; date '+%Y-%m-%dT%H:%M:%S%z' ; } > '${sq(runDir)}/.lock/owner' ; echo LEASE_OK ; ` +
  `else echo LEASE_HELD ; cat '${sq(runDir)}/.lock/owner' 2>/dev/null ; true ; fi`,
  'run-lease', 'Plan')
if (leaseOut.includes('LEASE_HELD'))
  throw new Error(`run directory is leased to another writer — ${runDir}/.lock exists ` +
    `(owner: ${leaseOut.split('\n').slice(1).join(' ').trim() || 'unknown'}). ` +
    `If that run is dead, confirm with the user, remove ${runDir}/.lock, and relaunch.`)
const releaseLease = async () => {
  try { await sh(`rm -rf '${sq(runDir)}/.lock'`, 'run-lease-release', 'Context') }
  catch (err) { log(`run lease not released (non-fatal): ${String((err && err.message) || err)}`) }
}

pump()
await drained

// ---------- integration verification (the tail of SKILL Step 4) ----------
phase('Integrate')
let integration = { features: [], fixesApplied: false, gaps: ['skipped: no items merged'] }
// Terminal deliverable state (codex F-09) — exactly one per run:
//   'verified'   the integrate agent completed and the branch tip is the
//                tree it verified (fixes, if any, reviewed clean and
//                committed)
//   'unverified' merged work exists but the branch tip lacks a completed
//                verification: the verifier died, or fixes it applied
//                could not be reviewed clean and committed
//   'built'      nothing merged this run — verification never ran
// The report and the audit/retry skills read this instead of inferring
// "completed deliverable" from the mere presence of a branch.
let deliverableState = 'built'
if (shipped.length) {
  try {
    integration = must(await agent(
      [`Integration worktree: ${integrationWt}`, `Run directory: ${runDir}`].join('\n'),
      tuned('integrate', { agentType: 'orca:integrate', label: 'integration-verify', schema: INTEGRATION })),
      'integration-verify')
    deliverableState = 'verified'
  } catch (err) {
    // The run result must survive a dead verifier: hours of merged work stay
    // reported, and the missing verification lands as a gap — an uncaught
    // throw here would fail the workflow and lose {shipped, blocked} entirely.
    integration = { features: [], fixesApplied: false,
      gaps: [`integration verification did not complete: ${String((err && err.message) || err)}`] }
    deliverableState = 'unverified'
  }

  if (integration.fixesApplied) {
    // Integration fixes pass the same gate items do (buildItem's bounded
    // review → fix → re-review loop): block while Critical/High findings
    // remain after two fix rounds, and never commit when the review itself
    // failed — an unreviewed commit would ship the one edit in this run no
    // independent reviewer ever saw. Uncommitted fixes stay in the
    // integration worktree; the gap names the state for audit/retry.
    let reviewedClean = false
    const fixNotes = { declines: [], escalations: [] }
    try {
      // A reviewer switch on retry (codex run resumed as claude, or vice
      // versa) can leave the other reviewer's integration artifact on disk
      // while fix.md asserts exactly one exists — the fixer would read last
      // round's stale findings beside the fresh ones. Clear both names
      // before this run's reviewer writes its own.
      await sh(`rm -f '${sq(runDir)}/reviews/integration-codex.json' '${sq(runDir)}/reviews/integration-claude.json'`,
        'integration-review-clean', 'Review')
      const first = await review('integration', integrationWt, 0, 'integration')
      if (first.total === 0 && first.criticalOrHigh === 0) reviewedClean = true
      else {
        for (let round = 1; ; round++) {
          await secretsStage('place', integrationWt, `secrets-place:integration#${round}`)
          const fixed = must(await agent(
            [`Worktree: ${integrationWt}`, `Run directory: ${runDir}`,
             `Item: integration — fixes applied during integration verification`,
             `There is no plan file for this item; the spec is the reference.`].join('\n'),
            tuned('fix', { agentType: 'orca:fix', label: `fix:integration#${round}`, phase: 'Review', schema: INTEGRATION_FIX })),
            `fix:integration#${round}`)
          fixNotes.declines.push(...fixed.declines)
          fixNotes.escalations.push(...fixed.escalations)
          const verdict = await review('integration', integrationWt, round, 'integration')
          if (verdict.criticalOrHigh === 0) { reviewedClean = true; break }
          if (round === 2) {
            log('integration fixes blocked: fix rounds exhausted with Critical/High findings remaining — left uncommitted, branch unverified')
            integration.gaps.push('integration fixes blocked after two fix rounds with Critical/High findings remaining — left uncommitted in the integration worktree')
            deliverableState = 'unverified'
            break
          }
        }
      }
    } catch (err) {
      const reason = String((err && err.message) || err)
      log(`integration review did not complete — fixes left uncommitted, branch unverified (${reason})`)
      integration.gaps.push(`integration fixes were NOT committed: their independent review did not complete (${reason}) — they remain uncommitted in the integration worktree`)
      deliverableState = 'unverified'
    }
    // The integration review stripped the worktree's secrets — restore them
    // so later merges in a retry round and the user's own use of the
    // worktree find their .envs.
    await secretsStage('place', integrationWt, 'secrets-restore:integration')
    // Persist the fixer's declines/escalations: with no plan file to carry
    // Deviations, an unpersisted return would be the only record — lost.
    integration.fixNotes = fixNotes
    if (fixNotes.declines.length || fixNotes.escalations.length) {
      try {
        await sh(`printf '%s\\n' '${sq(JSON.stringify(fixNotes, null, 2))}' > '${sq(runDir)}/integration-fixes.json'`,
          'integration-fix-notes', 'Integrate')
      } catch (err) {
        log(`integration fix notes not persisted (non-fatal): ${String((err && err.message) || err)} — they remain in the workflow result`)
      }
    }
    if (reviewedClean) {
      try {
        const status = await sh(
          `[ -n "$(git -C "${integrationWt}" status --porcelain)" ] && echo DIRTY || echo CLEAN`,
          'integration-status', 'Merge')
        if (status.includes('DIRTY')) {
          const c = await commitItem(integrationWt, 'integration', 'integration fixes from full-feature verification',
            ['There is no plan file for this item; commit the integration fixes only.'])
          log(`integration fixes committed (${c.hash})`)
        }
      } catch (err) {
        integration.gaps.push(`integration fixes could not be committed: ${String((err && err.message) || err)}`)
        // The verified tree was the fixed one; the branch tip is not it.
        deliverableState = 'unverified'
      }
    }
  }
}

// ---------- context maintenance ----------
// Fold the run into the machine-local project context. Non-fatal by design:
// a run whose context agent dies still delivered its branch — the promotions
// list just stays empty and the next run's refresh step catches the files up.
let promotions = []
if (updateContext && shipped.length) {
  phase('Context')
  try {
    const ctx = await agent(
      [`Run directory: ${runDir}`,
       `Integration worktree: ${integrationWt}`,
       `Context files: ${repoRoot}/.orca/map.md (codebase map) and ${repoRoot}/.orca/decisions.md (decision log)`]
        .join('\n'),
      { agentType: 'orca:context', label: 'context', phase: 'Context', schema: CONTEXT })
    if (ctx) {
      promotions = ctx.promotions
      log(`context ${ctx.updated ? 'updated' : 'unchanged'}: ${ctx.summary}`)
    } else {
      log('context agent was skipped or died (non-fatal) — the next run refreshes the context files')
    }
  } catch (err) {
    log(`context maintenance failed (non-fatal): ${String((err && err.message) || err)}`)
  }
}

await releaseLease()
return { shipped, cut, blocked, integration, deliverableState, promotions, tokensSpent: budget.spent() }
