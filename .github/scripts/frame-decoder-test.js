#!/usr/bin/env node
// Tests the verb codec block (base64 + UTF-8 + frame decoder) that the
// work loop carries: it decodes orca's verb-hook answers (b64: + base64 of
// UTF-8 JSON) and the frames inside them, and encodes the notes verb's
// payload. The sandboxed scripts cannot be imported (top-level workflow
// calls), so the block is extracted by its `verb codec` markers and
// evaluated standalone — CI runs node anyway (the envelope binds user
// machines, not runners).
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

for (const file of files) {
  const src = fs.readFileSync(file, 'utf8')
  const m = src.match(/\/\/ -+ verb codec[^\n]*\n([\s\S]*?)\/\/ -+ end verb codec/)
  if (!m) {
    console.error(`FAIL ${file}: no verb codec block found between the markers`)
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
    `pass-through line before the frame\n@@ORCA@@\nrc=0\naction=accepted\nhash=${'a'.repeat(40)}\nmessage.b64=${b64}\n@@ORCA_END@@\n`

  check(`${file}: an unwrapped frame decodes`, () => {
    const out = decodeFrame(frame(b64encode(msg)), KEYS)
    assert(out.rc === '0', `rc = ${out.rc}`)
    assert(out.action === 'accepted', `action = ${out.action}`)
    assert(out.hash === 'a'.repeat(40), `hash = ${out.hash}`)
    assert(out.message === msg, `message = ${JSON.stringify(out.message)}`)
  })

  check(`${file}: a hook answer decodes — base64 of UTF-8 JSON carrying a frame`, () => {
    const stdout = frame(b64encode(msg))
    const answer = Buffer.from(JSON.stringify({ v: 1, rc: 0, stdout, stderr: '' }), 'utf8').toString('base64')
    const a = JSON.parse(b64decode(answer))
    assert(a.stdout === stdout, 'stdout did not survive the round trip')
    assert(decodeFrame(a.stdout, KEYS).message === msg, 'frame inside the answer did not decode')
  })

  check(`${file}: garbage frames are loud decode failures`, () => {
    assertThrows(() => decodeFrame('no markers at all', KEYS), 'missing markers')
    assertThrows(() => decodeFrame('@@ORCA@@\nrc=0', KEYS), 'missing end marker')
    assertThrows(() => decodeFrame('@@ORCA@@\nstray line\nrc=0\n@@ORCA_END@@', KEYS),
      'a line opening no key')
    assertThrows(() => decodeFrame('@@ORCA@@\nrc=0\nsurprise=1\n@@ORCA_END@@', KEYS),
      'an undeclared key')
    assertThrows(() => decodeFrame(frame(b64encode(msg).replace(/(.{20})/, '$1\n')), KEYS),
      'a wrapped .b64 value (no continuation rule)')
    assertThrows(() => decodeFrame(frame('@@not-base64@@'), KEYS), 'b64 garbage')
  })
}

process.exit(failures ? 1 : 0)
