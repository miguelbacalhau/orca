// The bands' shared layout: the top rule and the rows fitted to a width.
// Pure — the run band (run-band.tsx) and the objective band
// (objective-band.tsx) both lay their OrcaBand out through these, and draw it
// through bands.tsx.

import type { OrcaBand, OrcaRow } from '../types'

export function truncate(text: string, width: number): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  if (width <= 0) return ''
  return flat.length <= width ? flat : `${flat.slice(0, Math.max(0, width - 1))}…`
}

// The band's top border: a rule across the width with the header set in it,
// `── orca ─ slug · phase · detail ─────`. Each piece keeps its own tone; the
// facts are cut from the end to fit and the rule takes whatever is left.
export type RuleTone = 'rule' | 'name' | 'slug' | 'phase' | 'detail' | 'sep' | 'note'
export type RulePiece = { text: string; tone: RuleTone }

export function headerRule(band: OrcaBand, columns: number): RulePiece[] {
  const facts: RulePiece[] = [
    { text: band.slug, tone: 'slug' },
    { text: band.phase, tone: 'phase' },
    { text: band.detail, tone: 'detail' },
  ]
  if (band.source === 'files') facts.push({ text: 'no journal', tone: 'note' })
  const out: RulePiece[] = [{ text: '── ', tone: 'rule' }, { text: 'orca', tone: 'name' }, { text: ' ─ ', tone: 'rule' }]
  let used = out.reduce((n, p) => n + p.text.length, 0)
  // A space and at least two rule cells close the line after the facts.
  let room = columns - used - 3
  let first = true
  for (const fact of facts) {
    const text = fact.text.replace(/\s+/g, ' ').trim()
    if (!text) continue
    if (!first) {
      // A separator with nothing after it says nothing: stop instead.
      if (room < 5) break
      out.push({ text: ' · ', tone: 'sep' })
      room -= 3
    }
    first = false
    if (room <= 0) break
    const cut = truncate(text, room)
    out.push({ text: cut, tone: fact.tone })
    room -= cut.length
    if (cut !== text) break
  }
  used = out.reduce((n, p) => n + p.text.length, 0)
  out.push({ text: ` ${'─'.repeat(Math.max(2, columns - used - 1))}`, tone: 'rule' })
  return out
}

// Fits the rows to the band's width: ids padded to one column, titles cut to
// what is left beside the widest status (statuses capped so a long blocked
// reason never squeezes every title away), statuses cut to the remainder.
// `lead` is `  <id>  <title>  `, with `id` and `title` its two padded cells.
export function layoutRows(rows: OrcaRow[], columns: number): { lead: string; id: string; title: string; tail: string; row: OrcaRow }[] {
  const idW = Math.max(0, ...rows.map(r => r.id.length))
  const statusW = Math.min(30, Math.max(0, ...rows.map(r => r.status.length + 2)))
  const lead = 2 + idW + 2
  const titleMax = Math.max(0, ...rows.map(r => r.title.replace(/\s+/g, ' ').trim().length))
  const titleW = Math.min(titleMax, Math.max(8, columns - lead - 2 - statusW))
  return rows.map(row => {
    const id = row.id.padEnd(idW)
    const title = truncate(row.title, titleW).padEnd(titleW)
    const head = `  ${id}  ${title}  `
    const tail = truncate(`${row.mark} ${row.status}`, Math.max(1, columns - head.length))
    return { lead: head, id, title, tail, row }
  })
}
