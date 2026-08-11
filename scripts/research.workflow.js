// orca research step — the one-agent workflow that spawns orca:research.
//
// The feature interview (and orca:followup's new-scope research) composes the
// complete task message (repository root, the idea verbatim, optional Project
// context line) and invokes this script through the Workflow tool. Routing
// the spawn through a workflow instead of the Agent tool is what makes
// research.effort an ordinary override: the Agent tool has a model parameter
// but no effort parameter, while agent() here takes both alongside agentType
// — so the research step gets the same {model, effort} tuning surface as
// every workflow-spawned stage.
//
// args: {
//   prompt   the complete task message for the orca:research agent, composed
//            by the skill exactly as the conversational spawn composed it.
//            This script never reads files — the workflow sandbox has no
//            filesystem access
//   model    optional model override (agents.research.model from the config)
//   effort   optional effort override (agents.research.effort from the config)
// }
//
// Return: { report: <the agent's final text>, died: false } — or
//         { report: null, died: true } when the agent was skipped or died
//         on a terminal API error: a typed failure the interviewer branches
//         on (research failure is non-fatal — the interview falls back to
//         intent-only), never a shapeless null. No schema on the agent call:
//         the research agent's contract is prose — its final message IS the
//         report, deliberately never persisted.
//
// No resume plumbing, deliberately: this is one agent call — cheap to redo.
// An interrupted research step relaunches fresh; the runId is throwaway and
// is never persisted anywhere.

export const meta = {
  name: 'orca-research',
  description: "Research the idea against the codebase for the interview — one orca:research agent",
  phases: [{ title: 'Research' }],
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
const { prompt, model, effort } = parsedArgs
if (typeof prompt !== 'string' || !prompt)
  throw new Error(`args.prompt must be a non-empty string (got ${JSON.stringify(prompt)})`)

// MODELS/EFFORTS are part of the ONE shared vocabulary kept in lockstep
// across six holders — scripts/lib.sh, work-loop.workflow.js,
// debug-loop.workflow.js, spec.workflow.js, prototype.workflow.js, and
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

// Spread the overrides only when set: an override-free spawn's opts stay
// byte-identical run to run (same rationale as the loop scripts' tuned()).
const opts = { agentType: 'orca:research', label: 'research', phase: 'Research' }
if (model) opts.model = model
if (effort) opts.effort = effort

const report = await agent(prompt, opts)
if (report === null || report === undefined) return { report: null, died: true }
return { report, died: false }
