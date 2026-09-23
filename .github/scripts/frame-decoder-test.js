#!/usr/bin/env node
// Tests the relay codec block (base64 + UTF-8 + frame decoder) that the
// verb-calling workflow script carries as a literal copy. The sandboxed
// scripts cannot be imported (top-level workflow calls), so the block is
// extracted by its `relay codec` markers and evaluated standalone — CI
// runs node anyway (the envelope binds user machines, not runners).
//
//   node .github/scripts/frame-decoder-test.js scripts/work-loop.workflow.js [...]
'use strict'
const fs = require('fs')

const files = process.argv.slice(2)
if (!files.length) {
  console.error('usage: frame-decoder-test.js <workflow.js> [...]')
  process.exit(2)
}

let failures = 0
const check = (name, fn) => {
  try { fn(); console.log(`ok ${name}`) }
  catch (e) { failures++; console.error(`FAIL ${name}: ${e.message}`) }
}
const assert = (cond, msg) => { if (!cond) throw new Error(msg) }
const assertThrows = (fn, what) => {
  try { fn() } catch { return }
  throw new Error(`expected a throw: ${what}`)
}

const KEYS = ['rc', 'action', 'hash', 'message.b64']
const wrap = (s, w) => s.replace(new RegExp(`(.{${w}})`, 'g'), '$1\n')

for (const file of files) {
  const src = fs.readFileSync(file, 'utf8')
  const m = src.match(/\/\/ -+ relay codec[^\n]*\n([\s\S]*?)\/\/ -+ end relay codec/)
  if (!m) {
    console.error(`FAIL ${file}: no relay codec block found between the markers`)
    failures++
    continue
  }
  // eslint-disable-next-line no-new-func
  const { b64encode, b64decode, decodeFrame } =
    new Function(`${m[1]}; return { b64encode, b64decode, decodeFrame }`)()

  check(`${file}: codec matches the platform reference for ascii and non-ascii`, () => {
    for (const s of ['plain ascii', 'café — naïve', '汉字 and 🎉', '', 'multi\nline\nmessage', 'padding1', 'padding12']) {
      const ref = Buffer.from(s, 'utf8').toString('base64')
      assert(b64encode(s) === ref, `encode(${JSON.stringify(s)}) = ${b64encode(s)}, want ${ref}`)
      assert(b64decode(ref) === s, `decode(${ref}) != ${JSON.stringify(s)}`)
      assert(b64decode(b64encode(s)) === s, `round trip failed for ${JSON.stringify(s)}`)
    }
  })

  const msg = 'fix: handle "quotes" and — dashes\n\nwith a body café'
  const frame = (b64) =>
    `relay preamble to ignore\n@@ORCA@@\nrc=0\naction=accepted\nhash=${'a'.repeat(40)}\nmessage.b64=${b64}\n@@ORCA_END@@\ntrailing noise`

  check(`${file}: an unwrapped frame decodes`, () => {
    const out = decodeFrame(frame(b64encode(msg)), KEYS)
    assert(out.rc === '0', `rc = ${out.rc}`)
    assert(out.action === 'accepted', `action = ${out.action}`)
    assert(out.hash === 'a'.repeat(40), `hash = ${out.hash}`)
    assert(out.message === msg, `message = ${JSON.stringify(out.message)}`)
  })

  check(`${file}: a relay-wrapped .b64 value rejoins via the continuation rule`, () => {
    // Wrapped lines can end in '=' padding and must still read as
    // continuations, never as key lines.
    const out = decodeFrame(frame(wrap(b64encode(msg), 20)), KEYS)
    assert(out.message === msg, `message = ${JSON.stringify(out.message)}`)
  })

  check(`${file}: garbage frames are loud decode failures`, () => {
    assertThrows(() => decodeFrame('no markers at all', KEYS), 'missing markers')
    assertThrows(() => decodeFrame('@@ORCA@@\nrc=0', KEYS), 'missing end marker')
    assertThrows(() => decodeFrame('@@ORCA@@\nstray continuation\nrc=0\n@@ORCA_END@@', KEYS),
      'continuation before any key')
    assertThrows(() => decodeFrame(frame('@@not-base64@@'), KEYS), 'b64 garbage')
  })
}

process.exit(failures ? 1 : 0)
