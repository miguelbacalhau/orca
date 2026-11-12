// The objective band (hooks/objective-band.tsx, hooks/derive-objective.ts):
// the derivation over objective files as plain data, then the hooks module
// end to end against the engine, with the repository's .orca/objectives
// served from memory. Run with `claude plugin test <orca checkout>`.

import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import { actionTail, deriveObjective, landedIn, openFollowups, parseEntries } from '../hooks/derive-objective'
import type { ObjectiveFiles } from '../hooks/derive-objective'
import type { OrcaObjective } from '../types'

const SESSION = 'sess-A'
const ROOT = '/repo/.orca/objectives'
const DIR = `${ROOT}/20261103-101500-rate-limit-public-api`
const OWNER = `session=${SESSION}\nhost=h\npid=1\npidstart=x\ntaken=2026-11-03T10:15:00+0000\n`

const OBJECTIVE: OrcaObjective = { dir: DIR, slug: 'rate-limit-public-api', repoRoot: '/repo', idlePrompts: 0 }

type Decision = [id: string, title: string, state: string, source?: string]
type Phase = [id: string, title: string, state: string, extra?: string]

function decisions(...ds: Decision[]): string {
  return '# Decisions\n\n' + ds.map(([id, title, state, source = 'discussion']) =>
    `## ${id} — ${title}\n**State:** ${state}\n**Source:** ${source}\n**Options:** a · b\n`).join('\n')
}

function phases(...ps: Phase[]): string {
  return '# Phases\n\n' + ps.map(([id, title, state, extra = '']) =>
    `## ${id} — ${title}\n**State:** ${state}\n**Source:** plan\n**Decisions:** D1\n**Goal:** a goal\n` +
    `**Acceptance:**\n- a line\n${extra}`).join('\n')
}

function report(...followups: string[]): string {
  return reportVerified(null, ...followups)
}

// A report whose `**Final verification:**` line names <after>, or none.
function reportVerified(after: string | null, ...followups: string[]): string {
  const line = after ? `**Final verification:** pass after ${after} (abc1234)\n` : ''
  return `# Report: x\n\n**Deliverable:** \`feature/x\`\n**Deliverable state:** verified\n${line}\n## Phases\n\n### P1 — a — abc\n\n## Blocked\n\nNone\n\n` +
    `## Follow-ups\n\n${followups.map(f => `- ${f} · P1 · gap · a title — why`).join('\n')}\n\n## Landing\n`
}

function frame(action: string, round: number, gating = 0): string {
  return `@@ORCA@@\nrc=0\naction=${action}\nround=${round}\ngating=${gating}\nminor=0\nout_of_scope=0\n@@ORCA_END@@\n`
}

function files(over: Partial<ObjectiveFiles> = {}): ObjectiveFiles {
  return {
    dirExists: true, owner: OWNER, archived: false, decisions: null, phases: null,
    phasesMtimeMs: 100, plan: [], report: null, action: null, ...over,
  }
}

const derive = (f: ObjectiveFiles) => deriveObjective(OBJECTIVE, f, SESSION)
const header = (f: ObjectiveFiles) => { const b = derive(f).band; return b ? [b.phase, b.detail] : null }
const rowsOf = (f: ObjectiveFiles) =>
  Object.fromEntries((derive(f).band?.rows ?? []).map(r => [r.id, `${r.mark} ${r.status}`]))

// ---------- derivation ----------

describe('header by derived state', () => {
  test('discussing: decision counts, and the open and deferred decisions as rows', () => {
    const f = files({ decisions: decisions(
      ['D1', 'Token bucket or sliding window?', 'decided'],
      ['D2', 'Per-key or per-IP limits?', 'open'],
      ['D3', 'Admin bypass?', 'deferred'],
      ['D4', 'Where do 429 bodies come from?', 'open'],
    ) })
    const out = derive(f)
    expect(out).toMatchObject({ finished: false, state: 'discussing' })
    expect(out.band).toMatchObject({ slug: 'rate-limit-public-api', phase: 'discussing', detail: '1 decided · 2 open', source: 'objective' })
    expect(out.band?.rows.map(r => [r.id, r.title, `${r.mark} ${r.status}`, r.tone])).toEqual([
      ['D2', 'Per-key or per-IP limits?', '○ open', 'live'],
      ['D3', 'Admin bypass?', '◌ deferred', 'cut'],
      ['D4', 'Where do 429 bodies come from?', '○ open', 'live'],
    ])
  })

  test('no phases yet is discussing, even with every decision taken', () => {
    expect(header(files({ decisions: decisions(['D1', 'q', 'decided']) }))).toEqual(['discussing', '1 decided · 0 open'])
  })

  test('a proposal is under review until a plan review lands after phases.md last changed', () => {
    const decided = decisions(['D1', 'q', 'decided'])
    const proposed = { name: 'proposed.md', mtimeMs: 200 }
    expect(header(files({ decisions: decided, plan: [proposed] }))).toEqual(['reviewing plan', ''])
    expect(header(files({ decisions: decided, plan: [proposed, { name: 'review-1.json', mtimeMs: 300 }] })))
      .toEqual(['planning', ''])
    // A replanning pass: the last pass's review predates the install of phases.md.
    expect(header(files({ decisions: decided, phasesMtimeMs: 500, phases: phases(['P1', 'a', 'done']),
      plan: [{ name: 'proposed.md', mtimeMs: 600 }, { name: 'review-1.json', mtimeMs: 300 }] }))).toEqual(['reviewing plan', ''])
    // An open decision outranks a proposal.
    expect(header(files({ decisions: decisions(['D1', 'q', 'open']), plan: [proposed] }))?.[0]).toBe('discussing')
  })

  test('active: the phase of the total, one row per phase, open follow-ups counted', () => {
    const f = files({
      decisions: decisions(['D1', 'q', 'decided'], ['D2', 'from a follow-up', 'decided', 'F3']),
      phases: phases(
        ['P1', 'Token bucket + store', 'done', '**Commit:** a1b2c3d4e5f6\n'],
        ['P2', 'Middleware on public routes', 'active'],
        ['P3', '429 responses + headers', 'pending'],
        ['P4', 'Docs', 'pending'],
      ),
      report: report('F1', 'F2', 'F3'),
      action: frame('review', 2),
    })
    expect(derive(f).band).toMatchObject({ phase: 'P2/4', detail: '2 follow-ups' })
    expect(rowsOf(f)).toEqual({ P1: '✓ done a1b2c3d', P2: '● review r2', P3: '◌ pending', P4: '◌ pending' })
    expect(derive(f).band?.rows.map(r => r.tone)).toEqual(['done', 'live', 'queued', 'queued'])
  })

  test('blocked names the decision it waits on', () => {
    const f = files({
      decisions: decisions(['D1', 'q', 'decided'], ['D7', 'later', 'open', 'P2 round 3 (disputed finding)']),
      phases: phases(['P1', 'a', 'done', '**Commit:** abc\n'], ['P2', 'b', 'blocked', '**Blocked on:** D7\n'], ['P3', 'c', 'pending']),
    })
    expect(header(f)).toEqual(['blocked on D7', ''])
    expect(rowsOf(f)).toEqual({ P1: '✓ done abc', P2: '✕ blocked on D7', P3: '◌ pending' })
  })

  test('ready counts the pending phases; verify and idle the done ones', () => {
    const decided = decisions(['D1', 'q', 'decided'])
    const two = phases(['P1', 'a', 'done'], ['P2', 'b', 'done'])
    expect(header(files({ decisions: decided, phases: phases(['P1', 'a', 'done'], ['P2', 'b', 'pending'], ['P3', 'c', 'pending']) })))
      .toEqual(['ready', '2 pending'])
    expect(header(files({ decisions: decided, phases: two, report: reportVerified('P2', 'F1') })))
      .toEqual(['idle', '2 phases done · 1 follow-up'])
    expect(header(files({ decisions: decided, phases: phases(['P1', 'a', 'done']), report: reportVerified('P1') })))
      .toEqual(['idle', '1 phase done'])
    // No final verification, or one a later phase made stale: verify.
    expect(header(files({ decisions: decided, phases: two, report: report('F1') })))
      .toEqual(['verify', '2 phases done · 1 follow-up'])
    expect(header(files({ decisions: decided, phases: two, report: reportVerified('P1') }))).toEqual(['verify', '2 phases done'])
    expect(header(files({ decisions: decided, phases: two }))).toEqual(['verify', '2 phases done'])
    // A recorded fail ends the verify state too.
    const failed = reportVerified('P2').replace('pass after P2 (abc1234)', 'fail after P2 (abc1234) — make test red')
    expect(header(files({ decisions: decided, phases: two, report: failed }))).toEqual(['idle', '2 phases done'])
  })
})

describe('the active phase\'s tail', () => {
  test('each round-engine action', () => {
    expect(actionTail(frame('implement', 0))).toBe('implement')
    expect(actionTail(frame('review', 1))).toBe('review r1')
    expect(actionTail(frame('fix', 2, 3))).toBe('fix r2 (3 gating)')
    expect(actionTail(frame('fix-minor', 3))).toBe('fix minor')
    expect(actionTail(frame('fix-checks', 1))).toBe('fix checks')
    expect(actionTail(frame('ask-disputes', 2))).toBe('waiting on you: dispute r2')
    expect(actionTail(frame('stalled', 3))).toBe('waiting on you: stall r3')
    expect(actionTail(frame('ask-questions', 0))).toBe('waiting on you: questions')
    expect(actionTail(frame('infeasible', 0))).toBe('waiting on you: infeasible')
    expect(actionTail(frame('drifted', 2))).toBe('revalidate r2')
    expect(actionTail(frame('commit', 2))).toBe('committing')
  })

  test('a missing, torn, failed or unknown frame only says active', () => {
    expect(actionTail(null)).toBe('active')
    expect(actionTail('@@ORCA@@\nrc=0\naction=rev')).toBe('active')
    expect(actionTail('@@ORCA@@\nrc=1\naction=review\nround=1\n@@ORCA_END@@\n')).toBe('active')
    expect(actionTail(frame('dance', 1))).toBe('active')
    expect(actionTail('not a frame at all')).toBe('active')
  })
})

describe('malformed or missing files', () => {
  test('missing decisions and phases read as none', () => {
    expect(derive(files()).band).toMatchObject({ phase: 'discussing', detail: '0 decided · 0 open', rows: [] })
  })

  test('only headings and Key lines count: prose, odd headings and repeated keys are ignored', () => {
    const text = '# Phases\n\nSome prose **State:** active\n## P1 — First\n**State:** done, really\n**State:** active\n' +
      'prose\n## Notes\n**State:** active\n## P2 without a dash\n**State:** active\n## P3 — \n**Commit:** zzz\n'
    const entries = parseEntries(text, 'P')
    expect(entries.map(e => [e.id, e.title, e.values.State ?? null])).toEqual([['P1', 'First', 'done'], ['P3', '-', null]])
    // P3 has no state: pending.
    expect(rowsOf(files({ decisions: decisions(['D1', 'q', 'decided']), phases: text }))).toEqual({ P1: '✓ done', P3: '◌ pending' })
  })

  test('a decision with an unknown state is open; Source keeps its whole line', () => {
    const [d] = parseEntries(decisions(['D1', 'q', 'maybe', 'F4 and F9']), 'D')
    expect(d?.values.Source).toBe('F4 and F9')
    expect(header(files({ decisions: decisions(['D1', 'q', 'maybe']) }))).toEqual(['discussing', '0 decided · 1 open'])
  })

  test('follow-ups are read under their own heading only, taken once cited', () => {
    const text = '## Phases\n- F9 · not here\n## Follow-ups\n- F1 · a\n- F2 · b\n- F2 · again\n-F3 no space\n## Landing\n- F4 · no\n'
    expect(openFollowups(text, [])).toBe(2)
    expect(openFollowups(text, parseEntries(decisions(['D1', 'q', 'decided', 'F2']), 'D'))).toBe(1)
    expect(openFollowups(null, [])).toBe(0)
  })

  test('a torn active phase still draws, its tail unknown', () => {
    const f = files({ decisions: decisions(['D1', 'q', 'decided']), phases: phases(['P1', 'a', 'active']), action: 'garbage' })
    expect(rowsOf(f)).toEqual({ P1: '● active' })
  })
})

describe('when the band goes', () => {
  test('the directory gone, archived, or the claim missing or another session\'s', () => {
    const gone = { finished: true, state: null, band: null }
    expect(derive(files({ dirExists: false }))).toEqual(gone)
    expect(derive(files({ archived: true }))).toEqual(gone)
    expect(derive(files({ owner: null }))).toEqual(gone)
    expect(derive(files({ owner: 'session=sess-B\n' }))).toEqual(gone)
    expect(derive(files({ owner: 'garbage' }))).toEqual(gone)
  })

  test('landed is read off objective list by directory name', () => {
    const line = (dir: string, state: string) => `OBJECTIVE:\t${dir}\trate-limit-public-api\t${state}\topen:0\tpending:0\tblocked:0\tfollowups:0\towner:mine`
    expect(landedIn(`${line(`/private${DIR}`, 'landed')}\n`, DIR)).toBe(true)
    expect(landedIn(`${line(DIR, 'idle')}\n`, DIR)).toBe(false)
    expect(landedIn(`${line(`${ROOT}/20261101-000000-other`, 'landed')}\n`, DIR)).toBe(false)
    expect(landedIn('', DIR)).toBe(false)
  })
})

// ---------- the hooks module against the engine ----------

const BAND = {
  component: 'AbovePrompt' as const,
  props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 100, scroll: { offset: 0, bodyRows: 19 }, view: {} },
}

type Node = { text: string; mtimeMs: number }

// The repository's files, served beneath the plugin: each call on $.fs
// answers { value }, or { deny } where the real one would reject.
function serveFiles(on: On, disk: Map<string, Node>) {
  const isDir = (p: string) => [...disk.keys()].some(k => k.startsWith(`${p}/`))
  on('fs.stat', ($, e) => {
    const f = disk.get(e.path)
    if (f) return { value: { kind: 'file' as const, size: f.text.length, mtimeMs: f.mtimeMs, isLink: false } }
    if (isDir(e.path)) return { value: { kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false } }
    return { deny: `ENOENT: ${e.path}` }
  })
  on('fs.exists', ($, e) => ({ value: disk.has(e.path) || isDir(e.path) }))
  on('fs.read', ($, e) => {
    const f = disk.get(e.path)
    return f ? { value: f.text } : { deny: `ENOENT: ${e.path}` }
  })
  on('fs.list', ($, e) => {
    if (!isDir(e.path)) return { deny: `ENOENT: ${e.path}` }
    const names = new Map<string, { kind: 'file' | 'dir'; mtimeMs: number; size: number }>()
    for (const [k, f] of disk) {
      if (!k.startsWith(`${e.path}/`)) continue
      const [name, ...more] = k.slice(e.path.length + 1).split('/')
      if (!name) continue
      names.set(name, more.length ? { kind: 'dir', mtimeMs: 0, size: 0 } : { kind: 'file', mtimeMs: f.mtimeMs, size: f.text.length })
    }
    return { value: [...names].map(([name, x]) => ({ name, ...x, isLink: false })) }
  })
}

// The session beneath: its id, its cwd, a terminal, and the engine's own band.
function session(on: On, where: { id: string; cwd: string }) {
  on('session.id', () => ({ value: where.id }))
  on('session.cwd', () => ({ value: where.cwd }))
  on('session.surfaces', () => ({ value: ['terminal' as const] }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('tool.call', { tool: 'Bash' }, () => ({ result: { stdout: '', stderr: '', interrupted: false } }))
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return Text({ children: 'engine band' })
  })
}

// `objective list`, answered beneath: the state it prints for DIR.
function serveList(on: On, state: { value: string }, calls: string[][]) {
  on('process.run', ($, e) => {
    calls.push([...e.argv])
    const stdout = `OBJECTIVE:\t${DIR}\trate-limit-public-api\t${state.value}\topen:0\tpending:0\tblocked:0\tfollowups:0\towner:mine\n`
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
}

function objectiveDisk(over: Record<string, string> = {}): Map<string, Node> {
  const base: Record<string, string> = {
    [`${DIR}/objective.md`]: '# Rate limit the public API\n',
    [`${DIR}/owner`]: OWNER,
    [`${DIR}/decisions.md`]: decisions(['D1', 'Token bucket?', 'decided'], ['D2', 'Per-key or per-IP limits?', 'open']),
    [`${DIR}/phases.md`]: '# Phases\n',
    ...over,
  }
  return new Map(Object.entries(base).map(([k, text]) => [k, { text, mtimeMs: 100 }]))
}

const start = ($: Engine, cwd: string) => $.session.start({ cwd, surface: 'terminal', isInteractive: true })
const say = ($: Engine, text: string) => $.prompt.submit({ text, wait: false, origin: { kind: 'composer' } })
const ranBash = ($: Engine, command: string, agentId?: string) =>
  $.tool.call({ tool: 'Bash', command, ...(agentId ? { agentId } : {}) })

async function shows($: Engine, text: string | RegExp) {
  const ui = await $.ui.mount({ plugin: 'orca', surface: 'terminal', ...BAND })
  const found = await ui.find({ type: 'Text', text })
  await ui.unmount()
  return found !== undefined
}

describe('the band in a session', () => {
  test('this session\'s claim is found by walking up from the cwd; another session\'s is not', async ($, on) => {
    mock.clock(on, { now: 10_000 })
    const disk = objectiveDisk({
      [`${ROOT}/20261101-090000-someone-else/objective.md`]: '# other\n',
      [`${ROOT}/20261101-090000-someone-else/owner`]: 'session=sess-B\nhost=h\npid=2\n',
      [`${ROOT}/20261101-090000-someone-else/decisions.md`]: decisions(['D9', 'Not mine', 'open']),
    })
    serveFiles(on, disk)
    session(on, { id: SESSION, cwd: '/repo/main/src/lib' })
    await start($, '/repo/main/src/lib')

    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ plugin: 'orca', surface, ...BAND })
      expect(await ui.find({ type: 'Text', text: 'rate-limit-public-api' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'discussing' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '1 decided · 1 open' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '○ open' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /Per-key or per-IP/ })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /Not mine/ })).toBeUndefined()
      await ui.unmount()
    }
  })

  test('the walk up is bounded: a cwd too deep below the repository finds nothing', async ($, on) => {
    mock.clock(on, { now: 10_000 })
    serveFiles(on, objectiveDisk())
    session(on, { id: SESSION, cwd: '/repo/a/b/c/d/e/f/g/h/i' })
    await start($, '/repo/a/b/c/d/e/f/g/h/i')
    expect(await shows($, 'engine band')).toBe(true)
  })

  test('the claim the session\'s open agent writes is picked up after its objective open; a --steal elsewhere drops it', async ($, on) => {
    const clock = mock.clock(on, { now: 10_000 })
    const disk = objectiveDisk()
    disk.delete(`${DIR}/owner`)
    serveFiles(on, disk)
    session(on, { id: SESSION, cwd: '/repo/main' })
    await start($, '/repo/main')
    expect(await shows($, 'engine band')).toBe(true)

    disk.set(`${DIR}/owner`, { text: OWNER, mtimeMs: 11_000 })
    // Another command does not rescan.
    await ranBash($, `bash /plugins/orca/scripts/orca.sh objective digest "${DIR}"`)
    expect(await shows($, 'engine band')).toBe(true)
    // orca:objective-open runs the open in its own loop.
    await ranBash($, `cd /repo/main && bash /plugins/orca/scripts/orca.sh objective open "${DIR}"`, 'agent-open')
    expect(await shows($, 'rate-limit-public-api')).toBe(true)

    // The files move on; the next tick redraws.
    disk.set(`${DIR}/decisions.md`, { text: decisions(['D1', 'Token bucket?', 'decided'], ['D2', 'Per-key?', 'decided'], ['D3', 'New?', 'open']), mtimeMs: 12_000 })
    await clock.advance(1500)
    expect(await shows($, '2 decided · 1 open')).toBe(true)

    // Another session takes it over with --steal: the band goes on the next tick.
    disk.set(`${DIR}/owner`, { text: 'session=sess-B\nhost=h\npid=9\n', mtimeMs: 13_000 })
    await clock.advance(1500)
    expect(await shows($, 'engine band')).toBe(true)
  })

  test('the active phase shows its round, and archiving the objective takes the band down', async ($, on) => {
    const clock = mock.clock(on, { now: 10_000 })
    const disk = objectiveDisk({
      [`${DIR}/decisions.md`]: decisions(['D1', 'q', 'decided']),
      [`${DIR}/phases.md`]: phases(['P1', 'Token bucket + store', 'done', '**Commit:** a1b2c3d4\n'], ['P2', 'Middleware', 'active'], ['P3', 'Docs', 'pending']),
      [`${DIR}/phases/P2/action`]: frame('fix', 1, 2),
    })
    serveFiles(on, disk)
    session(on, { id: SESSION, cwd: '/repo' })
    await start($, '/repo')
    const ui = await $.ui.mount({ plugin: 'orca', surface: 'terminal', ...BAND })
    expect(await ui.find({ type: 'Text', text: 'P2/3' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '✓ done a1b2c3d' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '● fix r1 (2 gating)' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '◌ pending' })).toBeDefined()

    disk.set(`${DIR}/phases/P2/action`, { text: frame('commit', 2), mtimeMs: 11_000 })
    await clock.advance(1500)
    await ui.redraw()
    expect(await ui.find({ type: 'Text', text: '● committing' })).toBeDefined()

    disk.set(`${DIR}/archived`, { text: 'state=abandoned\n', mtimeMs: 12_000 })
    await clock.advance(1500)
    await ui.redraw()
    expect(await ui.find({ type: 'Text', text: 'engine band' })).toBeDefined()
  })

  test('an archive under way (archiving written, not yet archived) takes the band down', async ($, on) => {
    const clock = mock.clock(on, { now: 10_000 })
    const disk = objectiveDisk()
    serveFiles(on, disk)
    session(on, { id: SESSION, cwd: '/repo' })
    await start($, '/repo')
    const ui = await $.ui.mount({ plugin: 'orca', surface: 'terminal', ...BAND })
    expect(await ui.find({ type: 'Text', text: 'discussing' })).toBeDefined()
    disk.set(`${DIR}/archiving`, { text: 'state=abandoned\n', mtimeMs: 12_000 })
    await clock.advance(1500)
    await ui.redraw()
    expect(await ui.find({ type: 'Text', text: 'engine band' })).toBeDefined()
  })

  test('the directory vanishing takes the band down', async ($, on) => {
    const clock = mock.clock(on, { now: 10_000 })
    const disk = objectiveDisk()
    serveFiles(on, disk)
    session(on, { id: SESSION, cwd: '/repo' })
    await start($, '/repo')
    expect(await shows($, 'rate-limit-public-api')).toBe(true)
    for (const k of [...disk.keys()]) disk.delete(k)
    await clock.advance(1500)
    expect(await shows($, 'engine band')).toBe(true)
  })

  test('idle through three of the person\'s prompts drops it until its files change', async ($, on) => {
    const clock = mock.clock(on, { now: 10_000 })
    const disk = objectiveDisk({
      [`${DIR}/decisions.md`]: decisions(['D1', 'q', 'decided']),
      [`${DIR}/phases.md`]: phases(['P1', 'a', 'done'], ['P2', 'b', 'done']),
      [`${DIR}/report.md`]: reportVerified('P2'),
    })
    serveFiles(on, disk)
    serveList(on, { value: 'idle' }, [])
    session(on, { id: SESSION, cwd: '/repo' })
    await start($, '/repo')
    expect(await shows($, 'idle')).toBe(true)
    expect(await shows($, '2 phases done')).toBe(true)

    // A task notification is no prompt of the person's.
    await $.prompt.submit({ text: '<task-notification>\n<task-id>x</task-id>\n<status>completed</status>\n</task-notification>',
      wait: false, origin: { kind: 'task-notification' } })
    await say($, 'nice')
    await say($, 'what next?')
    expect(await shows($, 'idle')).toBe(true)
    await say($, 'something else entirely')
    expect(await shows($, 'engine band')).toBe(true)
    // Still owned and unchanged: later rescans leave it down.
    await say($, 'more')
    await start($, '/repo')
    expect(await shows($, 'engine band')).toBe(true)

    // A new phase (an /orca:loop) brings it back.
    disk.set(`${DIR}/phases.md`, { text: phases(['P1', 'a', 'done'], ['P2', 'b', 'done'], ['P3', 'c', 'pending']), mtimeMs: 20_000 })
    await say($, '/orca:loop fix the typo')
    expect(await shows($, 'ready')).toBe(true)
    await clock.advance(1500)
    expect(await shows($, '1 pending')).toBe(true)
  })

  test('an idle objective that landed is dropped at the next rescan', async ($, on) => {
    mock.clock(on, { now: 10_000 })
    const state = { value: 'idle' }
    const calls: string[][] = []
    serveFiles(on, objectiveDisk({
      [`${DIR}/decisions.md`]: decisions(['D1', 'q', 'decided']),
      [`${DIR}/phases.md`]: phases(['P1', 'a', 'done']),
      [`${DIR}/report.md`]: reportVerified('P1'),
    }))
    serveList(on, state, calls)
    session(on, { id: SESSION, cwd: '/repo' })
    await start($, '/repo')
    expect(await shows($, 'idle')).toBe(true)
    expect(calls[0]?.[0]).toBe('bash')
    expect(calls[0]?.[1]).toMatch(/\/scripts\/orca\.sh$/)
    expect(calls[0]?.slice(2)).toEqual(['objective', 'list', '/repo'])

    state.value = 'landed'
    await say($, 'merged it')
    expect(await shows($, 'engine band')).toBe(true)
  })

  test('an objective awaiting its final verification that landed is dropped too', async ($, on) => {
    mock.clock(on, { now: 10_000 })
    const state = { value: 'verify' }
    serveFiles(on, objectiveDisk({
      [`${DIR}/decisions.md`]: decisions(['D1', 'q', 'decided']),
      [`${DIR}/phases.md`]: phases(['P1', 'a', 'done']),
    }))
    serveList(on, state, [])
    session(on, { id: SESSION, cwd: '/repo' })
    await start($, '/repo')
    expect(await shows($, 'verify')).toBe(true)
    state.value = 'landed'
    await say($, 'merged it')
    expect(await shows($, 'engine band')).toBe(true)
  })

  test('only an objective with every phase done asks whether it landed', async ($, on) => {
    mock.clock(on, { now: 10_000 })
    const calls: string[][] = []
    serveFiles(on, objectiveDisk())
    serveList(on, { value: 'landed' }, calls)
    session(on, { id: SESSION, cwd: '/repo' })
    await start($, '/repo')
    await say($, 'hello')
    expect(await shows($, 'discussing')).toBe(true)
    expect(calls).toEqual([])
  })

  test('a live run takes the band over, and the objective comes back when it ends', async ($, on) => {
    const clock = mock.clock(on, { now: 10_000 })
    const runDir = '/repo/.orca/20261103-120000-feat-overlay'
    const disk = objectiveDisk()
    disk.set(`${runDir}/spec.md`, { text: 'spec', mtimeMs: 2 })
    serveFiles(on, disk)
    session(on, { id: SESSION, cwd: '/repo' })
    on('tool.call', { tool: 'Workflow' }, () => ({
      result: { status: 'async_launched', taskId: 'task1', taskType: 'local_workflow', runId: 'wf_1', transcriptDir: '/t/wf_1' },
    }))
    await start($, '/repo')
    expect(await shows($, 'rate-limit-public-api')).toBe(true)

    await $.tool.call({ tool: 'Workflow', scriptPath: '/plugins/orca/scripts/work-loop.workflow.js',
      args: { runDir, slug: 'overlay', items: [{ id: 'W1', title: 'a', deps: [], files: [] }] } })
    await clock.settle()
    expect(await shows($, 'overlay')).toBe(true)
    expect(await shows($, 'rate-limit-public-api')).toBe(false)

    await $.prompt.submit({ text: '<task-notification>\n<task-id>task1</task-id>\n<status>completed</status>\n</task-notification>',
      wait: false, origin: { kind: 'task-notification' } })
    await clock.advance(1500)
    expect(await shows($, 'rate-limit-public-api')).toBe(true)
  })

  test('session end takes the band down', async ($, on) => {
    mock.clock(on, { now: 10_000 })
    serveFiles(on, objectiveDisk())
    session(on, { id: SESSION, cwd: '/repo' })
    await start($, '/repo')
    expect(await shows($, 'rate-limit-public-api')).toBe(true)
    await $.session.end({ reason: 'other', sessionId: SESSION, resume: { id: SESSION } })
    expect(await shows($, 'engine band')).toBe(true)
  })
})
