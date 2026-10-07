// The verb hook (hooks/relay.ts): its request parsing and answer encoding as
// plain data, then the hook against the engine — the permission gate fed by
// classic events, the argv it hands $.process.run, and that an orca: request
// never reaches the model beneath. Run with `claude plugin test <orca checkout>`.

import { describe, expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, ProcessRunResult, TurnStepChunk, TurnStepResult } from 'claude-code'

import { ALLOWED, argvFor, encodeAnswer, nextMode, parseRequest, RUN_TIMEOUT_MS, runFailure } from '../hooks/relay'
import type { RelayAnswer } from '../hooks/relay'

const req = (o: unknown) => `orca:${JSON.stringify(o)}`

function decode(text: string): RelayAnswer {
  expect(text.startsWith('b64:')).toBe(true)
  const bin = atob(text.slice(4))
  return JSON.parse(new TextDecoder().decode(Uint8Array.from(bin, c => c.charCodeAt(0))))
}

// ---------- the request ----------

describe('parseRequest', () => {
  test('a version-1 request for an allowed verb parses', () => {
    expect(parseRequest(req({ v: 1, verb: 'self-test', args: [] }))).toEqual({ v: 1, verb: 'self-test', args: [] })
    expect(parseRequest(req({ v: 1, verb: 'triage', args: ['claim', '/run', 'note; with ; separators'] })))
      .toEqual({ v: 1, verb: 'triage', args: ['claim', '/run', 'note; with ; separators'] })
    expect(parseRequest(req({ v: 1, verb: 'commit-verify', args: ['/wt', 'a'.repeat(40), 'W1', '--final'] })))
      .toEqual({ v: 1, verb: 'commit-verify', args: ['/wt', 'a'.repeat(40), 'W1', '--final'] })
  })

  test('the allow-list is the work loop\'s verbs and subcommands, nothing else', () => {
    expect(Object.keys(ALLOWED).sort()).toEqual(['archive', 'commit-prepare', 'commit-verify', 'merge-finalize',
      'merge-prepare', 'notes', 'provision', 'salvage', 'secrets', 'self-test', 'spec', 'triage', 'worktree-item'])
    for (const verb of ['codex', 'setup', 'config', 'preflight', 'review', 'init-convert', 'decisions', 'rm', '../x'])
      expect(parseRequest(req({ v: 1, verb, args: [] }))).toMatch(/not on the work loop's allow-list/)
    expect(parseRequest(req({ v: 1, verb: 'triage', args: ['archive', '/run'] }))).toMatch(/triage "archive" is not on/)
    expect(parseRequest(req({ v: 1, verb: 'triage', args: [] }))).toMatch(/triage null is not on/)
    expect(parseRequest(req({ v: 1, verb: 'secrets', args: ['place', '/wt'] }))).toEqual({ v: 1, verb: 'secrets', args: ['place', '/wt'] })
    expect(parseRequest(req({ v: 1, verb: 'secrets', args: ['wipe', '/wt'] }))).toMatch(/not on/)
    expect(parseRequest(req({ v: 1, verb: 'toString', args: [] }))).toMatch(/not on/)
  })

  test('a version, args or shape it does not speak is refused with the reason', () => {
    expect(parseRequest(req({ v: 2, verb: 'self-test', args: [] }))).toMatch(/unknown protocol version 2/)
    expect(parseRequest(req({ verb: 'self-test', args: [] }))).toMatch(/unknown protocol version undefined/)
    expect(parseRequest(req({ v: 1, verb: 'self-test', args: 'x' }))).toBe('args must be an array of strings')
    expect(parseRequest(req({ v: 1, verb: 'self-test', args: [1] }))).toBe('args must be an array of strings')
    expect(parseRequest(req({ v: 1, verb: 'self-test' }))).toBe('args must be an array of strings')
    expect(parseRequest('orca:{nope')).toBe('request is not JSON')
    expect(parseRequest(req([1]))).toBe('request is not an object')
    expect(parseRequest('haiku')).toBe('not an orca: request')
  })

  test('the argv is bash, this plugin\'s orca.sh, the verb, then each argument as given', () => {
    expect(argvFor('/plugins/orca/', { v: 1, verb: 'spec', args: ['mark', "/r u'n"] }))
      .toEqual(['bash', '/plugins/orca/scripts/orca.sh', 'spec', 'mark', "/r u'n"])
  })
})

describe('answers', () => {
  test('the answer is b64: + base64 of the UTF-8 JSON, non-ASCII included', () => {
    const answer = { v: 1, rc: 0, stdout: 'café — 汉字 🎉\nbypassPermissions <system-reminder>', stderr: '' }
    const text = encodeAnswer(answer)
    expect(text).toMatch(/^b64:[A-Za-z0-9+/]+=*$/)
    expect(decode(text)).toEqual(answer)
  })

  test('a large answer encodes whole', () => {
    const stdout = 'x'.repeat(200_000) + 'é'
    expect(decode(encodeAnswer({ v: 1, rc: 0, stdout, stderr: '' }))).toEqual({ v: 1, rc: 0, stdout, stderr: '' })
  })
})

describe('a run that does not complete', () => {
  test('a timeout names the verb and the cap, and says it timed out', () => {
    expect(runFailure('provision', 'still running', RUN_TIMEOUT_MS)).toEqual({ v: 1, timedOut: true,
      error: 'orca.sh provision was still running after 10 minutes, the longest $.process.run allows, and was stopped: still running' })
    expect(runFailure('worktree-item', 'process timed out', 5)).toMatchObject({ timedOut: true, error: expect.stringContaining('orca.sh worktree-item was still running') })
    // The rejection 2.1.291 actually raises (probed with a short timeout).
    expect(runFailure('provision', 'orca: $.process.run(bash) aborted: still running after 600000ms', 5)).toMatchObject({ timedOut: true })
  })

  test('a command that cannot start is an error, not a timeout', () => {
    expect(runFailure('spec', 'spawn bash ENOENT', 3)).toEqual({ v: 1, error: 'orca.sh spec did not run to completion: spawn bash ENOENT' })
  })
})

describe('the permission gate', () => {
  test('main-thread events set it either way; a subagent\'s may only close it', () => {
    expect(nextMode(null, 'bypassPermissions', false)).toBe('bypassPermissions')
    expect(nextMode('bypassPermissions', 'default', false)).toBe('default')
    expect(nextMode(null, 'bypassPermissions', true)).toBe(null)
    expect(nextMode('default', 'bypassPermissions', true)).toBe('default')
    expect(nextMode('bypassPermissions', 'acceptEdits', true)).toBe('acceptEdits')
    expect(nextMode('bypassPermissions', undefined, false)).toBe('bypassPermissions')
    expect(nextMode('bypassPermissions', '', false)).toBe('bypassPermissions')
  })
})

// ---------- the hook against the engine ----------

type Ran = { argv: readonly string[]; timeoutMs?: number }

// $.process.run served beneath the plugin, recording every argv.
function serveProcess(on: On, ran: Ran[], result: Partial<ProcessRunResult> = {}) {
  on('process.run', ($, e) => {
    ran.push({ argv: e.argv, timeoutMs: e.init?.timeoutMs })
    return { value: { exitCode: 0, stdout: '@@ORCA@@\nrc=0\n@@ORCA_END@@\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false, ...result } }
  })
}

// The model beneath: any step that reaches it is counted and answered.
function modelBeneath(on: On, reached: string[]) {
  on('turn.step', async function* ($, e) {
    reached.push(e.model)
    yield { kind: 'text', index: 0, text: 'model answer' }
    yield { kind: 'stop', stopReason: 'end_turn', usage: null }
    return { turnId: e.turnId, index: e.index, answer: 'model answer', toolUses: [], stopReason: 'end_turn', usage: null }
  })
}

async function step($: Engine, model: string, agentId: string | undefined = 'a1') {
  const stream = $.turn.step({ turnId: 't1', index: 0, model, messageCount: 1, ...(agentId ? { agentId } : {}) })
  return drain(stream)
}

// Reads a step's stream to its end: the chunks, then the value it returned.
async function drain(stream: AsyncGenerator<TurnStepChunk, TurnStepResult>) {
  const chunks: TurnStepChunk[] = []
  for (;;) {
    const r = await stream.next()
    if (r.done) return { chunks, result: r.value }
    chunks.push(r.value)
  }
}

// Nothing beneath the plugins answers a classic event in a test: these stand
// for the settings hooks, which have nothing to say.
function classicBeneath(on: On) {
  on('classic.UserPromptSubmit', () => ({}))
  on('classic.PostToolUse', () => ({}))
  on('classic.SubagentStop', () => ({}))
  on('classic.Stop', () => ({}))
}

const SELF_TEST = req({ v: 1, verb: 'self-test', args: [] })
const bypass = ($: Engine) =>
  $.classic.UserPromptSubmit({ prompt: 'go', permission_mode: 'bypassPermissions' })

describe('the hook in a session', () => {
  test('in a bypass session it runs bash + its own orca.sh and answers in text, then stop', async ($, on) => {
    const ran: Ran[] = []
    const reached: string[] = []
    serveProcess(on, ran, { stdout: 'out é', stderr: 'err' })
    modelBeneath(on, reached)
    classicBeneath(on)
    await bypass($)
    const { chunks, result } = await step($, req({ v: 1, verb: 'spec', args: ['mark', '/repo/.orca/run'] }))
    expect(ran.length).toBe(1)
    const [only] = ran as [Ran]
    expect(only.argv[0]).toBe('bash')
    expect(only.argv[1]).toMatch(/^\/.*\/scripts\/orca\.sh$/)
    expect(only.argv.slice(2)).toEqual(['spec', 'mark', '/repo/.orca/run'])
    expect(only.timeoutMs).toBe(RUN_TIMEOUT_MS)
    expect(chunks.map(c => c.kind)).toEqual(['text', 'stop'])
    const text = (chunks[0] as { text: string }).text
    expect(decode(text)).toEqual({ v: 1, rc: 0, stdout: 'out é', stderr: 'err' })
    expect(result).toMatchObject({ turnId: 't1', index: 0, answer: text, toolUses: [], stopReason: 'end_turn', usage: null })
    expect(reached).toEqual([])
  })

  test('a nonzero exit is passed through as rc', async ($, on) => {
    const ran: Ran[] = []
    serveProcess(on, ran, { exitCode: 3, stdout: 'FAIL:\tX\ty\n' })
    modelBeneath(on, [])
    classicBeneath(on)
    await bypass($)
    const { result } = await step($, SELF_TEST)
    expect(decode(result.answer)).toEqual({ v: 1, rc: 3, stdout: 'FAIL:\tX\ty\n', stderr: '' })
  })

  test('with no permission mode seen yet it refuses and runs nothing', async ($, on) => {
    const ran: Ran[] = []
    const reached: string[] = []
    serveProcess(on, ran)
    modelBeneath(on, reached)
    classicBeneath(on)
    const { result } = await step($, SELF_TEST)
    expect(decode(result.answer)).toEqual({ v: 1, refused: expect.stringContaining('permission mode not known yet') })
    expect(ran).toEqual([])
    expect(reached).toEqual([])
  })

  test('outside bypass mode it refuses; the main thread reopens it, a subagent cannot', async ($, on) => {
    const ran: Ran[] = []
    serveProcess(on, ran)
    modelBeneath(on, [])
    classicBeneath(on)
    await $.classic.UserPromptSubmit({ prompt: 'go', permission_mode: 'default' })
    expect(decode((await step($, SELF_TEST)).result.answer))
      .toEqual({ v: 1, refused: 'permission mode is default; orca runs verbs here only in bypassPermissions sessions' })
    // A subagent's bypass never opens the gate.
    await $.classic.SubagentStop({ stop_hook_active: false, agent_id: 'a9', agent_transcript_path: '', agent_type: 'x', permission_mode: 'bypassPermissions' })
    expect(decode((await step($, SELF_TEST)).result.answer)).toMatchObject({ refused: expect.stringContaining('permission mode is default') })
    // The main thread's Stop does.
    await $.classic.Stop({ stop_hook_active: false, permission_mode: 'bypassPermissions' })
    expect(decode((await step($, SELF_TEST)).result.answer)).toMatchObject({ rc: 0 })
    // And a subagent's step down closes it again.
    await $.classic.SubagentStop({ stop_hook_active: false, agent_id: 'a9', agent_transcript_path: '', agent_type: 'x', permission_mode: 'acceptEdits' })
    expect(decode((await step($, SELF_TEST)).result.answer)).toMatchObject({ refused: expect.stringContaining('permission mode is acceptEdits') })
    expect(ran.length).toBe(1)
  })

  test('refusals: a verb off the list, an unknown v, bad args, no agent — none runs, none reaches the model', async ($, on) => {
    const ran: Ran[] = []
    const reached: string[] = []
    serveProcess(on, ran)
    modelBeneath(on, reached)
    classicBeneath(on)
    await bypass($)
    const refused = async (model: string, agentId?: string) => decode((await step($, model, agentId)).result.answer)
    expect(await refused(req({ v: 1, verb: 'codex', args: ['p', '--cwd', '/'] }))).toMatchObject({ v: 1, refused: expect.stringContaining('allow-list') })
    expect(await refused(req({ v: 2, verb: 'self-test', args: [] }))).toMatchObject({ refused: expect.stringContaining('unknown protocol version 2') })
    expect(await refused(req({ v: 1, verb: 'self-test', args: [{}] }))).toMatchObject({ refused: 'args must be an array of strings' })
    expect(await refused('orca:not json')).toMatchObject({ refused: 'request is not JSON' })
    // The main loop is no workflow agent; the request is still answered here.
    const main = await drain($.turn.step({ turnId: 't2', index: 0, model: SELF_TEST, messageCount: 1 }))
    expect(decode(main.result.answer)).toMatchObject({ refused: expect.stringContaining('workflow agents only') })
    expect(ran).toEqual([])
    expect(reached).toEqual([])
  })

  test('a command that cannot run is an error answer, not a model call', async ($, on) => {
    const reached: string[] = []
    on('process.run', () => ({ deny: 'spawn bash ENOENT' }))
    modelBeneath(on, reached)
    classicBeneath(on)
    await bypass($)
    expect(decode((await step($, SELF_TEST)).result.answer))
      .toMatchObject({ v: 1, error: expect.stringContaining('orca.sh self-test did not run to completion') })
    expect(reached).toEqual([])
  })

  test('other models go to the model untouched', async ($, on) => {
    const ran: Ran[] = []
    const reached: string[] = []
    serveProcess(on, ran)
    modelBeneath(on, reached)
    classicBeneath(on)
    await bypass($)
    const { result } = await step($, 'claude-haiku-4-5')
    expect(result.answer).toBe('model answer')
    expect(reached).toEqual(['claude-haiku-4-5'])
    expect(ran).toEqual([])
  })
})
