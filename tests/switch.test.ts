// The switch hook (hooks/switch.ts): the objective.md header parse and the
// two shape checks as plain data, then the hook against the engine — the one
// EnterWorktree call it approves, and everything it passes on unanswered.
// Run with `claude plugin test <orca checkout>`.

import { describe, expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import { objectiveWorktree } from '../hooks/derive-objective'
import { ENTER_TOOL, enterPath, standsInAWorktree } from '../hooks/switch'

const ROOT = '/repo'
const WT = '/repo/orca-feat'
const SESSION = 'sess-A'
const OBJECTIVES = `${ROOT}/.orca/objectives`
const DIR = `${OBJECTIVES}/20261128-101500-feat`
const OTHER_DIR = `${OBJECTIVES}/20261128-111500-other`

// objective.md as `objective new` writes it.
const header = (worktree: string, slug = 'feat') =>
  `# ${slug}\n\n**Base:** \`main\`\n**Base commit:** \`0123456789abcdef0123456789abcdef01234567\`\n**Branch:** \`feature/${slug}\`\n**Worktree:** \`${worktree}\`\n\n## Idea\n\nMake it so.\n\n## Outcome\n\n## Non-goals\n\n## Constraints\n`
const owner = (session: string) => `session=${session}\nhost=h\npid=1\npidstart=x\ntaken=t\n`

describe('objectiveWorktree', () => {
  test('reads the verb-written header line, backticks dropped', () => {
    expect(objectiveWorktree(header(WT))).toBe(WT)
    expect(objectiveWorktree(header('/a/b c/orca-x'))).toBe('/a/b c/orca-x')
    expect(objectiveWorktree(`# t\r\n\r\n**Worktree:** \`${WT}\`\r\n`)).toBe(WT)
  })

  test('a value without backticks is read as written', () => {
    expect(objectiveWorktree(`# t\n\n**Worktree:** ${WT}\n`)).toBe(WT)
    expect(objectiveWorktree(`# t\n\n**Worktree:**   \`${WT}\`  \n`)).toBe(WT)
  })

  test('a missing or empty line, or one below the header, names nothing', () => {
    expect(objectiveWorktree('# t\n\n**Base:** `main`\n\n## Idea\n')).toBe(null)
    expect(objectiveWorktree('# t\n\n**Worktree:** ``\n')).toBe(null)
    expect(objectiveWorktree('# t\n\n**Worktree:**\n')).toBe(null)
    expect(objectiveWorktree(`# t\n\n## Idea\n\n**Worktree:** \`${WT}\`\n`)).toBe(null)
    expect(objectiveWorktree(`# t\n\n> **Worktree:** \`${WT}\`\n`)).toBe(null)
    expect(objectiveWorktree('')).toBe(null)
    expect(objectiveWorktree(null)).toBe(null)
  })

  test('the first line wins', () => {
    expect(objectiveWorktree(`**Worktree:** \`${WT}\`\n**Worktree:** \`/repo/orca-other\`\n`)).toBe(WT)
  })
})

describe('the shape checks', () => {
  test('the input names a worktree only by an absolute orca-* path', () => {
    expect(enterPath({ path: WT })).toBe(WT)
    expect(enterPath({ path: `${WT}/` })).toBe(WT)
    for (const input of [{ path: 'orca-feat' }, { path: '/repo/../repo/orca-feat' }, { path: '/repo/./orca-feat' },
      { path: '/repo/main' }, { path: '/repo/orca-feat/src' }, { path: 7 }, { name: 'feat' }, {}, null, undefined, WT])
      expect(enterPath(input)).toBe(null)
  })

  test('the session stands in a worktree: under the root, not the root, not .orca or .bare', () => {
    for (const cwd of ['/repo/main', '/repo/main/', '/repo/main/src/deep', '/repo/second', '/repo/orca-other', '/repo/main/../main'])
      expect(standsInAWorktree(cwd, WT)).toBe(true)
    for (const cwd of ['/repo', '/repo/', '/repo/main/..', '/repo/.orca', '/repo/.orca/objectives/x', '/repo/.bare',
      '/repo/.bare/worktrees/main', '/elsewhere', '/repository/main', '/', '', 'main'])
      expect(standsInAWorktree(cwd, WT)).toBe(false)
    // A worktree directly under / has no repository root to stand under.
    expect(standsInAWorktree('/main', '/orca-feat')).toBe(false)
  })
})

// ---------- the hook against the engine ----------

type Node = { text: string }

// The repository's files, served beneath the plugin.
function serveFiles(on: On, disk: Map<string, Node>, o: { isGone?: boolean; notText?: string } = {}) {
  const isDir = (p: string) => [...disk.keys()].some(k => k.startsWith(`${p}/`))
  on('fs.stat', ($, e) => {
    const f = disk.get(e.path)
    if (f) return { value: { kind: 'file' as const, size: f.text.length, mtimeMs: 100, isLink: false } }
    if (isDir(e.path)) return { value: { kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false } }
    return { deny: `ENOENT: ${e.path}` }
  })
  on('fs.exists', ($, e) => ({ value: disk.has(e.path) || isDir(e.path) }))
  on('fs.read', ($, e) => {
    if (e.path === o.notText) return { value: 7 as never }
    const f = disk.get(e.path)
    return f ? { value: f.text } : { deny: `ENOENT: ${e.path}` }
  })
  on('fs.list', ($, e) => {
    if (o.isGone || !isDir(e.path)) return { deny: `EACCES: ${e.path}` }
    const names = new Map<string, 'file' | 'dir'>()
    for (const k of disk.keys()) {
      if (!k.startsWith(`${e.path}/`)) continue
      const [name, ...more] = k.slice(e.path.length + 1).split('/')
      if (name) names.set(name, more.length ? 'dir' : 'file')
    }
    return { value: [...names].map(([name, kind]) => ({ name, kind, mtimeMs: 100, size: 1, isLink: false })) }
  })
}

function disk(over: Record<string, string | null> = {}): Map<string, Node> {
  const base: Record<string, string | null> = {
    [`${DIR}/objective.md`]: header(WT),
    [`${DIR}/owner`]: owner(SESSION),
    [`${DIR}/decisions.md`]: '# Decisions\n',
    [`${OTHER_DIR}/objective.md`]: header('/repo/orca-other', 'other'),
    [`${OTHER_DIR}/owner`]: owner('sess-B'),
    ...over,
  }
  const files = new Map<string, Node>()
  for (const [path, text] of Object.entries(base)) if (text !== null) files.set(path, { text })
  return files
}

// What is beneath the plugin on the event: it records that it was asked and
// answers nothing, as Claude Code does before it asks the person.
function beneath(on: On, asked: unknown[]) {
  on('classic.PermissionRequest', ($, e) => {
    asked.push(e.tool_input)
    return {}
  })
}

type Ask = { tool_name?: string; tool_input?: unknown; cwd?: string; session_id?: string; agent_id?: string; permission_mode?: string }

const ask = ($: Engine, o: Ask = {}) =>
  $.classic.PermissionRequest({
    tool_name: ENTER_TOOL, tool_input: { path: WT }, cwd: '/repo/main', session_id: SESSION, permission_mode: 'acceptEdits',
    ...o,
  } as never) as Promise<{ decision?: { behavior: string } }>

const ALLOW = { decision: { behavior: 'allow' } }

describe('the switch hook', () => {
  test('approves the claimed objective\'s worktree from the default worktree and a subdirectory of it', async ($, on) => {
    const asked: unknown[] = []
    serveFiles(on, disk())
    beneath(on, asked)
    expect(await ask($)).toEqual(ALLOW)
    expect(await ask($, { cwd: '/repo/main/packages/x' })).toEqual(ALLOW)
    expect(await ask($, { tool_input: { path: `${WT}/` } })).toEqual(ALLOW)
    // From another of orca's worktrees, and whatever the permission mode.
    expect(await ask($, { cwd: '/repo/orca-other', permission_mode: 'default' })).toEqual(ALLOW)
    expect(asked).toEqual([])
  })

  test('another path, or a sibling orca-* worktree this session does not own, is passed on', async ($, on) => {
    const asked: unknown[] = []
    serveFiles(on, disk())
    beneath(on, asked)
    for (const path of ['/repo/orca-other', '/repo/orca-unknown', '/repo/second', '/elsewhere/orca-feat', '/repo/orca-feat/src'])
      expect(await ask($, { tool_input: { path } })).toEqual({})
    expect(asked).toHaveLength(5)
  })

  test('another session\'s owner, or no owner, is passed on', async ($, on) => {
    const asked: unknown[] = []
    serveFiles(on, disk({ [`${DIR}/owner`]: owner('sess-B') }))
    beneath(on, asked)
    expect(await ask($)).toEqual({})
    expect(await ask($, { session_id: 'sess-C' })).toEqual({})
    expect(asked).toHaveLength(2)
  })

  test('no owner file is passed on', async ($, on) => {
    const asked: unknown[] = []
    serveFiles(on, disk({ [`${DIR}/owner`]: null }))
    beneath(on, asked)
    expect(await ask($)).toEqual({})
    expect(asked).toHaveLength(1)
  })

  for (const marker of ['archived', 'archiving']) {
    test(`an ${marker} objective is passed on`, async ($, on) => {
      const asked: unknown[] = []
      serveFiles(on, disk({ [`${DIR}/${marker}`]: 'landed\n' }))
      beneath(on, asked)
      expect(await ask($)).toEqual({})
      expect(asked).toHaveLength(1)
    })
  }

  test('an objective whose header names another worktree, or none, is passed on', async ($, on) => {
    const asked: unknown[] = []
    serveFiles(on, disk({ [`${DIR}/objective.md`]: header('/repo/orca-renamed') }))
    beneath(on, asked)
    expect(await ask($)).toEqual({})
    expect(asked).toHaveLength(1)
  })

  test('a directory that is not an objective\'s is never read as one', async ($, on) => {
    const asked: unknown[] = []
    serveFiles(on, disk({
      [`${DIR}/owner`]: null,
      [`${OBJECTIVES}/notes/objective.md`]: header(WT),
      [`${OBJECTIVES}/notes/owner`]: owner(SESSION),
    }))
    beneath(on, asked)
    expect(await ask($)).toEqual({})
    expect(asked).toHaveLength(1)
  })

  test('a relative path, a .. segment, a non-orca last segment, or no path is passed on', async ($, on) => {
    const asked: unknown[] = []
    serveFiles(on, disk())
    beneath(on, asked)
    for (const tool_input of [{ path: 'orca-feat' }, { path: '../orca-feat' }, { path: '/repo/main/../orca-feat' },
      { path: '/repo/main' }, { name: 'feat' }, {}, null, 'orca-feat'])
      expect(await ask($, { tool_input })).toEqual({})
    expect(asked).toHaveLength(8)
  })

  test('another tool, or a subagent\'s ask, is passed on', async ($, on) => {
    const asked: unknown[] = []
    serveFiles(on, disk())
    beneath(on, asked)
    expect(await ask($, { tool_name: 'ExitWorktree' })).toEqual({})
    expect(await ask($, { tool_name: 'Write', tool_input: { file_path: `${WT}/a.ts`, path: WT } })).toEqual({})
    expect(await ask($, { tool_name: 'Bash', tool_input: { command: 'ls', path: WT } })).toEqual({})
    expect(await ask($, { agent_id: 'a1' })).toEqual({})
    expect(asked).toHaveLength(4)
  })

  test('a session at the root, under .orca or .bare, or outside the repository is passed on', async ($, on) => {
    const asked: unknown[] = []
    serveFiles(on, disk())
    beneath(on, asked)
    for (const cwd of ['/repo', '/repo/', '/repo/.orca', '/repo/.orca/objectives', '/repo/.bare', '/elsewhere', '/'])
      expect(await ask($, { cwd })).toEqual({})
    expect(asked).toHaveLength(7)
  })

  test('an objectives directory that cannot be read is passed on', async ($, on) => {
    const asked: unknown[] = []
    serveFiles(on, disk(), { isGone: true })
    beneath(on, asked)
    expect(await ask($)).toEqual({})
    expect(asked).toHaveLength(1)
  })

  test('it never answers deny, and never replaces a deny from beneath', async ($, on) => {
    serveFiles(on, disk())
    on('classic.PermissionRequest', () => ({ decision: { behavior: 'deny' as const, message: 'no' } }))
    // What it recognizes it allows without asking beneath; anything else gets beneath's own answer.
    expect(await ask($)).toEqual(ALLOW)
    expect(await ask($, { tool_input: { path: '/repo/orca-other' } })).toEqual({ decision: { behavior: 'deny', message: 'no' } })
    expect(await ask($, { cwd: '/repo' })).toEqual({ decision: { behavior: 'deny', message: 'no' } })
  })

  test('a handler that throws still passes the ask on', async ($, on) => {
    const asked: unknown[] = []
    // An owner file read back as something that is no text.
    serveFiles(on, disk(), { notText: `${DIR}/owner` })
    beneath(on, asked)
    expect(await ask($)).toEqual({})
    expect(asked).toHaveLength(1)
  })

  test('the module registers it beside the relay\'s and the pin\'s classic hooks, each event still reaching beneath', async ($, on) => {
    const seen: string[] = []
    serveFiles(on, disk())
    on('classic.PermissionRequest', () => { seen.push('PermissionRequest'); return {} })
    on('classic.UserPromptSubmit', () => { seen.push('UserPromptSubmit'); return {} })
    on('classic.PostToolUse', () => { seen.push('PostToolUse'); return {} })
    on('classic.SubagentStart', () => { seen.push('SubagentStart'); return {} })
    on('classic.SubagentStop', () => { seen.push('SubagentStop'); return {} })
    on('classic.Stop', () => { seen.push('Stop'); return {} })
    await $.classic.UserPromptSubmit({ prompt: 'go', permission_mode: 'default' })
    await $.classic.PostToolUse({ tool_name: 'Bash', tool_input: {}, tool_response: {}, tool_use_id: 't', permission_mode: 'default' } as never)
    await $.classic.SubagentStart({ agent_id: 'a1', agent_type: 'general-purpose' })
    await $.classic.SubagentStop({ stop_hook_active: false, agent_id: 'a1', agent_transcript_path: '', agent_type: 'general-purpose' })
    await $.classic.Stop({ stop_hook_active: false, permission_mode: 'default' })
    expect(await ask($, { cwd: '/repo' })).toEqual({})
    expect(await ask($)).toEqual(ALLOW)
    expect(seen).toEqual(['UserPromptSubmit', 'PostToolUse', 'SubagentStart', 'SubagentStop', 'Stop', 'PermissionRequest'])
  })
})
