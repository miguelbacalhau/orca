// The bands' file reads: one size+mtime cache shared by the run band and the
// objective band, so a file that has not changed since the last tick is not
// read again.

import type { EngineInterface } from 'claude-code'

export type FileRead =
  | { status: 'ok'; text: string }
  | { status: 'missing' | 'unreadable' | 'too-large' }

// $.fs.read refuses anything larger.
const MAX_READ = 4 * 1024 * 1024

// Module variables start over on a hot reload: the cache only saves reads.
const textCache = new Map<string, { size: number; mtimeMs: number; text: string }>()

// 'too-large' past what $.fs.read takes.
export async function readCached($: EngineInterface, path: string): Promise<FileRead> {
  let stat
  try { stat = await $.fs.stat(path) } catch { return { status: 'missing' } }
  if (stat.size > MAX_READ) return { status: 'too-large' }
  const hit = textCache.get(path)
  if (hit && hit.size === stat.size && hit.mtimeMs === stat.mtimeMs) return { status: 'ok', text: hit.text }
  try {
    const text = await $.fs.read(path)
    textCache.set(path, { size: stat.size, mtimeMs: stat.mtimeMs, text })
    return { status: 'ok', text }
  } catch { return { status: 'unreadable' } }
}

export async function listNames($: EngineInterface, dir: string): Promise<{ name: string; mtimeMs: number }[]> {
  try { return (await $.fs.list(dir)).map(f => ({ name: f.name, mtimeMs: f.mtimeMs })) } catch { return [] }
}
