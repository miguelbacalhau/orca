// The bands above the prompt: the run band (./run-band.tsx) and the objective
// band (./objective-band.tsx) share one AbovePrompt slot, the tone tables, and
// the drawing. Each band says what it does on session start, on a prompt, and
// on session end, and which band it would draw now; those events and the slot
// are registered here once, for both — an event takes one unmatched hook per
// module. The slot draws the run band whenever it has one, so a live run takes
// it over. One slot also means the person's collapse of it (`[-]`, ctrl+x
// ctrl+a) holds whichever band is showing.

import type { EngineInterface, Register, RenderInput } from 'claude-code'

import type { OrcaBand, OrcaTone } from '../types'
import { headerRule, layoutRows } from './layout'
import type { RuleTone } from './layout'
import { objectiveBand, objectiveEnd, objectivePrompt, objectiveStart } from './objective-band'
import { runBand, runEnd, runPrompt, runStart } from './run-band'

type Style = { color?: string; dimColor?: boolean; bold?: boolean }

const TONE: Record<OrcaTone, Style> = {
  done: { color: 'success' },
  live: { color: 'suggestion' },
  wait: { dimColor: true },
  queued: { dimColor: true },
  blocked: { color: 'error' },
  cut: { dimColor: true },
}

// The top border: the rule and the name in Claude's accent, the facts set in it.
const RULE: Record<RuleTone, Style> = {
  rule: { color: 'claude', dimColor: true },
  name: { color: 'claude', bold: true },
  slug: { bold: true },
  phase: { color: 'suggestion' },
  detail: {},
  sep: { dimColor: true },
  note: { color: 'warning' },
}

function drawBand($: EngineInterface, e: RenderInput<'AbovePrompt'>, band: OrcaBand) {
  const { Box, Text } = $.ui.resolve(e)
  const columns = Math.max(24, e.props.bodyColumns || 80)

  // A blank row above the rule sets the band off from the transcript's last
  // line, and one below it sets the rule off from the rows.
  return (
    <Box flexDirection="column" marginTop={1}>
      <Box marginBottom={band.rows.length ? 1 : 0}>
        {headerRule(band, columns).map(piece => (
          <Text {...RULE[piece.tone]} wrap="truncate-end">{piece.text}</Text>
        ))}
      </Box>
      {layoutRows(band.rows, columns).map(line => (
        <Box>
          <Text>{'  '}</Text>
          <Text bold>{line.id}</Text>
          <Text>{`  ${line.title}  `}</Text>
          <Text {...TONE[line.row.tone]} wrap="truncate-end">{line.tail}</Text>
        </Box>
      ))}
    </Box>
  )
}

// Each band hears every event; one that throws costs only itself.
export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    try { await runStart($) } catch { /* observe only */ }
    try { await objectiveStart($) } catch { /* observe only */ }
    return next(e)
  }).catch(($, e, next) => next(e)) // an observer never stands in a call's way

  on('prompt.submit', async ($, e, next) => {
    try { await runPrompt($, e.origin.kind, e.text) } catch { /* observe only */ }
    try { await objectivePrompt($, e.origin.kind) } catch { /* observe only */ }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.end', async ($, e, next) => {
    try { await runEnd($) } catch { /* observe only */ }
    try { await objectiveEnd($) } catch { /* observe only */ }
    return next(e)
  }).catch(($, e, next) => next(e))

  // The run band first: a live run takes the slot over.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const band = (await runBand($)) ?? (await objectiveBand($))
    return band ? drawBand($, e, band) : next(e)
  })
}
