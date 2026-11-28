// The pin hook (hooks/pin.ts): the worktree line and its checks as plain
// data, then the hook against the engine — which spawns it pins and how, what
// it does to a bound agent's tool calls, how a restarted workflow agent is
// blocked, and that a binding outlives a reload. Run with
// `claude plugin test <orca checkout>`.

import { describe, expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { AgentSpawnInput, On } from 'claude-code'

import {
  BLOCKED_TOOLS, CD_FAILED_EXIT, editDenial, forgetPins, INTEGRATION_WORKTREE, normalizePath, PINNED, pinnedCommand,
  resolveIn, REVIEW_WORKTREE, shellNote, shellQuote, UNBOUND_DENIAL, WORKTREE, worktreeLine, worktreePath,
} from '../hooks/pin'

const ROOT = '/repo'
const WT = '/repo/orca-feat'

// ---------- the line ----------

describe('worktreeLine', () => {
  test('each pinned type is read by its own label', () => {
    expect(worktreeLine('orca:implement', `Worktree: ${WT}\nRun directory: /repo/.orca/feat-runs/r\nItem: W1 — title`)).toBe(WT)
    expect(worktreeLine('orca:merge', `Integration worktree: ${WT}\nRun directory: /r`)).toBe(WT)
    expect(worktreeLine('orca:spec-review-claude', `Review worktree: /repo/orca-feat-specreview\nRun directory: /r`)).toBe('/repo/orca-feat-specreview')
    // The planner's line is the fourth of its header block.
    expect(worktreeLine('orca:plan', `Run directory: /r\nItem: W1 — title\nOwned files: a.ts, b.ts\nIntegration worktree: ${WT}\nsome context`)).toBe(WT)
    expect(worktreeLine('orca:objective-implement', `\nWorktree: ${WT}  \nBrief: /repo/.orca/objectives/o/phases/P1/brief.md`)).toBe(WT)
  })

  test('another type\'s label pins nothing', () => {
    expect(worktreeLine('orca:implement', `Integration worktree: ${WT}`)).toBe(null)
    expect(worktreeLine('orca:merge', `Worktree: ${WT}`)).toBe(null)
    expect(worktreeLine('orca:spec-review-codex', `Worktree: ${WT}`)).toBe(null)
  })

  test('the first line of the label wins', () => {
    expect(worktreeLine('orca:fix', `Worktree: ${WT}\nWorktree: /repo/orca-other`)).toBe(WT)
  })

  test('a header line with no value does not end the header', () => {
    // The planner's prompt for an item with files: [] — `Owned files: ` and nothing after it.
    const prompt = ['Run directory: /r', 'Item: W1 — title', `Owned files: ${[].join(', ')}`, `Integration worktree: ${WT}`].join('\n')
    expect(prompt).toContain('Owned files: \nIntegration worktree:')
    expect(worktreeLine('orca:plan', prompt)).toBe(WT)
    expect(worktreeLine('orca:plan', `Run directory: /r\nOwned files:\nIntegration worktree: ${WT}`)).toBe(WT)
    expect(worktreeLine('orca:implement', 'Worktree: ')).toBe('')
    expect(worktreeLine('orca:implement', 'Worktree:')).toBe('')
  })

  test('no line, or a label after any other text, pins nothing', () => {
    expect(worktreeLine('orca:implement', 'Run directory: /r\nItem: W1')).toBe(null)
    expect(worktreeLine('orca:implement', `Please work on this.\nWorktree: ${WT}`)).toBe(null)
    expect(worktreeLine('orca:implement', `Run directory: /r\n\nWorktree: ${WT}`)).toBe(null)
    expect(worktreeLine('orca:address', `The user wrote:\n> Worktree: ${WT}`)).toBe(null)
    expect(worktreeLine('orca:implement', '')).toBe(null)
  })

  test('a type off the allow-list is never read, whatever its prompt quotes', () => {
    const quoted = `Worktree: ${WT}\nRepository: /repo/main`
    for (const type of ['orca:objective-open', 'orca:council', 'orca:council-codex', 'orca:spec', 'orca:research',
      'orca:audit', 'orca:doctor', 'general-purpose', 'workflow-subagent', 'toString'])
      expect(worktreeLine(type, quoted)).toBe(null)
  })

  test('the allow-list is these types, each with its label and how it starts', () => {
    const by = (label: string, workflow: boolean) =>
      Object.keys(PINNED).filter(t => PINNED[t]?.label === label && PINNED[t]?.workflow === workflow).sort()
    expect(by(WORKTREE, true)).toEqual(['orca:commit', 'orca:fix', 'orca:implement', 'orca:review-claude', 'orca:review-codex'])
    expect(by(INTEGRATION_WORKTREE, true)).toEqual(['orca:integrate', 'orca:merge', 'orca:plan'])
    expect(by(REVIEW_WORKTREE, true)).toEqual(['orca:spec-review-claude', 'orca:spec-review-codex'])
    expect(by(WORKTREE, false)).toEqual(['orca:address', 'orca:objective-implement', 'orca:objective-review-claude',
      'orca:objective-review-codex', 'orca:objective-verify', 'orca:phases', 'orca:phases-review-claude',
      'orca:phases-review-codex', 'orca:provision'])
    expect(Object.keys(PINNED).length).toBe(19)
    // The labels are frozen: the composers spell them (tests/work-loop.bats greps for them).
    expect([WORKTREE, INTEGRATION_WORKTREE, REVIEW_WORKTREE]).toEqual(['Worktree', 'Integration worktree', 'Review worktree'])
  })
})

describe('worktreePath', () => {
  test('an absolute orca-* path passes, a trailing slash dropped', () => {
    expect(worktreePath(WT)).toBe(WT)
    expect(worktreePath(`${WT}/`)).toBe(WT)
    expect(worktreePath('/a/b c/orca-x-specreview')).toBe('/a/b c/orca-x-specreview')
  })

  test('a relative path, a dot segment, another basename, or a bare root fails', () => {
    expect(worktreePath('orca-feat')).toBe(null)
    expect(worktreePath('./orca-feat')).toBe(null)
    expect(worktreePath('/repo/../repo/orca-feat')).toBe(null)
    expect(worktreePath('/repo/./orca-feat')).toBe(null)
    expect(worktreePath('/repo//orca-feat')).toBe(null)
    expect(worktreePath('/repo/main')).toBe(null)
    expect(worktreePath('/repo/orca-feat/src')).toBe(null)
    expect(worktreePath('/repo/my-orca-feat')).toBe(null)
    expect(worktreePath('/orca-feat')).toBe(null)
    expect(worktreePath('')).toBe(null)
    expect(worktreePath('/')).toBe(null)
  })
})

describe('paths and commands', () => {
  test('the Bash prefix is cd, || exit 97, a newline, then the command as given', () => {
    expect(CD_FAILED_EXIT).toBe(97)
    expect(pinnedCommand(WT, 'git status')).toBe(`cd '/repo/orca-feat' || exit 97\ngit status`)
    expect(pinnedCommand(WT, 'cat <<EOF\nx\nEOF')).toBe(`cd '/repo/orca-feat' || exit 97\ncat <<EOF\nx\nEOF`)
    expect(pinnedCommand("/re'po/orca-x", 'ls')).toBe(`cd '/re'\\''po/orca-x' || exit 97\nls`)
    expect(shellQuote("a'b")).toBe(`'a'\\''b'`)
  })

  test('a path argument resolves against the worktree', () => {
    expect(resolveIn(WT, 'src/a.ts')).toBe('/repo/orca-feat/src/a.ts')
    expect(resolveIn(WT, './src/../b.ts')).toBe('/repo/orca-feat/b.ts')
    expect(resolveIn(WT, '/elsewhere/x')).toBe('/elsewhere/x')
    expect(normalizePath('/repo/orca-feat/../main//a.ts')).toBe('/repo/main/a.ts')
  })

  test('edits are refused under the root outside the worktree and .orca, allowed elsewhere', () => {
    for (const path of ['/repo/main/src/a.ts', '/repo/orca-other/a.ts', '/repo/.bare/config', '/repo/CLAUDE.md',
      '/repo/feature-x/a.ts', '/repo/orca-feat/../main/a.ts', '../main/a.ts', '/repo/orca-feat-2/a.ts', '/repo/.orca-x/a'])
      expect(editDenial(WT, path)).toMatch(/this agent works in \/repo\/orca-feat/)
    for (const path of ['/repo/orca-feat/src/a.ts', '/repo/orca-feat', 'src/a.ts', '/repo/.orca/feat-runs/r/plans/W1.md',
      '/repo/.orca/objectives/o/phases/P1/notes.md', '/tmp/scratch.txt', '/private/tmp/x', '/repository/a.ts', '/a.ts'])
      expect(editDenial(WT, path)).toBe(null)
    expect(editDenial(WT, '/repo/main/a.ts')).toContain('/repo/main/a.ts')
  })
})

// ---------- the hook against the engine ----------

type Spawned = { cwd?: string; prompt: string; subagentType: string }
type Called = Record<string, unknown> & { tool: string }

// The engine beneath the plugin: spawns answered with the next id of `ids`,
// tool calls recorded and answered, `.orca` present under ROOT alone.
function beneath(on: On, o: { ids?: string[]; spawned?: Spawned[]; called?: Called[]; context?: string[]; disk?: { isGone: boolean } } = {}) {
  const ids = [...(o.ids ?? [])]
  on('agent.spawn', ($, e) => {
    o.spawned?.push({ cwd: e.cwd, prompt: e.prompt, subagentType: e.subagentType })
    return { model: 'claude-test', agentId: e.resume?.agentId ?? ids.shift() ?? 'unnamed' }
  })
  on('tool.call', ($, e) => {
    o.called?.push({ ...e } as Called)
    return { result: 'ran', text: 'ran', ...(o.context ? { context: o.context } : {}) } as never
  })
  on('tool.offer', () => ({ isOffered: true }))
  on('fs.exists', ($, e) => {
    if (o.disk?.isGone) throw new Error('disk gone')
    return { value: e.path === `${ROOT}/.orca` }
  })
  on('classic.SubagentStart', () => ({}))
  on('classic.SubagentStop', () => ({}))
}

function spawnInput(subagentType: string, prompt: string, extra: Partial<AgentSpawnInput> = {}): AgentSpawnInput {
  return {
    tool_use_id: 'tu1', prompt, description: 'task', subagentType,
    provider: { plugin: 'orca', tier: 'user' }, parentModel: 'claude-test', background: true, fork: false,
    ...extra,
  } as AgentSpawnInput
}

const WORKFLOW = { workflow: { runId: 'wf_1', agentIndex: 1 } }
const implementPrompt = `Worktree: ${WT}\nRun directory: /repo/.orca/feat-runs/r\nItem: W1 — title`

async function spawnWorkflow($: Engine, subagentType = 'orca:implement', prompt = implementPrompt) {
  return $.agent.spawn(spawnInput(subagentType, prompt, WORKFLOW))
}

const call = ($: Engine, input: Record<string, unknown>) => $.tool.call(input as never) as Promise<{ deny?: string; context?: readonly string[] }>
const offer = ($: Engine, agentId: string, subagentType: string, tool = 'Bash') =>
  $.tool.offer({ tool, provider: { plugin: 'engine', tier: 'core' }, for: 'list', agentId, subagentType })
const stop = ($: Engine, agent_id: string, agent_type: string) =>
  $.classic.SubagentStop({ stop_hook_active: false, agent_id, agent_transcript_path: '', agent_type })

describe('spawns', () => {
  test('an Agent-tool spawn of a pinned type runs in its worktree', async ($, on) => {
    forgetPins()
    const spawned: Spawned[] = []
    beneath(on, { ids: ['t1'], spawned })
    const started = await $.agent.spawn(spawnInput('orca:objective-implement', `Worktree: ${WT}\nBrief: /repo/.orca/o/brief.md`))
    expect(started).toMatchObject({ agentId: 't1' })
    expect(spawned).toEqual([{ cwd: WT, prompt: `Worktree: ${WT}\nBrief: /repo/.orca/o/brief.md`, subagentType: 'orca:objective-implement' }])
  })

  test('a workflow spawn goes on unchanged and its id is bound', async ($, on) => {
    forgetPins()
    const spawned: Spawned[] = []
    const called: Called[] = []
    beneath(on, { ids: ['w1'], spawned, called })
    expect(await spawnWorkflow($)).toMatchObject({ agentId: 'w1' })
    expect(spawned).toEqual([{ cwd: undefined, prompt: implementPrompt, subagentType: 'orca:implement' }])
    await call($, { tool: 'Bash', command: 'pwd', agentId: 'w1' })
    expect(called[0]?.command).toBe(`cd '${WT}' || exit 97\npwd`)
  })

  test('a line that fails the check leaves the spawn unpinned, never denied', async ($, on) => {
    forgetPins()
    const spawned: Spawned[] = []
    const called: Called[] = []
    beneath(on, { ids: ['t2', 't3', 't4', 'w2'], spawned, called })
    // No .orca beside it, not an orca- directory, a relative path.
    for (const path of ['/elsewhere/orca-feat', '/repo/main', 'orca-feat'])
      expect(await $.agent.spawn(spawnInput('orca:objective-verify', `Worktree: ${path}`))).toMatchObject({ model: 'claude-test' })
    expect(spawned.map(s => s.cwd)).toEqual([undefined, undefined, undefined])
    // A workflow agent with an unusable line is known, so it is neither prefixed nor blocked.
    await spawnWorkflow($, 'orca:implement', 'Worktree: /repo/main\nRun directory: /r')
    await offer($, 'w2', 'orca:implement')
    expect(await call($, { tool: 'Bash', command: 'ls', agentId: 'w2' })).not.toHaveProperty('deny')
    expect(called[0]?.command).toBe('ls')
  })

  test('types off the allow-list, quoted labels, forks and verb calls are untouched', async ($, on) => {
    forgetPins()
    const spawned: Spawned[] = []
    beneath(on, { ids: ['x1', 'x2', 'x3', 'x4', 'x5', 'x6'], spawned })
    await $.agent.spawn(spawnInput('orca:objective-open', `Mode: new\nRepository: /repo/main\nIdea: fix it\nWorktree: ${WT}`))
    await $.agent.spawn(spawnInput('orca:council', `Worktree: ${WT}\nQuestion: where?`, WORKFLOW))
    await $.agent.spawn(spawnInput('general-purpose', `Worktree: ${WT}`))
    await $.agent.spawn(spawnInput('orca:address', `Address these comments.\nWorktree: ${WT}`))
    await $.agent.spawn(spawnInput('orca:implement', implementPrompt, { fork: true }))
    // A relay verb call: an empty prompt, the request in the model name.
    await $.agent.spawn(spawnInput('workflow-subagent', '', { ...WORKFLOW, model: 'orca:{"v":1,"verb":"self-test","args":[]}' }))
    expect(spawned.map(s => s.cwd)).toEqual([undefined, undefined, undefined, undefined, undefined, undefined])
    expect(spawned[5]?.prompt).toBe('')
  })

  test('a resume passes through unchanged', async ($, on) => {
    forgetPins()
    const spawned: Spawned[] = []
    beneath(on, { ids: ['t5'], spawned })
    await $.agent.spawn(spawnInput('orca:objective-implement', `Worktree: ${WT}`))
    await $.agent.spawn(spawnInput('orca:objective-implement', 'fix round 2', { resume: { agentId: 't5' }, cwd: WT }))
    await $.agent.spawn(spawnInput('orca:objective-implement', `Worktree: /repo/orca-other`, { resume: { agentId: 't5' } }))
    expect(spawned.slice(1)).toEqual([
      { cwd: WT, prompt: 'fix round 2', subagentType: 'orca:objective-implement' },
      { cwd: undefined, prompt: 'Worktree: /repo/orca-other', subagentType: 'orca:objective-implement' },
    ])
  })
})

describe('a bound agent\'s tool calls', () => {
  test('Bash is prefixed for the bound id, with the note once; the main thread and others are not', async ($, on) => {
    forgetPins()
    const called: Called[] = []
    beneath(on, { ids: ['w3'], called, context: ['from beneath'] })
    await spawnWorkflow($)
    const first = await call($, { tool: 'Bash', command: 'echo "a\'b"', agentId: 'w3' })
    const second = await call($, { tool: 'Bash', command: 'ls', agentId: 'w3' })
    await call($, { tool: 'Bash', command: 'ls' })
    await call($, { tool: 'Bash', command: 'ls', agentId: 'stranger' })
    expect(called.map(c => c.command)).toEqual([`cd '${WT}' || exit 97\necho "a'b"`, `cd '${WT}' || exit 97\nls`, 'ls', 'ls'])
    expect(first.context).toEqual(['from beneath', shellNote(WT)])
    expect(shellNote(WT)).toBe(`orca starts this agent's shell commands in ${WT}`)
    expect(second.context).toEqual(['from beneath'])
  })

  test('Glob and Grep search the worktree by default and resolve a relative path', async ($, on) => {
    forgetPins()
    const called: Called[] = []
    beneath(on, { ids: ['w4'], called })
    await spawnWorkflow($, 'orca:plan', `Run directory: /r\nItem: W1 — t\nOwned files: a\nIntegration worktree: ${WT}`)
    await call($, { tool: 'Glob', pattern: '**/*.ts', agentId: 'w4' })
    await call($, { tool: 'Grep', pattern: 'x', path: 'src', agentId: 'w4' })
    await call($, { tool: 'Grep', pattern: 'x', path: '/repo/main/src', agentId: 'w4' })
    await call($, { tool: 'Glob', pattern: '*', path: '../main', agentId: 'w4' })
    expect(called.map(c => c.path)).toEqual([WT, `${WT}/src`, '/repo/main/src', '/repo/main'])
  })

  test('edits outside the worktree are denied, inside it, under .orca and outside the repository allowed; Read never', async ($, on) => {
    forgetPins()
    const called: Called[] = []
    beneath(on, { ids: ['w5'], called })
    await spawnWorkflow($)
    const denied = async (input: Record<string, unknown>) => (await call($, { ...input, agentId: 'w5' })).deny
    expect(await denied({ tool: 'Edit', file_path: '/repo/main/a.ts', old_string: 'a', new_string: 'b' })).toContain(WT)
    expect(await denied({ tool: 'Write', file_path: '/repo/orca-other/a.ts', content: 'x' })).toContain('/repo/orca-other/a.ts')
    expect(await denied({ tool: 'Write', file_path: '/repo/.bare/config', content: 'x' })).toMatch(/outside it/)
    expect(await denied({ tool: 'Write', file_path: '/repo/notes.md', content: 'x' })).toMatch(/outside it/)
    expect(await denied({ tool: 'NotebookEdit', notebook_path: '/repo/main/n.ipynb', new_source: 'x' })).toMatch(/outside it/)
    expect(called).toEqual([])
    expect(await denied({ tool: 'Edit', file_path: `${WT}/a.ts`, old_string: 'a', new_string: 'b' })).toBe(undefined)
    expect(await denied({ tool: 'Write', file_path: '/repo/.orca/feat-runs/r/plans/W1.md', content: 'x' })).toBe(undefined)
    expect(await denied({ tool: 'Write', file_path: '/tmp/scratch', content: 'x' })).toBe(undefined)
    expect(await denied({ tool: 'Read', file_path: '/repo/main/a.ts' })).toBe(undefined)
    expect(called.map(c => c.file_path)).toEqual([`${WT}/a.ts`, '/repo/.orca/feat-runs/r/plans/W1.md', '/tmp/scratch', '/repo/main/a.ts'])
  })

  test('an Agent-tool pin denies the same edits and leaves Bash and searches as given', async ($, on) => {
    forgetPins()
    const called: Called[] = []
    beneath(on, { ids: ['t6'], called })
    await $.agent.spawn(spawnInput('orca:address', `Worktree: ${WT}\nNotes file: /repo/.orca/review-notes/k.json`))
    expect((await call($, { tool: 'Edit', file_path: '/repo/main/a.ts', old_string: 'a', new_string: 'b', agentId: 't6' })).deny).toContain(WT)
    await call($, { tool: 'Bash', command: 'ls', agentId: 't6' })
    await call($, { tool: 'Grep', pattern: 'x', agentId: 't6' })
    expect(called.map(c => [c.tool, c.command, c.path])).toEqual([['Bash', 'ls', undefined], ['Grep', undefined, undefined]])
  })
})

describe('a restarted workflow agent', () => {
  const writes: Record<string, unknown>[] = [
    { tool: 'Bash', command: 'git commit -m x' },
    { tool: 'Edit', file_path: `${WT}/a.ts`, old_string: 'a', new_string: 'b' },
    { tool: 'Write', file_path: `${WT}/a.ts`, content: 'x' },
    { tool: 'NotebookEdit', notebook_path: `${WT}/n.ipynb`, new_source: 'x' },
    { tool: 'StructuredOutput', completed: true, summary: 'done' },
  ]

  test('typed by tool.offer with no binding: its writes and its result are denied', async ($, on) => {
    forgetPins()
    const called: Called[] = []
    beneath(on, { called })
    expect(await offer($, 'r1', 'orca:implement')).toEqual({ isOffered: true })
    for (const input of writes) expect((await call($, { ...input, agentId: 'r1' })).deny).toBe(UNBOUND_DENIAL)
    expect(BLOCKED_TOOLS).toEqual(['Bash', 'Edit', 'Write', 'NotebookEdit', 'StructuredOutput'])
    expect(UNBOUND_DENIAL).toContain('orca could not bind this agent to its worktree')
    expect(called).toEqual([])
    // Reading is still its to do.
    expect((await call($, { tool: 'Read', file_path: `${WT}/a.ts`, agentId: 'r1' })).deny).toBe(undefined)
  })

  test('typed by SubagentStart alone: denied the same', async ($, on) => {
    forgetPins()
    beneath(on)
    await $.classic.SubagentStart({ agent_id: 'r2', agent_type: 'orca:merge' })
    for (const input of writes) expect((await call($, { ...input, agentId: 'r2' })).deny).toBe(UNBOUND_DENIAL)
  })

  test('a first attempt is bound before its loop is typed, and a start seen early does not block it', async ($, on) => {
    forgetPins()
    const called: Called[] = []
    beneath(on, { ids: ['w6', 'w7'], called })
    await spawnWorkflow($)
    await offer($, 'w6', 'orca:implement')
    await $.classic.SubagentStart({ agent_id: 'w6', agent_type: 'orca:implement' })
    expect((await call($, { tool: 'Bash', command: 'ls', agentId: 'w6' })).deny).toBe(undefined)
    // SubagentStart ahead of the spawn's answer: the binding takes its place.
    await $.classic.SubagentStart({ agent_id: 'w7', agent_type: 'orca:implement' })
    await spawnWorkflow($)
    expect((await call($, { tool: 'Bash', command: 'ls', agentId: 'w7' })).deny).toBe(undefined)
    expect(called.map(c => c.command)).toEqual([`cd '${WT}' || exit 97\nls`, `cd '${WT}' || exit 97\nls`])
  })

  test('an unpinned type, an Agent-tool type, and an id no event typed are let through', async ($, on) => {
    forgetPins()
    const called: Called[] = []
    beneath(on, { called })
    await offer($, 'u1', 'orca:research')
    await offer($, 'u2', 'orca:objective-implement')
    await $.classic.SubagentStart({ agent_id: 'u3', agent_type: 'general-purpose' })
    for (const agentId of ['u1', 'u2', 'u3', 'u4'])
      expect((await call($, { tool: 'Bash', command: 'ls', agentId })).deny).toBe(undefined)
    expect((await call($, { tool: 'StructuredOutput', ok: true, agentId: 'u4' })).deny).toBe(undefined)
    expect(called.map(c => c.command)).toEqual(['ls', 'ls', 'ls', 'ls', undefined])
  })
})

describe('bindings over time', () => {
  test('a workflow binding is dropped when the agent stops, an Agent-tool binding kept', async ($, on) => {
    forgetPins()
    const called: Called[] = []
    beneath(on, { ids: ['w8', 't7'], called })
    await spawnWorkflow($)
    await $.agent.spawn(spawnInput('orca:objective-implement', `Worktree: ${WT}`))
    await stop($, 'w8', 'orca:implement')
    await stop($, 't7', 'orca:objective-implement')
    await call($, { tool: 'Bash', command: 'ls', agentId: 'w8' })
    expect(called.map(c => c.command)).toEqual(['ls'])
    expect((await call($, { tool: 'Write', file_path: '/repo/main/a.ts', content: 'x', agentId: 't7' })).deny).toContain(WT)
  })

  test('a binding survives a reload through $.state', async ($, on) => {
    forgetPins()
    const called: Called[] = []
    beneath(on, { ids: ['w9', 't8'], called })
    await spawnWorkflow($)
    await $.agent.spawn(spawnInput('orca:phases', `Objective directory: /repo/.orca/objectives/o\nWorktree: ${WT}`))
    await offer($, 'r3', 'orca:fix')
    forgetPins()
    await call($, { tool: 'Bash', command: 'ls', agentId: 'w9' })
    expect(called.map(c => c.command)).toEqual([`cd '${WT}' || exit 97\nls`])
    expect((await call($, { tool: 'Write', file_path: '/repo/main/a.ts', content: 'x', agentId: 't8' })).deny).toContain(WT)
    expect((await call($, { tool: 'Bash', command: 'ls', agentId: 'r3' })).deny).toBe(UNBOUND_DENIAL)
    // A loop typed after the reload is still known: not taken for a restart.
    await offer($, 'w9', 'orca:implement')
    expect((await call($, { tool: 'Bash', command: 'ls', agentId: 'w9' })).deny).toBe(undefined)
  })

  test('a resume whose binding is lost is bound again from its cwd', async ($, on) => {
    forgetPins()
    const spawned: Spawned[] = []
    beneath(on, { spawned })
    // Nothing in the module or in $.state knows t9: the spawn was before this module loaded.
    await $.agent.spawn(spawnInput('orca:objective-implement', 'fix round 3', { resume: { agentId: 't9' }, cwd: WT }))
    expect(spawned).toEqual([{ cwd: WT, prompt: 'fix round 3', subagentType: 'orca:objective-implement' }])
    expect((await call($, { tool: 'Edit', file_path: '/repo/main/a.ts', old_string: 'a', new_string: 'b', agentId: 't9' })).deny).toContain(WT)
    // A cwd that is no orca worktree binds nothing.
    await $.agent.spawn(spawnInput('orca:objective-implement', 'go on', { resume: { agentId: 't10' }, cwd: '/repo/main' }))
    expect((await call($, { tool: 'Edit', file_path: '/repo/main/a.ts', old_string: 'a', new_string: 'b', agentId: 't10' })).deny).toBe(undefined)
  })
})

describe('failing open', () => {
  test('a lookup that fails leaves an Agent-tool spawn unpinned and lets it through', async ($, on) => {
    forgetPins()
    const spawned: Spawned[] = []
    const called: Called[] = []
    const disk = { isGone: true }
    beneath(on, { ids: ['f1'], spawned, called, disk })
    expect(await $.agent.spawn(spawnInput('orca:objective-implement', `Worktree: ${WT}`))).toMatchObject({ agentId: 'f1' })
    expect(spawned).toEqual([{ cwd: undefined, prompt: `Worktree: ${WT}`, subagentType: 'orca:objective-implement' }])
    await call($, { tool: 'Bash', command: 'ls', agentId: 'f1' })
    expect(called.map(c => c.command)).toEqual(['ls'])
  })

  test('a lookup that fails on a workflow spawn leaves a known first attempt: offered tools, it is not blocked', async ($, on) => {
    forgetPins()
    const called: Called[] = []
    const disk = { isGone: true }
    beneath(on, { ids: ['f2'], called, disk })
    expect(await spawnWorkflow($)).toMatchObject({ agentId: 'f2' })
    expect(await offer($, 'f2', 'orca:implement')).toEqual({ isOffered: true })
    await $.classic.SubagentStart({ agent_id: 'f2', agent_type: 'orca:implement' })
    expect((await call($, { tool: 'StructuredOutput', completed: true, summary: 'done', agentId: 'f2' })).deny).toBe(undefined)
    expect((await call($, { tool: 'Bash', command: 'ls', agentId: 'f2' })).deny).toBe(undefined)
    // Unpinned: the command runs as given.
    expect(called.map(c => c.command)).toEqual([undefined, 'ls'])
  })
})
