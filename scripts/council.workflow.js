// orca council — one question, every seat answering it independently and
// in parallel, for orca:council to merge in the invoking session.
//
// The skill resolves the roster through `orca.sh council resolve` and
// passes its lines through as args; this script decides nothing about
// who sits. Every seat gets the byte-identical member prompt below —
// the council's diversity is its models, never its instructions — and
// no seat sees another's answer. There is no merge stage here: merging
// is the session's job, on the returned results.
//
// args: {
//   prompt      the user's question, verbatim
//   root        absolute path of the checkout the seats explore (ROOT:)
//   members     [{ seat, name, kind, model }] — one per MEMBER: line;
//               kind 'claude' (model a Claude alias) or 'codex' (model a
//               Codex model id)
//   pluginRoot  absolute plugin root — required when a codex seat sits
//               (its courier shells out to orca.sh)
//   scratch     absolute SCRATCH: directory — required when a codex
//               seat sits; the courier stages its prompt and payload there
// }
//
// Return: { members: [{ seat, name, kind, model, status, result?,
//           artifact?, reason? }] } in roster order:
//   status 'ok'     — claude: `result` is the claims object; codex:
//                     `artifact` is the payload path, Codex's own bytes,
//                     for the session to Read (no agent transcribes it)
//   status 'died'   — the agent was skipped or died
//   status 'failed' — the codex courier reported no payload; `reason`
//                     names why (timeout, exec_failed, …)
// A seat that fails never fails the council: the session merges what
// landed and says who did not sit.
//
// No resume plumbing, deliberately: an interrupted council relaunches
// fresh — the runId is throwaway and never persisted.

export const meta = {
  name: 'orca-council',
  description: 'Put one question to every council seat in parallel — Claude seats directly, the Codex seat through its courier',
  phases: [{ title: 'Deliberate' }],
}

let parsedArgs = args
if (typeof parsedArgs === 'string') {
  try { parsedArgs = JSON.parse(parsedArgs) }
  catch { throw new Error('args arrived as a string that is not valid JSON — pass args as a real JSON object') }
}
if (typeof parsedArgs !== 'object' || parsedArgs === null)
  throw new Error(`args must be a JSON object (got ${JSON.stringify(args)}) — pass it as a real object, not a JSON-encoded string`)
const { prompt, root, members, pluginRoot, scratch } = parsedArgs

// MODELS is part of the ONE shared vocabulary kept in lockstep across the
// config validators (scripts/lib.sh's ORCA_MODELS; CI's lockstep-check.py
// holds this copy to it): the sandbox has no filesystem, so the literal
// copy is the design.
const MODELS = ['haiku', 'sonnet', 'opus', 'fable']

const isAbs = p => typeof p === 'string' && p.startsWith('/')
if (typeof prompt !== 'string' || !prompt.trim())
  throw new Error(`args.prompt must be a non-empty string (got ${JSON.stringify(prompt)})`)
if (!isAbs(root))
  throw new Error(`args.root must be an absolute path (got ${JSON.stringify(root)})`)
if (!Array.isArray(members) || members.length < 2 || members.length > 5)
  throw new Error(`args.members must be an array of 2 to 5 seats (got ${JSON.stringify(members)})`)
const seats = new Set()
for (const m of members) {
  if (typeof m !== 'object' || m === null || !Number.isInteger(m.seat) || m.seat < 1 || typeof m.name !== 'string')
    throw new Error(`each member needs an integer seat >= 1 and a name (got ${JSON.stringify(m)})`)
  if (seats.has(m.seat)) throw new Error(`seat ${m.seat} appears twice in args.members`)
  seats.add(m.seat)
  if (m.kind === 'claude') {
    if (!MODELS.includes(m.model))
      throw new Error(`seat ${m.seat}: a claude seat's model must be one of ${MODELS.join(', ')} (got ${JSON.stringify(m.model)})`)
  } else if (m.kind === 'codex') {
    if (typeof m.model !== 'string' || !/^[a-z0-9][a-z0-9._-]*$/.test(m.model))
      throw new Error(`seat ${m.seat}: a codex seat's model must be a model id like gpt-6-astra (got ${JSON.stringify(m.model)})`)
  } else {
    throw new Error(`seat ${m.seat}: kind must be "claude" or "codex" (got ${JSON.stringify(m.kind)})`)
  }
}
if (members.some(m => m.kind === 'codex')) {
  if (!isAbs(pluginRoot))
    throw new Error(`NO_PLUGIN_ROOT: args.pluginRoot must be an absolute path when a codex seat sits (got ${JSON.stringify(pluginRoot)})`)
  if (!isAbs(scratch))
    throw new Error(`args.scratch must be an absolute path when a codex seat sits (got ${JSON.stringify(scratch)})`)
}

// The claims shape — scripts/council-claims.schema.json, which Codex
// enforces for the astra seat. The sandbox cannot read that file, so this
// is a literal copy; keep the two identical.
const CLAIMS = { type: 'object', additionalProperties: false, required: ['summary', 'claims', 'open_questions'],
  properties: {
    summary: { type: 'string' },
    claims: { type: 'array', items: { type: 'object', additionalProperties: false,
      required: ['claim', 'evidence', 'confidence'],
      properties: {
        claim: { type: 'string' },
        evidence: { type: 'array', items: { type: 'string' } },
        confidence: { type: 'string', enum: ['high', 'medium', 'low'] } } } },
    open_questions: { type: 'array', items: { type: 'string' } } } }

const COURIER = { type: 'object', additionalProperties: false, required: ['written', 'status', 'reason'],
  properties: {
    written: { type: 'boolean' },
    status: { type: 'string' },
    reason: { type: 'string' } } }

// The one member prompt, identical for every seat and model.
const memberPrompt = [
  `Repository root: ${root}`,
  '',
  'You sit on a council: several independent agents, on different models, receive this same question. None sees the others\' answers, and the answers are merged claim by claim afterwards — so answer from your own reading of the repository, not from what an answer usually looks like.',
  '',
  'Read-only: read files, search, and run commands that change nothing (git log, git blame, git diff, read-only inspection). Modify nothing, anywhere.',
  '',
  'Every claim carries its evidence — a path:line anchor, or a command and what it showed. A claim you cannot anchor is still worth making, at confidence low. One assertion per claim, so each can be matched against the other members\' claims; never pad the list to look thorough.',
  '',
  'Question:',
  prompt,
  '',
  'Your answer is ONLY a JSON object — no prose around it, no code fences — in exactly this shape:',
  '{"summary": "your direct answer to the question, a few sentences",',
  ' "claims": [{"claim": "…", "evidence": ["path:line — what it shows"], "confidence": "high|medium|low"}],',
  ' "open_questions": ["what neither the question nor the code settles"]}',
].join('\n')

const seatOf = m => ({ seat: m.seat, name: m.name, kind: m.kind, model: m.model })
const label = m => `seat-${m.seat}:${m.name}`

const sitClaude = async m => {
  const r = await agent(memberPrompt,
    { agentType: 'orca:council', model: m.model, schema: CLAIMS, label: label(m), phase: 'Deliberate' })
  if (r === null || r === undefined) return { ...seatOf(m), status: 'died' }
  return { ...seatOf(m), status: 'ok', result: r }
}

const sitCodex = async m => {
  const base = `${scratch}/seat-${m.seat}`
  const artifact = `${base}.json`
  const r = await agent(
    [`Plugin root: ${pluginRoot}`, `Repository root: ${root}`, `Codex model: ${m.model}`,
     `Prompt path: ${base}.prompt.md`, `Artifact path: ${artifact}`,
     '', 'The prompt, verbatim — every line between the two marker lines, markers excluded:',
     '<<<ORCA-COUNCIL-PROMPT', memberPrompt, 'ORCA-COUNCIL-PROMPT>>>'].join('\n'),
    { agentType: 'orca:council-codex', schema: COURIER, label: label(m), phase: 'Deliberate' })
  if (r === null || r === undefined) return { ...seatOf(m), status: 'died' }
  if (!r.written) return { ...seatOf(m), status: 'failed', reason: r.reason || r.status || 'courier reported written=false with no reason' }
  return { ...seatOf(m), status: 'ok', artifact }
}

const results = await parallel(members.map(m => () => (m.kind === 'codex' ? sitCodex(m) : sitClaude(m))))
return {
  members: members.map((m, i) => results[i] || { ...seatOf(m), status: 'died' }),
}
