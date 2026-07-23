// orca debug loop — the autonomous middle of the orca:debug skill (repro gate,
// hypothesis fan-out, adversarial verification, judged diagnosis, nested fix,
// deterministic repro check) as a deterministic workflow.
//
// The main conversation runs the skill's interactive steps (triage, interview,
// pre-flights, confirmation, worktree creation) and the final report, then
// invokes this script via the Workflow tool. Everything that must not decay
// over a long context is code here: the hard repro gate (no deterministic
// repro -> the run stops loudly; exit 125 "cannot test" fails it like exit 0
// does), the single internal retry after a committed fix leaves the repro red
// (the failed attempt is reverted on the branch tip first — its diff stays in
// history as evidence), worktree-per-hypothesis isolation with cleanup
// after each verdict, and a zero-judgment repro check whose branching lives in
// script code, never in a model. The fix tail is not reimplemented: it is a
// nested workflow() call to work-loop.workflow.js over a synthesized one-item
// breakdown, so the fix gets the same plan/implement/review/fix/commit/merge/
// integrate machinery — and the same resolved reviewer — as a feature run.
//
// args: {
//   runDir       .orca/<timestamp>-bug-<slug> — hypotheses, verdicts/, diagnosis.md,
//                fix/ (the nested run dir; never a top-level spec.md) (absolute)
//   repoRoot     parent of the bare repo; all worktrees live here (absolute)
//   slug         case slug; the skill pre-created the case worktree
//                <repoRoot>/orca-bug-<slug> (branch bug/<slug>) and, under
//                diagnose-and-fix, the fix integration worktree
//                <repoRoot>/orca-fix-<slug> (branch fix/<slug>)
//   caseDir      .orca/bug-cases/<slug> — case.md, repro.sh, ledger.md,
//                evidence/ (absolute)
//   scope        'diagnose-only' | 'diagnose-and-fix' — the case's scope rule
//   hasRepro     boolean — the case already holds a repro.sh from a prior run;
//                it is re-confirmed (still exits bug-present) instead of rebuilt
//   workLoopPath absolute path of work-loop.workflow.js, for the nested fix
//                call — scripts cannot resolve ${CLAUDE_PLUGIN_ROOT} themselves
//   reviewer     'codex' | 'claude' — passed verbatim to the nested work loop.
//                REQUIRED even under diagnose-only (where it is unused): the
//                skill resolves it before launch and a resume must replay it
//   agents       optional { <stage>: { model?, effort? } } from
//                <repo-root>/.orca/config — one shared block for both
//                verbs: the debug stages (reproduce, hypothesize, verify,
//                diagnose) are applied here, the feature stages are validated
//                here and applied by the nested work loop, which receives the
//                block verbatim
//   fixTaskId    optional id of the fix work item's session task (created by
//                the main conversation before launch under diagnose-and-fix);
//                threaded into the nested work loop's item for live display
//   pluginRoot   REQUIRED absolute path of the installed plugin root (the
//                launching skill substitutes ${CLAUDE_PLUGIN_ROOT} — this
//                script has no environment to resolve it from). The
//                per-hypothesis worktree ritual runs through the
//                plugin-shipped CLI (scripts/orca.sh, which chains
//                its secrets verb), and the nested work loop receives the
//                value verbatim — it refuses launch without it — so a
//                missing plugin root refuses HERE, typed (NO_PLUGIN_ROOT),
//                not at the Fix phase an hour in
// }
//
// Return: { status: 'fixed'|'not-fixed'|'diagnosed'|'undiagnosed'|'no-repro',
//           diagnosis?, fixBranch? (present iff a fix attempt was committed,
//           whatever the final status), notes? (no-repro: what the attempt
//           hit; not-fixed: why the fix is unverified when repro.sh exits
//           125), promotions? (fixed only: knowledge the context agent
//           flagged for human promotion), hypothesesTested, tokensSpent }

export const meta = {
  name: 'orca-debug-loop',
  description: 'Reproduce, hypothesize, verify, and diagnose a bug case — and under diagnose-and-fix, land and re-check a fix',
  phases: [
    { title: 'Repro', detail: 'establish or re-confirm the deterministic repro script (hard gate)' },
    { title: 'Hypothesize', detail: 'ranked root-cause candidates from case, ledger, and evidence' },
    { title: 'Verify', detail: 'adversarial verification, one throwaway worktree per hypothesis' },
    { title: 'Diagnose', detail: 'judge merges the verdicts into one root-cause statement' },
    { title: 'Fix', detail: 'nested work loop over the synthesized one-item fix contract' },
    { title: 'Check', detail: 'deterministic repro re-run in the fix integration worktree' },
    { title: 'Context', detail: 'fold the landed fix into the machine-local project context' },
  ],
}

// Recover a JSON-encoded args delivery, then fail fast — at launch, not
// mid-run — on anything missing or mis-shaped (same posture as work-loop).
let parsedArgs = args
if (typeof parsedArgs === 'string') {
  try { parsedArgs = JSON.parse(parsedArgs) }
  catch { throw new Error('args arrived as a string that is not valid JSON — pass args as a real JSON object') }
}
if (typeof parsedArgs !== 'object' || parsedArgs === null)
  throw new Error(`args must be a JSON object (got ${JSON.stringify(args)}) — pass it as a real object, not a JSON-encoded string`)
const { runDir, repoRoot, slug, caseDir, scope, hasRepro, workLoopPath, reviewer, fixTaskId } = parsedArgs
for (const [k, v] of Object.entries({ runDir, repoRoot, slug, caseDir, workLoopPath }))
  if (typeof v !== 'string' || !v)
    throw new Error(`args.${k} must be a non-empty string (got ${JSON.stringify(v)})`)
// Absolute paths only: agents resolve them from their own working directories.
for (const [k, v] of Object.entries({ runDir, repoRoot, caseDir, workLoopPath }))
  if (!v.startsWith('/'))
    throw new Error(`args.${k} must be an absolute path (got ${JSON.stringify(v)})`)
if (scope !== 'diagnose-only' && scope !== 'diagnose-and-fix')
  throw new Error(`args.scope must be "diagnose-only" or "diagnose-and-fix" (got ${JSON.stringify(scope)})`)
if (typeof hasRepro !== 'boolean')
  throw new Error(`args.hasRepro must be a boolean (got ${JSON.stringify(hasRepro)})`)
if (reviewer !== 'codex' && reviewer !== 'claude')
  throw new Error(`args.reviewer must be "codex" or "claude" (got ${JSON.stringify(reviewer)}) — the skill resolves it before launch`)
if (fixTaskId !== undefined && (typeof fixTaskId !== 'string' || !fixTaskId))
  throw new Error(`args.fixTaskId, when present, must be a non-empty string (got ${JSON.stringify(fixTaskId)})`)
// Grammar validation at the deterministic boundary (same posture as
// work-loop): the slug is interpolated into worktree paths and the
// bug/<slug>, fix/<slug> refs by every stage — a malformed one must fail
// here, not deep in the run. Hypothesis (H<n>) and fix-item (F<n>) ids are
// generated internally and need no launch grammar.
//   valid:   "login-crash", "oom2"
//   invalid: "Login", "a_b", "-x", "a/b", ""
const SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
if (!SLUG_RE.test(slug))
  throw new Error(`args.slug must match ${SLUG_RE} (got ${JSON.stringify(slug)})`)
// The hypothesis worktree ritual runs through the plugin-shipped CLI, and
// the nested work loop refuses to launch without a pluginRoot — mandatory,
// refused typed here at launch rather than at the Fix phase an hour in
// (same posture and failure type as work-loop).
const pluginRoot = parsedArgs.pluginRoot
if (typeof pluginRoot !== 'string' || !pluginRoot.startsWith('/'))
  throw new Error(`NO_PLUGIN_ROOT: args.pluginRoot must be the installed plugin's absolute path (got ${JSON.stringify(pluginRoot)}) — the launching skill substitutes \${CLAUDE_PLUGIN_ROOT}`)

// Per-stage model/effort overrides (args.agents). The stage vocabulary is the
// ONE shared 12-key list — feature's stages plus debug's — kept in lockstep
// across scripts/lib.sh (the config verb's write path, and the run skills' launch validation
// via its validate subcommand), work-loop.workflow.js, and this script: the
// config file has a single agents block, and a key accepted by any validator
// must be accepted by all three, or a written override bricks the other
// verb's launches. MODELS/EFFORTS have a FOURTH holder: spec.workflow.js
// carries its own literal copies for the spec spawn's model/effort
// validation. This script applies
// only the debug stages; the rest are validated here and applied by the
// nested work loop, which receives the block verbatim — except agents.spec,
// which the nested loop also only validates: debug runs never spawn a spec
// agent (the diagnose agent writes the fix contract).
const DEBUG_TUNABLE = ['reproduce', 'hypothesize', 'verify', 'diagnose']
const STAGES = ['spec', 'plan', 'implement', 'review', 'fix', 'commit', 'merge', 'integrate', ...DEBUG_TUNABLE]
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
}
const tuned = (stage, opts) => {
  const cfg = agentCfg[stage]
  if (!cfg) return opts
  const out = { ...opts }
  if (cfg.model) out.model = cfg.model
  if (cfg.effort) out.effort = cfg.effort
  return out
}

const baseWt = `${repoRoot}/orca-bug-${slug}`
const baseBranch = `bug/${slug}`
const fixWt = `${repoRoot}/orca-fix-${slug}`
const fixBranch = `fix/${slug}`
const reproCmd = `bash "${caseDir}/repro.sh"`

// Machine-local project context: hints injected into the judgment-stage
// prompts (hypothesize, diagnose). The run skill's refresh step made the
// files current before launch; agents skip a missing file.
const contextLine = `Project context: ${repoRoot}/.orca/map.md (codebase map) and ${repoRoot}/.orca/decisions.md (decision log) — hints from a snapshot at the commit stamped in each header, not ground truth: read them first for where to look, verify anything you rely on; file paths rot slower than implementation details. A missing file is skipped, not an error.`

// ---------- structured-output schemas ----------
const CONTEXT = { type: 'object', additionalProperties: false,
  required: ['updated', 'promotions', 'summary'],
  properties: { updated: { type: 'boolean' },
    promotions: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' } } }
const REPRODUCE = { type: 'object', additionalProperties: false, required: ['reproduced', 'notes'],
  properties: { reproduced: { type: 'boolean' }, notes: { type: 'string' } } }
const HYPOTHESES = { type: 'object', additionalProperties: false, required: ['hypotheses'],
  properties: { hypotheses: { type: 'array', minItems: 1, maxItems: 8, items: {
    type: 'object', additionalProperties: false, required: ['id', 'statement'],
    properties: { id: { type: 'string' }, statement: { type: 'string' } } } } } }
const VERDICT = { type: 'object', additionalProperties: false, required: ['verdict', 'summary'],
  properties: {
    verdict: { type: 'string', enum: ['confirmed', 'refuted', 'inconclusive'] },
    summary: { type: 'string' } } }
const DIAGNOSIS = { type: 'object', additionalProperties: false,
  required: ['diagnosed', 'rootCause', 'fixTitle', 'ownedFiles'],
  properties: { diagnosed: { type: 'boolean' }, rootCause: { type: 'string' },
    fixTitle: { type: 'string' }, ownedFiles: { type: 'array', items: { type: 'string' } } } }

// ---------- helpers ----------
const must = (result, what) => {
  if (result === null || result === undefined)
    throw new Error(`${what}: agent was skipped or returned no result`)
  return result
}

// The script has no shell; deterministic commands run through a haiku agent
// with an exit-status marker (same relay as work-loop). One core does the
// relay and the marker parsing; exit-code POLICY lives in the two wrappers
// below, so a parsing fix can never drift between them.
const relay = async (cmd, label, ph) => {
  const prompt = `Run exactly this command and return its complete output verbatim — plain text, no code fences, no commentary:\n{ ${cmd} ; } ; echo "SH_RC=$?"`
  const raw = await agent(prompt, { model: 'haiku', effort: 'low', label, phase: ph })
  if (raw === null || raw === undefined) throw new Error(`${label}: command agent was skipped or died`)
  const out = raw.split('\n').filter(l => !/^\s*`{3,}/.test(l)).join('\n')
  const marks = [...out.matchAll(/SH_RC=(\d+)/g)]
  if (!marks.length) throw new Error(`${label}: no exit-status marker in command output: ${out.trim().slice(-300)}`)
  const m = marks[marks.length - 1]
  return { exitCode: Number(m[1]), output: out.slice(0, m.index).trim() }
}

// Plumbing commands must succeed: a nonzero exit throws.
const sh = async (cmd, label, ph) => {
  const r = await relay(cmd, label, ph)
  if (r.exitCode !== 0) throw new Error(`${label}: command exited ${r.exitCode}: ${r.output.slice(-300)}`)
  return r.output
}

// The repro check: the zero-judgment checker the skill's design names. It
// cannot share sh()'s throw-on-nonzero policy — here the exit STATUS is the
// signal (0 = bug absent, 125 = cannot test, other 1-127 = bug present; the
// git-bisect-run contract), and every consumer must branch on all three
// bands in script code. A failed cd maps to 125 in a subshell: a missing
// worktree is "cannot test", never "bug present".
const reproCheck = async (wt, label, ph) => {
  const r = await relay(`( cd "${wt}" || exit 125 ; ${reproCmd} )`, label, ph)
  // Normalize the cannot-test band: >127 is a signal death (137 = SIGKILL,
  // the OOM killer's signature) and 124 is GNU timeout — neither is
  // evidence the bug is present, and a correct fix must never be reverted
  // because the tree was OOM-killed mid-check. Both collapse to 125,
  // git-bisect's own skip code, so every consumer's three-band branch
  // handles them as cannot-test.
  const exitCode = (r.exitCode > 127 || r.exitCode === 124) ? 125 : r.exitCode
  return { exitCode, rawExitCode: r.exitCode, output: r.output.slice(-2000) }
}

// sh() keeps any leading relay commentary in its output, so anything that
// gets PARSED — the revert-target sha — must come from between explicit
// markers, never the raw transcript (work-loop's shMarked rule). Marker lines
// are matched whole, so the echoed command text can never match.
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

// ---------- relay codec: base64 + UTF-8 + frame decoder ----------
// LOCKSTEP: a literal copy of this block lives in each workflow script
// that calls the CLI verbs — the sandbox reads no files, so each script
// carries its own (the MODELS/EFFORTS precedent); CI extracts and tests
// the block under node (.github/scripts/frame-decoder-test.js). The
// sandbox exposes NO atob/btoa/Buffer/TextDecoder/TextEncoder (verified
// empirically 2026-07-23 with a zero-agent probe) — "standard JS
// built-ins" means ECMAScript only, so the UTF-8 step is hand-rolled
// here: commit messages carry non-ASCII.
const B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
const b64encode = s => {
  const b = []
  for (const ch of s) {
    const cp = ch.codePointAt(0)
    if (cp < 0x80) b.push(cp)
    else if (cp < 0x800) b.push(0xc0 | (cp >> 6), 0x80 | (cp & 63))
    else if (cp < 0x10000) b.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63))
    else b.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63))
  }
  let out = ''
  for (let i = 0; i < b.length; i += 3) {
    const n = (b[i] << 16) | ((b[i + 1] ?? 0) << 8) | (b[i + 2] ?? 0)
    out += B64_ALPHABET[n >> 18] + B64_ALPHABET[(n >> 12) & 63] +
      (i + 1 < b.length ? B64_ALPHABET[(n >> 6) & 63] : '=') +
      (i + 2 < b.length ? B64_ALPHABET[n & 63] : '=')
  }
  return out
}
const b64decode = s => {
  const clean = s.replace(/\s+/g, '').replace(/=+$/, '')
  if (!/^[A-Za-z0-9+/]*$/.test(clean) || clean.length % 4 === 1)
    throw new Error('value is not base64')
  const bytes = []
  for (let i = 0; i < clean.length; i += 4) {
    const chunk = clean.slice(i, i + 4)
    let n = 0
    for (const c of chunk) n = (n << 6) | B64_ALPHABET.indexOf(c)
    n <<= 6 * (4 - chunk.length)
    bytes.push((n >> 16) & 255)
    if (chunk.length > 2) bytes.push((n >> 8) & 255)
    if (chunk.length > 3) bytes.push(n & 255)
  }
  let out = ''
  for (let i = 0; i < bytes.length;) {
    const b0 = bytes[i++]
    let cp, extra
    if (b0 < 0x80) { cp = b0; extra = 0 }
    else if ((b0 & 0xe0) === 0xc0) { cp = b0 & 31; extra = 1 }
    else if ((b0 & 0xf0) === 0xe0) { cp = b0 & 15; extra = 2 }
    else if ((b0 & 0xf8) === 0xf0) { cp = b0 & 7; extra = 3 }
    else throw new Error('decoded value is not valid UTF-8')
    for (; extra > 0; extra--) {
      const bn = bytes[i++]
      if (bn === undefined || (bn & 0xc0) !== 0x80) throw new Error('decoded value is not valid UTF-8')
      cp = (cp << 6) | (bn & 63)
    }
    out += String.fromCodePoint(cp)
  }
  return out
}
// Frame grammar, normative alongside lib.sh's emitter: between @@ORCA@@
// and @@ORCA_END@@, a line opening one of the frame's DECLARED keys
// (each verb's key set is fixed) starts that key; ANY other line is a
// continuation of the open key's value — joined, then whitespace
// stripped from .b64 values before decoding. The continuation rule is
// what lets a relay-wrapped multi-KB message.b64 line rejoin instead of
// burning the one retry; matching declared keys (not a generic charset)
// keeps a wrapped base64 continuation ending in '=' padding from
// masquerading as a key line. A continuation before any key, or a .b64
// value that still fails to decode after the join, throws — the loud
// retryable frame-decode failure. Decoded .b64 keys land WITHOUT the
// suffix (message.b64 -> message).
const decodeFrame = (raw, keys) => {
  const lines = raw.split('\n')
  const a = lines.findIndex(l => l.trim() === '@@ORCA@@')
  const b = lines.map(l => l.trim()).lastIndexOf('@@ORCA_END@@')
  if (a === -1 || b <= a) throw new Error('frame markers missing from verb output')
  const out = {}
  let open = null
  for (const line of lines.slice(a + 1, b)) {
    const key = keys.find(k => line.startsWith(`${k}=`))
    if (key) { open = key; out[key] = line.slice(key.length + 1) }
    else if (open !== null) out[open] += line
    else if (line.trim() === '') continue
    else throw new Error(`frame continuation before any key: ${line.slice(0, 80)}`)
  }
  for (const k of Object.keys(out)) {
    if (k.endsWith('.b64')) { out[k.slice(0, -4)] = b64decode(out[k]); delete out[k] }
    else out[k] = out[k].trim()
  }
  return out
}
// ---------- end relay codec ----------

// One relay call per ritual: run a CLI verb through the dispatcher and
// decode its frame. One retry on frame-decode failure, then fail —
// bounded, matching the lock-retry temperament. A nonzero exit (the
// verb's typed FAIL line) is the verb's own verdict, thrown by sh() and
// never retried here. Returns { frame, raw } — raw so callers can
// surface the verb's pass-through lines (secrets placement).
const verb = async (argline, keys, label, ph) => {
  const cmd = `bash "${pluginRoot}/scripts/orca.sh" ${argline}`
  for (let attempt = 1; ; attempt++) {
    const raw = await sh(cmd, attempt > 1 ? `${label}~frameretry` : label, ph)
    try { return { frame: decodeFrame(raw, keys), raw } }
    catch (err) {
      if (attempt === 2)
        throw new Error(`${label}: verb frame did not decode after a retry: ${String((err && err.message) || err)}`)
    }
  }
}
const WORKTREE_KEYS = ['rc', 'arrival', 'head']

// ---------- per-run lease (codex F-03; same design as work-loop) ----------
// Atomic mkdir is the lock, owner metadata inside, refusal typed. A resume
// replays this from the journal without re-executing (no self-deadlock); a
// fresh launch over a live lease fails here, and the skill's user-confirmed
// recovery removes a stale .lock. Released on every terminal return via
// finish().
const leaseNote = `orca debug loop; slug=${slug}; scope=${scope}`
const leaseOut = await sh(
  `if mkdir '${sq(runDir)}/.lock' 2>/dev/null ; then ` +
  `{ echo '${sq(leaseNote)}' ; date '+%Y-%m-%dT%H:%M:%S%z' ; } > '${sq(runDir)}/.lock/owner' ; echo LEASE_OK ; ` +
  `else echo LEASE_HELD ; cat '${sq(runDir)}/.lock/owner' 2>/dev/null ; true ; fi`,
  'run-lease', 'Repro')
if (leaseOut.includes('LEASE_HELD'))
  throw new Error(`run directory is leased to another writer — ${runDir}/.lock exists ` +
    `(owner: ${leaseOut.split('\n').slice(1).join(' ').trim() || 'unknown'}). ` +
    `If that run is dead, confirm with the user, remove ${runDir}/.lock, and relaunch.`)
const finish = async result => {
  try { await sh(`rm -rf '${sq(runDir)}/.lock'`, 'run-lease-release', 'Check') }
  catch (err) { log(`run lease not released (non-fatal): ${String((err && err.message) || err)}`) }
  return result
}

// ---------- phase 1: the repro gate (hard) ----------
phase('Repro')
let needReproduce = true
let staleRepro = ''   // why the prior repro.sh cannot be trusted, for the reproduce prompt
if (hasRepro) {
  // A prior run established repro.sh — re-confirm it still shows the bug
  // before trusting it, rather than verifying hypotheses against a dead probe.
  // Exit 0 (bug gone) and exit 125 (tree cannot run the probe) both mean the
  // probe cannot be trusted as-is.
  const check = await reproCheck(baseWt, 'repro-confirm', 'Repro')
  if (check.exitCode === 0) {
    staleRepro = 'exits 0 — it no longer demonstrates the bug'
    log('the prior repro.sh exits 0 — it no longer shows the bug; re-establishing the repro')
  } else if (check.exitCode === 125) {
    staleRepro = 'exits 125 — the tree cannot run it (missing prerequisites or an unrelated break)'
    log('the prior repro.sh exits 125 — the tree cannot be tested; re-establishing the repro')
  } else {
    needReproduce = false
    log(`prior repro.sh re-confirmed (exit ${check.exitCode})`)
  }
}
if (needReproduce) {
  const rep = must(await agent(
    [`Worktree: ${baseWt}`,
     `Case directory: ${caseDir}`,
     `Run directory: ${runDir}`,
     staleRepro ? `A previous run's repro.sh exists at ${caseDir}/repro.sh but currently ${staleRepro} in this worktree. Investigate why and rewrite it.` : '']
      .filter(Boolean).join('\n'),
    tuned('reproduce', { agentType: 'orca:reproduce', label: 'reproduce', phase: 'Repro', schema: REPRODUCE })),
    'reproduce')
  if (!rep.reproduced)
    return finish({ status: 'no-repro', notes: rep.notes, hypothesesTested: 0, tokensSpent: budget.spent() })
  // The gate is deterministic, never the agent's self-report: run the script.
  // Exit 0 and exit 125 both fail it — a tree that cannot be tested is not a
  // reproduction.
  const check = await reproCheck(baseWt, 'repro-gate', 'Repro')
  if (check.exitCode === 0 || check.exitCode === 125)
    return finish({ status: 'no-repro',
      notes: `reproduce agent reported success but repro.sh exits ${check.exitCode}${check.exitCode === 125 ? ' (cannot test)' : ''} in ${baseWt}: ${rep.notes}`,
      hypothesesTested: 0, tokensSpent: budget.spent() })
  log(`repro established (exit ${check.exitCode})`)
}

// ---------- phases 2-6: one cycle, with exactly one internal retry ----------
// tested accumulates across rounds; ids stay unique (H1..Hn, then H<n+1>..),
// so verdict files and worktrees never collide between rounds.
const tested = []   // { id, statement, verdict, summary, round }
let lastFailedFix = null   // { rootCause, reason, committed } — evidence for the round-2 regenerate
let diagnosis = null
let fixCommitted = false   // a fix attempt was merged onto the fix branch (any round)
let fixBaseSha = null      // fix-branch tip before the first attempt — the revert target

// One hypothesis: worktree off the case branch -> verify agent -> cleanup.
// A dead verify agent yields null (recorded as inconclusive by the caller);
// its worktree is kept for inspection — cleanup runs only after a verdict.
const verifyOne = async (h, hypPath) => {
  const wt = `${repoRoot}/orca-bug-${slug}-${h.id}`
  const branch = `${baseBranch}-${h.id}`
  // One relay call for the whole ritual (same worktree-item verb as the
  // work loop): three arrivals — a worktree or branch left by an
  // interrupted run is resumed, not a collision — the bounded index.lock
  // retry (up to 8 hypothesis worktrees are added concurrently off one git
  // dir), and chained secrets placement. -C the case worktree — the repo
  // root is only a git context via its .git pointer file.
  // Least-privilege note: unlike the work loop's review stage, every stage
  // that runs in a hypothesis worktree (reproduce, verify) executes
  // repro.sh, which needs the credentials — so placement stays.
  const wtRes = await verb(
    `worktree-item "${baseWt}" "${wt}" "${branch}" "${baseBranch}"`,
    WORKTREE_KEYS, `worktree:${h.id}`, 'Verify')
  if (wtRes.frame.arrival === 'reused') log(`${h.id}: resuming the worktree left by an interrupted run`)
  for (const line of wtRes.raw.split('\n').map(l => l.trim()))
    if (/^(UNIGNORED|SKIPPED_EXISTS|SKIPPED_ERROR):/.test(line))
      log(`${h.id}: secrets ${line.replace(/\t/g, ' ')}`)

  const short = h.statement.length > 60 ? `${h.statement.slice(0, 57)}…` : h.statement
  const v = await agent(
    [`Worktree: ${wt}`,
     `Case directory: ${caseDir}`,
     `Run directory: ${runDir}`,
     `Hypothesis: ${h.id} — ${h.statement}`,
     `Hypotheses file: ${hypPath} — your hypothesis's full entry (causal story, killing evidence, falsification experiment) is there${h.fileId && h.fileId !== h.id ? ` under the id "${h.fileId}"` : ''}.`,
     `Verdict artifact path: ${runDir}/verdicts/${h.id}.json`,
     `Repro command: ${reproCmd} — run from the worktree root; exit 0 = bug absent, 1-127 = bug present, 125 = cannot test (git-bisect-run compatible).`,
     // JSON.stringify: a statement containing quotes must not garble the
     // subject the agent is told to set verbatim.
     `Status task: as your FIRST action, create one session task via TaskCreate with subject ${JSON.stringify(`${h.id} — ${short}`)}, then set it in_progress via TaskUpdate with activeForm "verifying ${h.id}". Just before returning, TaskUpdate it to completed with subject ${JSON.stringify(`${h.id} — ${short} · `)}<your verdict>. If a call fails or the tools are missing, skip it and proceed; never touch any other task.`]
      .join('\n'),
    tuned('verify', { agentType: 'orca:verify', label: `verify:${h.id}`, phase: 'Verify', schema: VERDICT }))
  if (v === null || v === undefined) return null

  // Hypothesis worktrees never merge — remove after the verdict (best-effort:
  // a stray build artifact must never fail the round).
  try {
    await sh(`git -C "${baseWt}" worktree remove --force "${wt}" && git -C "${baseWt}" branch -D "${branch}"`,
             `cleanup:${h.id}`, 'Verify')
  } catch (err) {
    log(`${h.id}: worktree cleanup failed (non-fatal): ${String((err && err.message) || err)}`)
  }
  return v
}

for (let round = 1; round <= 2; round++) {
  // ---------- phase 2: hypothesize ----------
  phase('Hypothesize')
  const offset = tested.length
  const hypPath = round === 1 ? `${runDir}/hypotheses.md` : `${runDir}/hypotheses-${round}.md`
  const refuted = tested.filter(t => t.verdict === 'refuted')
  const inconclusive = tested.filter(t => t.verdict === 'inconclusive')
  const hyp = must(await agent(
    [`Case directory: ${caseDir}`,
     `Run directory: ${runDir}`,
     `Exploration worktree: ${baseWt}`,
     contextLine,
     `Hypotheses file to write: ${hypPath}`,
     `Number your hypotheses sequentially from H${offset + 1} — ids must be unique across this run.`,
     refuted.length ? `Refuted THIS run — never re-propose: ${refuted.map(t => `${t.id}: ${t.statement}`).join('; ')}` : '',
     inconclusive.length ? `Inconclusive THIS run — start from these: ${inconclusive.map(t => `${t.id}: ${t.statement}`).join('; ')}` : '',
     lastFailedFix ? (lastFailedFix.committed
       ? `A committed fix attempt for the diagnosis "${lastFailedFix.rootCause}" did not clear the repro (${lastFailedFix.reason}). Its diff is in the history of branch ${fixBranch} — the tip carries a revert of it, so read it with git log/show from the exploration worktree and treat it as first-class evidence.`
       : `A fix attempt for the diagnosis "${lastFailedFix.rootCause}" never landed a commit (${lastFailedFix.reason}). There is no diff to read; the diagnosis itself was not disproven — weigh it accordingly.`) : '']
      .filter(Boolean).join('\n'),
    tuned('hypothesize', { agentType: 'orca:hypothesize', label: `hypothesize#${round}`, phase: 'Hypothesize', schema: HYPOTHESES })),
    `hypothesize#${round}`)
  // Keep the agent's ids when they are exactly the assigned set (in any
  // order) — the file was written under those ids, so matching by id keeps
  // each verify prompt's statement aligned with the file entry it reads even
  // if the return order differs from the file's. Creative ids fall back to
  // positional numbering, which the prompt assigned.
  const expectedIds = hyp.hypotheses.map((_, i) => `H${offset + i + 1}`)
  const returnedIds = hyp.hypotheses.map(h => String(h.id || '').trim().toUpperCase())
  const idsUsable = new Set(returnedIds).size === returnedIds.length &&
    returnedIds.every(id => expectedIds.includes(id))
  if (!idsUsable)
    log(`round ${round}: hypothesize returned unexpected ids (${returnedIds.join(', ')}) — falling back to positional H-numbering`)
  // fileId keeps the agent's original spelling: the hypotheses FILE was
  // written under it (e.g. "h3"), and the verify agent must find its entry
  // there even when the run's canonical id normalized the case.
  const hyps = hyp.hypotheses.map((h, i) => ({
    id: idsUsable ? returnedIds[i] : `H${offset + i + 1}`,
    fileId: String(h.id || '').trim() || `H${offset + i + 1}`,
    statement: h.statement }))
  log(`round ${round}: ${hyps.length} hypotheses to verify`)

  // ---------- phase 3: verify (parallel, worktree-isolated) ----------
  phase('Verify')
  const verdicts = await parallel(hyps.map(h => () => verifyOne(h, hypPath)))
  verdicts.forEach((v, i) => tested.push({
    ...hyps[i], round,
    verdict: v ? v.verdict : 'inconclusive',
    summary: v ? v.summary : 'verify agent was skipped or died — worktree kept for inspection' }))
  const roundVerdicts = tested.filter(t => t.round === round)
  log(`round ${round} verdicts: ${roundVerdicts.map(t => `${t.id}=${t.verdict}`).join(', ')}`)

  // ---------- phase 4: diagnose ----------
  phase('Diagnose')
  const fixItemId = `F${round}`
  const hypFiles = round === 1 ? `${runDir}/hypotheses.md` : `${runDir}/hypotheses.md, ${runDir}/hypotheses-2.md`
  const diag = must(await agent(
    [`Case directory: ${caseDir}`,
     `Run directory: ${runDir}`,
     contextLine,
     `Hypotheses files: ${hypFiles}`,
     `Verdicts directory: ${runDir}/verdicts (one JSON per hypothesis)`,
     `Diagnosis file to write: ${runDir}/diagnosis.md`,
     `Scope: ${scope}`,
     scope === 'diagnose-and-fix'
       ? `Fix contract: if you confirm a root cause, write the synthesized spec to ${runDir}/fix/spec.md with the single work item ${fixItemId} — the repro command its Features section must cite is: ${reproCmd}`
       : '',
     lastFailedFix ? (lastFailedFix.committed
       ? `A previous fix attempt for "${lastFailedFix.rootCause}" left the repro red (${lastFailedFix.reason}); its diff is in the history of branch ${fixBranch} (reverted on the tip). Your new contract supersedes the existing ${runDir}/fix/spec.md — read it, judge what the failed diff proves, and rewrite it.`
       : `A previous fix attempt for "${lastFailedFix.rootCause}" never landed a commit (${lastFailedFix.reason}). The existing ${runDir}/fix/spec.md may have been amended by that run's escalation — your new contract supersedes it: rewrite it from your own diagnosis.`) : '']
      .filter(Boolean).join('\n'),
    tuned('diagnose', { agentType: 'orca:diagnose', label: `diagnose#${round}`, phase: 'Diagnose', schema: DIAGNOSIS })),
    `diagnose#${round}`)

  if (!diag.diagnosed) {
    // Honest "nothing confirmed" — no retry: the inconclusives are in the
    // verdicts and land in the ledger. In round 2 a committed failed fix may
    // sit on the fix branch (reverted on its tip) — return the branch so the
    // report and ledger keep the record, and keep round 1's diagnosis too:
    // it was judged and attempted, and the report must not lose it just
    // because round 2 confirmed nothing new.
    return finish({ status: 'undiagnosed', ...(diagnosis ? { diagnosis } : {}),
      ...(fixCommitted ? { fixBranch } : {}),
      hypothesesTested: tested.length, tokensSpent: budget.spent() })
  }
  diagnosis = diag.rootCause
  log(`diagnosed: ${diagnosis.length > 120 ? `${diagnosis.slice(0, 117)}…` : diagnosis}`)
  if (scope === 'diagnose-only')
    return finish({ status: 'diagnosed', diagnosis, hypothesesTested: tested.length, tokensSpent: budget.spent() })

  // ---------- phase 5: fix (nested work loop) ----------
  phase('Fix')
  const item = { id: fixItemId, title: diag.fixTitle || `fix ${slug}`, deps: [],
    files: Array.isArray(diag.ownedFiles) ? diag.ownedFiles : [] }
  if (fixTaskId) item.taskId = fixTaskId
  // The revert target for a failed committed attempt: the branch tip before
  // anything landed on it. Journaled, so a resume replays the same sha. The
  // sha is interpolated into the revert command, so it is read through
  // markers and hex-validated; a garbled read degrades to no-revert (the
  // revert is best-effort anyway), never to a corrupt git command.
  if (round === 1) {
    const sha = (await shMarked(`git -C "${fixWt}" rev-parse HEAD`, 'fix-base', 'Fix')).trim()
    if (/^[0-9a-f]{40}$/.test(sha)) fixBaseSha = sha
    else log(`fix-base: relay returned something that is not a commit sha (${sha.slice(0, 80)}) — a failed attempt will not be reverted`)
  }
  // The nested work loop takes its own lease on runDir/fix. Anyone
  // legitimately writing there holds THIS run's lease on runDir (fix/ is
  // inside it), so a .lock surviving from a crashed prior nested attempt
  // is stale by construction — clear it or round 2 and resumes would
  // refuse against a dead holder.
  try { await sh(`rm -rf '${sq(runDir)}/fix/.lock'`, `fix-lease-clear#${round}`, 'Fix') }
  catch { /* the nested launch will surface a real problem */ }
  let fixRun = null
  try {
    fixRun = await workflow({ scriptPath: workLoopPath }, {
      runDir: `${runDir}/fix`,
      repoRoot,
      slug: `fix-${slug}`,            // work-loop derives the integration worktree <repoRoot>/orca-fix-<slug>
      integrationBranch: fixBranch,   // and item branches fix/<slug>-F<n>
      items: [item],
      reviewer,
      // This run maintains the project context itself after the Check phase,
      // with the diagnosis in hand — the nested loop must not double-run it.
      updateContext: false,
      ...(Object.keys(agentCfg).length ? { agents: agentCfg } : {}),
      pluginRoot,
    })
  } catch (err) {
    log(`fix attempt ${round}: nested work loop failed: ${String((err && err.message) || err)}`)
  }
  const shippedFix = fixRun && Array.isArray(fixRun.shipped) && fixRun.shipped.length > 0
  if (!shippedFix) {
    // The work loop's terminal buckets: an item cut by escalation (licensed
    // by the contract's prefer-smaller-scope doubt rule) is not "blocked" —
    // surface its reason too, or the ledger records a generic no-commit line.
    const cut = fixRun && Array.isArray(fixRun.cut) && fixRun.cut.length
      ? `cut by escalation: ${fixRun.cut.map(c => `${c.id}: ${c.reason}`).join('; ')}` : ''
    const blocked = fixRun && Array.isArray(fixRun.blocked) && fixRun.blocked.length
      ? fixRun.blocked.map(b => `${b.id}: ${b.reason}`).join('; ') : ''
    const reason = [cut, blocked].filter(Boolean).join('; ') || 'the nested work loop landed no fix commit'
    log(`fix attempt ${round} did not land: ${reason}`)
    if (round === 2)
      return finish({ status: 'not-fixed', diagnosis, ...(fixCommitted ? { fixBranch } : {}),
        hypothesesTested: tested.length, tokensSpent: budget.spent() })
    lastFailedFix = { rootCause: diagnosis, reason, committed: false }
    continue
  }
  fixCommitted = true

  // ---------- phase 6: the deterministic repro check ----------
  phase('Check')
  const check = await reproCheck(fixWt, `repro-check#${round}`, 'Check')
  if (check.exitCode === 0) {
    log(`repro.sh exits 0 in ${fixWt} — fixed`)
    // Fold the landed fix into the machine-local project context. Non-fatal:
    // a run whose context agent dies still delivered its branch.
    phase('Context')
    let promotions = []
    try {
      const ctx = await agent(
        [`Run directory: ${runDir}`,
         `Integration worktree: ${fixWt}`,
         `Context files: ${repoRoot}/.orca/map.md (codebase map) and ${repoRoot}/.orca/decisions.md (decision log)`,
         `This was a debug run: the diagnosis is ${runDir}/diagnosis.md and the fix contract with its plans is under ${runDir}/fix/.`]
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
    return finish({ status: 'fixed', diagnosis, fixBranch, promotions, hypothesesTested: tested.length, tokensSpent: budget.spent() })
  }
  if (check.exitCode === 125) {
    // Cannot-test is not "still red": the committed fix is unverified, and a
    // retry premised on "the bug still reproduces" would build on a false
    // premise. Stop loudly instead.
    log(`repro.sh exits 125 in ${fixWt} — the tree cannot be tested; the fix is unverified`)
    return finish({ status: 'not-fixed', diagnosis, fixBranch,
      notes: `the committed fix is unverified: repro.sh exits 125 (cannot test) in ${fixWt} — repair the tree (build, dependencies), then re-run the case`,
      hypothesesTested: tested.length, tokensSpent: budget.spent() })
  }
  log(`fix attempt ${round}: repro.sh still exits ${check.exitCode} in ${fixWt}`)
  if (round === 2)
    return finish({ status: 'not-fixed', diagnosis, fixBranch, hypothesesTested: tested.length, tokensSpent: budget.spent() })
  // One internal retry: revert the failed attempt on the fix branch tip (a
  // single commit restoring the pre-attempt tree — the diff stays in history
  // as ledger evidence, but round 2 builds from a tree without the wrong fix
  // and its regression test asserting the superseded causal story), then
  // hypotheses regenerate once (refuted ones excluded).
  if (fixBaseSha) {
    try {
      await sh(`git -C "${fixWt}" read-tree --reset -u "${fixBaseSha}" && git -C "${fixWt}" commit -m "Revert unverified fix approach"`,
               'revert-fix', 'Check')
      log(`fix attempt ${round} reverted on the ${fixBranch} tip — diff kept in history as evidence`)
    } catch (err) {
      log(`fix attempt ${round}: revert failed (non-fatal; round 2 builds on the failed tree): ${String((err && err.message) || err)}`)
    }
  } else {
    log(`fix attempt ${round}: no valid revert target recorded — round 2 builds on the failed tree`)
  }
  lastFailedFix = { rootCause: diagnosis, committed: true,
    reason: `repro.sh still exits ${check.exitCode} after the committed fix` }
}

// Unreachable — both rounds return — but a linter-visible fallback beats an
// undefined workflow result if the loop is ever edited.
return finish({ status: 'not-fixed', diagnosis, ...(fixCommitted ? { fixBranch } : {}),
  hypothesesTested: tested.length, tokensSpent: budget.spent() })
