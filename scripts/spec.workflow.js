// orca spec stage — the gated workflow that spawns orca:spec, then an
// independent adversarial review of the spec it wrote.
//
// The feature skill composes the complete task message (run dir, repo root,
// timestamp, brief, optional Project context line) and invokes this script
// through the Workflow tool. Routing the spawn through a workflow instead of
// the Agent tool is what makes spec.effort an ordinary override: the Agent
// tool has a model parameter but no effort parameter, while agent() here
// takes both alongside agentType — so the spec stage gets the same
// {model, effort} tuning surface as every workflow-spawned stage.
//
// After the spec agent writes <runDir>/spec.md, the run's reviewer — the
// same codex-or-claude selection the work loop uses — reads brief and spec
// together against a clean checkout of the codebase and writes a findings
// artifact. Critical/High findings trigger exactly one revise round (an
// orca:spec re-spawn over the current spec plus the findings) whose output
// is final: the revised spec proceeds with no re-review and no further
// gate — the item reviews and integration verification are the backstop.
// Medium/Low never block. The review fails OPEN: a courier that cannot
// complete after a retry never bricks the run — the skill relays the
// failure as one-way status and every downstream gate still stands.
//
// args: {
//   prompt          the complete task message for the orca:spec agent,
//                   composed by the skill exactly as the conversational
//                   spawn composed it. This script never reads files — the
//                   workflow sandbox has no filesystem access
//   model           optional model override (agents.spec.model from the
//                   config) — applied to the spec agent and its revise
//                   spawn, never to the reviewer
//   effort          optional effort override (agents.spec.effort) — same
//                   application
//   runDir          absolute path to the run directory (brief.md, spec.md,
//                   reviews/)
//   reviewWorktree  absolute path to the clean throwaway review worktree
//                   the skill created at the trunk tip (detached, no
//                   branch, no secrets placed)
//   reviewer        'codex' | 'claude' — the run's held reviewer; selects
//                   orca:spec-review-<reviewer>. No overrides apply to it:
//                   like reconcile and escalate, its cost/judgment profile
//                   lives in the agent frontmatter
//   amendPath       optional absolute path marking this an AMEND round —
//                   the iterate skill's spec stage, where the agent writes
//                   an amendment file (spec.amendment.md) beside the
//                   delivered spec instead of authoring <runDir>/spec.md.
//                   When set: the revise prompt's hardcoded lines point at
//                   <amendPath> ("rewrite <amendPath> in place") instead of
//                   <runDir>/spec.md; the review spawn's task message gains
//                   an `Amendment path: <amendPath>` line; and the review
//                   artifact becomes spec-amend-<reviewer>.json, never
//                   clobbering the original run's spec review. When absent,
//                   the fresh-spec path is byte-identical to before the arg
//                   existed.
// }
//
// Return: { summary, died, review } —
//   summary  the latest spec agent's final text (the revise spawn's when a
//            revise round ran), or null with died: true when the spec agent
//            was skipped or died on a terminal API error before anything
//            else ran (review is absent in that one case)
//   review   { written, total, criticalHigh, revised, reason }
//            written      whether the review produced an artifact (false =
//                         the review failed open; the counts are 0 and
//                         reason names why)
//            total        finding count from the written artifact
//            criticalHigh Critical/High count from the artifact
//            revised      whether the revise round ran to completion —
//                         criticalHigh > 0 with revised: false means the
//                         revise spawn died and the findings stand
//                         unaddressed: the skill's surface-and-stop gate.
//                         With revised: true the counts are what the
//                         revision folded in, never a still-standing gate
//            reason       '' when nothing needs relaying; otherwise one
//                         line (fail-open cause, or the dead revise spawn)
//
// No resume plumbing, deliberately: the whole stage is cheap to redo. An
// interrupted spec stage relaunches fresh; the runId is throwaway and is
// never persisted anywhere.

export const meta = {
  name: 'orca-spec',
  description: "Author the run's spec from the confirmed brief, then adversarially review it against brief and codebase — one final revise round on Critical/High findings",
  phases: [
    { title: 'Spec', detail: 'orca:spec authors spec.md from the brief' },
    { title: 'Review', detail: 'independent reviewer reads brief + spec against a clean checkout' },
    { title: 'Revise', detail: 'one orca:spec re-spawn folds Critical/High findings in — its output launches' },
  ],
}

// Recover a JSON-encoded args delivery, then fail fast — at launch, not
// mid-run — on anything missing or mis-shaped (same posture as the loop
// scripts).
let parsedArgs = args
if (typeof parsedArgs === 'string') {
  try { parsedArgs = JSON.parse(parsedArgs) }
  catch { throw new Error('args arrived as a string that is not valid JSON — pass args as a real JSON object') }
}
if (typeof parsedArgs !== 'object' || parsedArgs === null)
  throw new Error(`args must be a JSON object (got ${JSON.stringify(args)}) — pass it as a real object, not a JSON-encoded string`)
const { prompt, model, effort, runDir, reviewWorktree, reviewer, amendPath } = parsedArgs
for (const [k, v] of Object.entries({ prompt, runDir, reviewWorktree }))
  if (typeof v !== 'string' || !v)
    throw new Error(`args.${k} must be a non-empty string (got ${JSON.stringify(v)})`)
if (amendPath !== undefined && (typeof amendPath !== 'string' || !amendPath))
  throw new Error(`args.amendPath must be a non-empty string when present (got ${JSON.stringify(amendPath)})`)
// Absolute paths only: the reviewer resolves them from its own working
// directory, so a relative path silently points it somewhere else.
for (const [k, v] of Object.entries(amendPath !== undefined
  ? { runDir, reviewWorktree, amendPath } : { runDir, reviewWorktree }))
  if (!v.startsWith('/'))
    throw new Error(`args.${k} must be an absolute path (got ${JSON.stringify(v)})`)
if (reviewer !== 'codex' && reviewer !== 'claude')
  throw new Error(`args.reviewer must be "codex" or "claude" (got ${JSON.stringify(reviewer)}) — the run skill resolves it before launch`)

// MODELS/EFFORTS are part of the ONE shared vocabulary kept in lockstep
// across six holders — scripts/lib.sh, work-loop.workflow.js,
// debug-loop.workflow.js, research.workflow.js, prototype.workflow.js, and
// this script: a value
// accepted by any validator but rejected by another bricks that verb's
// launches until the config file is hand-edited. Workflow scripts run
// sandboxed with no filesystem access, so they cannot read a shared vocab
// file — the literal copies are the design.
const MODELS = ['haiku', 'sonnet', 'opus', 'fable']
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max']
if (model !== undefined && !MODELS.includes(model))
  throw new Error(`args.model must be one of ${MODELS.join(', ')} (got ${JSON.stringify(model)})`)
if (effort !== undefined && !EFFORTS.includes(effort))
  throw new Error(`args.effort must be one of ${EFFORTS.join(', ')} (got ${JSON.stringify(effort)})`)

// Spread the overrides only when set: an override-free run's opts stay
// byte-identical run to run (same rationale as the loop scripts' tuned()).
const specOpts = (label, phaseTitle) => {
  const opts = { agentType: 'orca:spec', label, phase: phaseTitle }
  if (model) opts.model = model
  if (effort) opts.effort = effort
  return opts
}

const summary = await agent(prompt, specOpts('spec', 'Spec'))
if (summary === null || summary === undefined) return { summary: null, died: true }

// The reviewer's whole report — the same shape as the work loop's REVIEW:
// written=false is a retryable failure (the gate never sees it); the counts
// are the agent's count of the findings it wrote; reason is "" when written
// is true.
const REVIEW = { type: 'object', additionalProperties: false, required: ['written', 'total', 'criticalHigh', 'reason'],
  properties: {
    written: { type: 'boolean' },
    total: { type: 'integer', minimum: 0 },
    criticalHigh: { type: 'integer', minimum: 0 },
    reason: { type: 'string' } } }

const reviewAgentType = `orca:spec-review-${reviewer}`
// An amend round's review artifact gets its own name so it never clobbers
// the original run's spec review; across iteration rounds (and checkpoint
// re-spawns) the artifact is latest-wins, matching report.md's rewrite
// posture.
const artifact = `${runDir}/reviews/${amendPath ? `spec-amend-${reviewer}` : `spec-${reviewer}`}.json`

// The one review: two workflow-level attempts on top of the agent's
// internal retries; the returned counts never pass the impossible-count
// check unexamined (trusting {total: 0, criticalHigh: 2} would misgate the
// revise round). A review that cannot complete returns written:false with
// the last reason — the FAIL-OPEN branch, not an error: a dead reviewer
// must never brick a feature run, and every downstream gate still stands.
const review = async () => {
  let lastReason
  for (let attempt = 1; attempt <= 2; attempt++) {
    const r = await agent(
      [`Review worktree: ${reviewWorktree}`, `Run directory: ${runDir}`,
       ...(amendPath ? [`Amendment path: ${amendPath}`] : []),
       `Artifact path: ${artifact}`].join('\n'),
      { agentType: reviewAgentType, schema: REVIEW,
        label: `spec-review${attempt > 1 ? '~retry' : ''}`, phase: 'Review' })
    if (r === null || r === undefined) { lastReason = 'review agent was skipped or died'; continue }
    if (!r.written) { lastReason = r.reason || 'review agent reported written=false with no reason'; continue }
    if (r.criticalHigh > r.total) {
      lastReason = `review reported criticalHigh (${r.criticalHigh}) > total (${r.total}) — an impossible count`
      continue
    }
    return { written: true, total: r.total, criticalHigh: r.criticalHigh }
  }
  return { written: false, reason: lastReason }
}

const r1 = await review()
if (!r1.written) {
  log(`spec review failed open: ${r1.reason}`)
  return { summary, died: false,
    review: { written: false, total: 0, criticalHigh: 0, revised: false, reason: r1.reason } }
}
if (r1.criticalHigh === 0)
  return { summary, died: false,
    review: { written: true, total: r1.total, criticalHigh: 0, revised: false, reason: '' } }

// Critical/High findings: exactly one revise round — an orca:spec re-spawn
// carrying the original task message plus the revise contract (current spec
// and findings artifact by path; the agent reads both itself). Its output
// is final: no re-review — a second adversarial pass is blind to the first
// and churns on fresh or re-raised findings instead of converging, and the
// item reviews and integration verification still gate everything built
// over the spec. The revise prompt reuses the original prompt verbatim so
// the agent still holds the brief, the repo root, and the project context.
log(`spec review: ${r1.total} finding(s), ${r1.criticalHigh} Critical/High — revising`)
const reviseTarget = amendPath || `${runDir}/spec.md`
const revisePrompt = [
  prompt,
  '',
  '---',
  '',
  'REVISE ROUND — this spawn revises an existing spec; it is not a fresh authoring.',
  `The current spec is at ${reviseTarget} — read it first.`,
  `An independent adversarial review of that spec against the brief and the codebase found ${r1.criticalHigh} Critical/High finding(s). The findings artifact is at ${artifact} — read it.`,
  'Address or explicitly rebut each Critical/High finding, exactly as the checkpoint\'s requested changes are treated: a rebuttal is a `Risks & Open Questions` entry naming the finding and why it stands. Never silently drop one. Medium/Low findings are advisory — adopt what improves the spec.',
  'Your rewrite is final: it is not re-reviewed, and the run launches over it.',
  `Rewrite ${reviseTarget} in place under the same structure, then return the same 4-6 sentence summary, noting what the revision changed.`,
].join('\n')
const reviseSummary = await agent(revisePrompt, specOpts('spec-revise', 'Revise'))
if (reviseSummary === null || reviseSummary === undefined) {
  // A dead revise spawn leaves the findings standing: report them with
  // revised:false so the skill's surface-and-stop gate fires rather than
  // launching against a spec known to be wrong.
  log('spec revise agent was skipped or died — the findings stand')
  return { summary, died: false,
    review: { written: true, total: r1.total, criticalHigh: r1.criticalHigh, revised: false,
      reason: 'revise agent was skipped or died — the findings stand unaddressed' } }
}

return { summary: reviseSummary, died: false,
  review: { written: true, total: r1.total, criticalHigh: r1.criticalHigh, revised: true, reason: '' } }
