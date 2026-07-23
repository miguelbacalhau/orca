#!/usr/bin/env python3
"""Lockstep check for the contract vocabulary duplicated across the
config validators: scripts/lib.sh (the sole write path, used by
the config verb), and the sandboxed workflow scripts that carry literal
copies because they cannot read files (scripts/work-loop.workflow.js,
scripts/debug-loop.workflow.js, and — MODELS/EFFORTS only —
scripts/spec.workflow.js, which validates the spec spawn's overrides
at launch). A value accepted by one validator but rejected by another
bricks launches until the config file is hand-edited — so CI fails
when the lists drift.
"""
import re
import sys

# file label -> (path, keys checked there)
ALL = ('STAGES', 'MODELS', 'EFFORTS')
MODELS_ONLY = ('MODELS', 'EFFORTS')
FILES = {
    'lib.sh': ('scripts/lib.sh', ALL),
    'work-loop': ('scripts/work-loop.workflow.js', ALL),
    'debug-loop': ('scripts/debug-loop.workflow.js', ALL),
    'spec': ('scripts/spec.workflow.js', MODELS_ONLY),
}


def strings_of(blob):
    return re.findall(r"'([a-z-]+)'", blob)


def list_literal(src, name, path):
    """The bracketed list assigned to `name`, spreads NOT resolved."""
    m = re.search(re.escape(name) + r"\s*=\s*\[(.*?)\]", src, re.S)
    if not m:
        sys.exit(f"lockstep: no {name} list found in {path}")
    return m.group(1)


def js_vocab(path, keys):
    src = open(path).read()
    vocab = {}
    if 'STAGES' in keys:
        stages_blob = list_literal(src, 'const STAGES', path)
        # resolve one level of ...SPREAD against its own const list
        for spread in re.findall(r"\.\.\.([A-Z_]+)", stages_blob):
            stages_blob = stages_blob.replace(
                f"...{spread}", list_literal(src, f"const {spread}", path))
        vocab['STAGES'] = strings_of(stages_blob)
    for key in ('MODELS', 'EFFORTS'):
        if key in keys:
            vocab[key] = strings_of(list_literal(src, f'const {key}', path))
    return vocab


def sh_vocab(path, keys):
    """lib.sh's lists are space-separated double-quoted bash strings:
    ORCA_STAGES="spec plan ..."."""
    src = open(path).read()
    vocab = {}
    for key in keys:
        m = re.search(f'ORCA_{key}="([a-z ]+)"', src)
        if not m:
            sys.exit(f"lockstep: no ORCA_{key} list found in {path}")
        vocab[key] = m.group(1).split()
    return vocab


# The relay codec (base64 + UTF-8 + frame decoder) is a literal copy in
# each verb-calling workflow script — the sandbox reads no files. The
# copies get the lockstep check, not just the lockstep risk: any drift
# fails CI. (frame-decoder-test.js separately proves the block WORKS;
# this proves the copies are the same block.)
CODEC_FILES = [
    'scripts/work-loop.workflow.js',
    'scripts/debug-loop.workflow.js',
]


def codec_block(path):
    src = open(path).read()
    m = re.search(r"// -+ relay codec[^\n]*\n(.*?)// -+ end relay codec",
                  src, re.S)
    if not m:
        sys.exit(f"lockstep: no relay codec block found in {path}")
    return m.group(1)


vocabs = {}
for name, (path, keys) in FILES.items():
    reader = sh_vocab if path.endswith('.sh') else js_vocab
    vocabs[name] = reader(path, keys)

codec_copies = {p: codec_block(p) for p in CODEC_FILES}
if len(set(codec_copies.values())) != 1:
    print("lockstep: the relay codec copies drifted:")
    for p, block in codec_copies.items():
        print(f"  {p}: {len(block)} chars")
    sys.exit(1)

ok = True
for key in ALL:
    # order differs legitimately (each script lists its own tunables first);
    # the contract is the SET of accepted values
    sets = {name: sorted(v[key]) for name, v in vocabs.items() if key in v}
    if len({tuple(s) for s in sets.values()}) != 1:
        ok = False
        print(f"lockstep: {key} drifted across the validators:")
        for name, values in sets.items():
            print(f"  {name}: {values}")

if not ok:
    sys.exit(1)
for name, v in vocabs.items():
    counts = ", ".join(f"{len(v[k])} {k.lower()}" for k in ALL if k in v)
    print(f"lockstep: {name}: {counts} — in lockstep")
print(f"lockstep: relay codec: {len(CODEC_FILES)} identical copies")
