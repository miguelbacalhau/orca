// The verb hook: answers the work loop's orca.sh verb calls without a model.
//
// The work loop (scripts/work-loop.workflow.js) asks for a verb with
// `agent('', { model: 'orca:{"v":1,"verb":…,"args":[…]}' })`. That request
// reaches `turn.step` before any API call; this hook answers it itself by
// running `bash <this plugin>/scripts/orca.sh <verb> <args…>` and returning
// the result as the agent's text. It never calls `next` for an `orca:` model:
// that would send the request (and the arguments in its model name) to the API.
//
// What it will run, and when:
//   - only an `orca:` request from a subagent (a workflow agent), protocol
//     version 1, whose verb (and subcommand) is one the work loop calls;
//   - only while the session's permission mode is known to be
//     bypassPermissions. The mode is read off the classic hook events that
//     carry it and kept in $.state; no mode seen yet means refuse.
//   - always through bash + orca.sh, never git directly: `$.process.run` runs
//     git with repo hooks off, a script that bash starts does not.
//
// The answer is `b64:` + base64(UTF-8 JSON): `{ v, rc, stdout, stderr }`, or
// `{ v, refused }` when a guard says no, or `{ v, error, timedOut? }` when the
// command could not be run to completion. Encoded whole because the harness
// rewrites subagent results that look instruction-shaped (a verb's output
// naming the session's flags, say); base64 passes untouched.
//
// This hook is the work loop's only way to orca.sh: there is no fallback.
// Where it is not loaded, an `orca:` request goes to the API, which has no
// such model, and the work loop fails loudly at that call (its first is
// `triage claim`), naming the cause.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

export const RELAY_VERSION = 1
export const MODEL_PREFIX = 'orca:'
// The longest `$.process.run` allows. setup's own cap (540 s, verbs/setup.sh)
// sits under it, so a slow worktree setup ends in setup's own soft timeout;
// a verb that still runs past ten minutes fails here, as a timeout naming it.
export const RUN_TIMEOUT_MS = 600_000

// Exactly the verbs work-loop.workflow.js calls through orca(), with the
// subcommands it uses where a verb has several; null means any arguments.
export const ALLOWED: Readonly<Record<string, readonly string[] | null>> = {
  'self-test': null,
  'triage': ['claim', 'release'],
  'spec': ['mark', 'changed'],
  'secrets': ['place', 'remove'],
  'archive': ['attempt'],
  'notes': ['write'],
  'worktree-item': null,
  'provision': null,
  'commit-verify': null,
  'merge-prepare': null,
  'merge-finalize': null,
  'commit-prepare': null,
  'salvage': null,
}

export type RelayRequest = { v: number; verb: string; args: string[] }
export type RelayAnswer =
  | { v: number; rc: number; stdout: string; stderr: string }
  | { v: number; refused: string }
  | { v: number; error: string; timedOut?: true }

const modeAtom = atom({ plugin: 'orca', key: 'permissionMode' } as const, null)

// Parses and checks the request the model name carries. A string answer is
// the refusal reason.
export function parseRequest(model: string): RelayRequest | string {
  if (!model.startsWith(MODEL_PREFIX)) return 'not an orca: request'
  let req: unknown
  try { req = JSON.parse(model.slice(MODEL_PREFIX.length)) } catch { return 'request is not JSON' }
  if (typeof req !== 'object' || req === null || Array.isArray(req)) return 'request is not an object'
  const { v, verb, args } = req as Record<string, unknown>
  if (v !== RELAY_VERSION) return `unknown protocol version ${JSON.stringify(v)} (this hook speaks ${RELAY_VERSION})`
  if (typeof verb !== 'string' || !Object.prototype.hasOwnProperty.call(ALLOWED, verb))
    return `verb ${JSON.stringify(verb)} is not on the work loop's allow-list`
  if (!Array.isArray(args) || args.some(a => typeof a !== 'string')) return 'args must be an array of strings'
  const subcommands = ALLOWED[verb]
  if (subcommands && !subcommands.includes(args[0] as string))
    return `${verb} ${JSON.stringify(args[0] ?? null)} is not on the work loop's allow-list (${subcommands.join(', ')})`
  return { v, verb, args: args as string[] }
}

export function argvFor(root: string, req: RelayRequest): string[] {
  return ['bash', `${root.replace(/\/+$/, '')}/scripts/orca.sh`, req.verb, ...req.args]
}

export function encodeAnswer(answer: RelayAnswer): string {
  const bytes = new TextEncoder().encode(JSON.stringify(answer))
  let bin = ''
  for (let i = 0; i < bytes.length; i += 0x8000)
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return `b64:${btoa(bin)}`
}

// Main-thread events set the mode either way. An event from inside a
// subagent may only close the gate: a subagent's own mode is not the
// session's, and must never be what opens it.
export function nextMode(current: string | null, seen: unknown, fromSubagent: boolean): string | null {
  if (typeof seen !== 'string' || !seen) return current
  if (!fromSubagent) return seen
  return seen === 'bypassPermissions' ? current : seen
}

async function noteMode($: EngineInterface, e: { permission_mode?: string; agent_id?: string }) {
  const current = await read($, modeAtom)
  const mode = nextMode(current, e.permission_mode, e.agent_id !== undefined)
  if (mode !== current) await update($, modeAtom, () => mode)
}

// A rejected $.process.run: the command could not start, or was still
// running at the cap and was killed. The two are told apart by the time it
// took, or by the message (2.1.291 rejects a timeout with "<plugin>:
// $.process.run(<argv0>) aborted: still running after <ms>ms"), so the work
// loop can name a timeout.
export function runFailure(verb: string, message: string, elapsedMs: number): RelayAnswer {
  if (elapsedMs >= RUN_TIMEOUT_MS - 1000 || /still running after|timed? ?out/i.test(message))
    return { v: RELAY_VERSION, error: `orca.sh ${verb} was still running after ${RUN_TIMEOUT_MS / 60_000} minutes, the longest $.process.run allows, and was stopped: ${message}`, timedOut: true }
  return { v: RELAY_VERSION, error: `orca.sh ${verb} did not run to completion: ${message}` }
}

async function answer($: EngineInterface, model: string, agentId: string | undefined): Promise<RelayAnswer> {
  if (!agentId) return { v: RELAY_VERSION, refused: 'orca: requests are answered for workflow agents only' }
  const req = parseRequest(model)
  if (typeof req === 'string') return { v: RELAY_VERSION, refused: req }
  const mode = await read($, modeAtom)
  if (mode !== 'bypassPermissions')
    return { v: RELAY_VERSION, refused: mode === null
      ? 'permission mode not known yet (none seen since this session or hook loaded); orca runs verbs here only in bypassPermissions sessions'
      : `permission mode is ${mode}; orca runs verbs here only in bypassPermissions sessions` }
  let run
  const started = Date.now()
  try { run = await $.process.run(argvFor($.plugin.root, req), { timeoutMs: RUN_TIMEOUT_MS }) }
  catch (err) { return runFailure(req.verb, String((err as Error)?.message ?? err), Date.now() - started) }
  if (run.isStdoutTruncated) return { v: RELAY_VERSION, error: `orca.sh ${req.verb} wrote more than 4 MiB to stdout` }
  return { v: RELAY_VERSION, rc: run.exitCode, stdout: run.stdout, stderr: run.stderr }
}

export const register: Register = on => {
  // The events Phase 3 saw carry permission_mode (2.1.290/291); SubagentStart
  // and SessionStart do not.
  on('classic.UserPromptSubmit', async ($, e, next) => {
    try { await noteMode($, e) } catch { /* the gate stays as it was */ }
    return next(e)
  }).catch(($, e, next) => next(e))
  on('classic.PostToolUse', async ($, e, next) => {
    try { await noteMode($, e) } catch { /* the gate stays as it was */ }
    return next(e)
  }).catch(($, e, next) => next(e))
  on('classic.SubagentStop', async ($, e, next) => {
    try { await noteMode($, e) } catch { /* the gate stays as it was */ }
    return next(e)
  }).catch(($, e, next) => next(e))
  on('classic.Stop', async ($, e, next) => {
    try { await noteMode($, e) } catch { /* the gate stays as it was */ }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.step', async function* ($, e, next) {
    if (!e.model.startsWith(MODEL_PREFIX)) return yield* next(e)
    let reply: RelayAnswer
    try { reply = await answer($, e.model, e.agentId) }
    catch (err) { reply = { v: RELAY_VERSION, error: `orca hook failed: ${String((err as Error)?.message ?? err)}` } }
    const text = encodeAnswer(reply)
    yield { kind: 'text', index: 0, text }
    yield { kind: 'stop', stopReason: 'end_turn', usage: null }
    return { turnId: e.turnId, index: e.index, answer: text, toolUses: [], stopReason: 'end_turn', usage: null }
  }).catch(async function* ($, e, next) {
    // An orca: request never goes to the API, even when this hook failed.
    if (next.called || !e.model.startsWith(MODEL_PREFIX)) return yield* next(e)
    const text = encodeAnswer({ v: RELAY_VERSION, error: `orca hook failed: ${next.error.message ?? next.error.kind}` })
    yield { kind: 'text', index: 0, text }
    yield { kind: 'stop', stopReason: 'end_turn', usage: null }
    return { turnId: e.turnId, index: e.index, answer: text, toolUses: [], stopReason: 'end_turn', usage: null }
  })
}
