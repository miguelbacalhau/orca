# The shared JSON tokenizer: load it with a first -f ahead of the script
# that walks the grammar (codex-payload.awk, findings.awk). It reads the
# whole input into `document`, hands out one token at a time through
# next_token() (`token`, `position`), and decodes a string token into
# its bytes. invalid() exits 1 — the walker's only failure path.
# Run under LC_ALL=C so every string operation counts bytes, not
# characters. POSIX awk keeps this usable on stock macOS as well as Linux.

{ document = document $0 "\n" }

function invalid() { exit 1 }

# Consume a token, preserving quoted strings so punctuation in a finding's
# prose cannot affect the grammar. JSON permits only these four whitespace
# characters, these escapes, and unescaped bytes above the control range.
function next_token(    rest) {
    rest = substr(document, position)
    if (match(rest, /^[ \t\r\n]+/)) {
        position += RLENGTH
        rest = substr(rest, RLENGTH + 1)
    }
    if (rest == "") { token = ""; return }
    if (match(rest, /^"([^"\\\001-\037]|\\(["\\\/bfnrt]|u[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]))*"/) ||
        match(rest, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/) ||
        match(rest, /^(true|false|null)/) ||
        match(rest, /^[{}\[\],:]/)) {
        token = substr(rest, 1, RLENGTH)
        position += RLENGTH
        return
    }
    invalid()
}

function json_hex(digits,    n, j) {
    digits = tolower(digits)
    n = 0
    for (j = 1; j <= 4; j++)
        n = n * 16 + index("0123456789abcdef", substr(digits, j, 1)) - 1
    return n
}

# Append one code point to bytes[] as UTF-8; returns the new length.
function json_utf8(cp, bytes, n) {
    if (cp < 128) { bytes[++n] = cp; return n }
    if (cp < 2048) {
        bytes[++n] = 192 + int(cp / 64)
    } else {
        if (cp < 65536) {
            bytes[++n] = 224 + int(cp / 4096)
        } else {
            bytes[++n] = 240 + int(cp / 262144)
            bytes[++n] = 128 + int(cp / 4096) % 64
        }
        bytes[++n] = 128 + int(cp / 64) % 64
    }
    bytes[++n] = 128 + cp % 64
    return n
}

# Decode a string token (quotes included, already validated by
# next_token) into bytes[1..n] as byte values; returns n. Byte values,
# not an awk string, so an escaped NUL survives. Surrogate pairs join
# into one code point; a lone surrogate becomes U+FFFD.
function json_decode(quoted, bytes,    i, last, c, e, cp, low, n) {
    if (!json_ord_ready) {
        for (i = 1; i < 256; i++) json_ord[sprintf("%c", i)] = i
        json_ord_ready = 1
    }
    split("", bytes)
    n = 0
    last = length(quoted) - 1
    for (i = 2; i <= last; i++) {
        c = substr(quoted, i, 1)
        if (c != "\\") { bytes[++n] = json_ord[c]; continue }
        e = substr(quoted, ++i, 1)
        if (e != "u") {
            bytes[++n] = json_ord[e == "b" ? "\b" : e == "f" ? "\f" : e == "n" ? "\n" : e == "r" ? "\r" : e == "t" ? "\t" : e]
            continue
        }
        cp = json_hex(substr(quoted, i + 1, 4))
        i += 4
        if (cp >= 55296 && cp < 56320) {
            low = substr(quoted, i + 1, 2) == "\\u" ? json_hex(substr(quoted, i + 3, 4)) : -1
            if (low >= 56320 && low < 57344) {
                cp = 65536 + (cp - 55296) * 1024 + (low - 56320)
                i += 6
            } else cp = 65533
        } else if (cp >= 56320 && cp < 57344) cp = 65533
        n = json_utf8(cp, bytes, n)
    }
    return n
}
