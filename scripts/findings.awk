# Turn the top-level findings array of a review (round-<N>.json:
# severity, file, line, title, body, fix_location) or of an implementer's
# response (findings[{title, file, outcome, reason}]) into one TSV row
# per entry:
#
#   severity <TAB> fix_location <TAB> file <TAB> outcome <TAB> title.b64
#
# severity is gating | medium | low — the reviewers' count rule: only a
# severity that is, case-insensitively and trimmed of JSON whitespace,
# exactly `medium` or `low` keeps its name; anything else, missing
# included, gates. Every other
# missing or non-string field is empty; control bytes in the plain
# columns become spaces so a row stays one line of five columns. The
# title crosses base64-encoded, byte for byte.
#
# The whole document is validated before any row is printed: malformed
# or truncated JSON, a NUL byte or malformed UTF-8 anywhere in the
# file, a missing or
# repeated findings key, or an entry that is not an object exits 1 with
# no output. The input must be a file operand (the NUL check re-reads
# it), never stdin.
#
# Loads after the shared tokenizer, under LC_ALL=C:
#   LC_ALL=C awk -f json-tokens.awk -f findings.awk <file>

function skip_value(depth,    closing, object) {
    # Findings are shallow; bound recursion for corrupt/unexpected input.
    if (depth > 128) invalid()
    if (token == "{" || token == "[") {
        object = token == "{"
        closing = object ? "}" : "]"
        next_token()
        if (token == closing) { next_token(); return }
        while (1) {
            if (object) {
                if (substr(token, 1, 1) != "\"") invalid()
                next_token()
                if (token != ":") invalid()
                next_token()
            }
            skip_value(depth + 1)
            if (token == closing) { next_token(); return }
            if (token != ",") invalid()
            next_token()
        }
    }
    if (token == "" || token ~ /^[}\],:]$/) invalid()
    next_token()
}

# The plain-column text of a string token: its decoded bytes, with every
# control byte (tab and newline included) turned into a space.
function plain_text(quoted,    bytes, n, i, text) {
    n = json_decode(quoted, bytes)
    text = ""
    for (i = 1; i <= n; i++)
        text = text (bytes[i] < 32 ? " " : sprintf("%c", bytes[i]))
    return text
}

function base64(quoted,    bytes, n, i, a, b, c, out, alphabet) {
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    n = json_decode(quoted, bytes)
    out = ""
    for (i = 1; i <= n; i += 3) {
        a = bytes[i]
        b = i + 1 <= n ? bytes[i + 1] : 0
        c = i + 2 <= n ? bytes[i + 2] : 0
        out = out substr(alphabet, int(a / 4) + 1, 1)
        out = out substr(alphabet, (a % 4) * 16 + int(b / 16) + 1, 1)
        out = out (i + 1 <= n ? substr(alphabet, (b % 16) * 4 + int(c / 64) + 1, 1) : "=")
        out = out (i + 2 <= n ? substr(alphabet, c % 64 + 1, 1) : "=")
    }
    return out
}

function is_json_space(byte) {
    return byte == 32 || byte == 9 || byte == 10 || byte == 13
}

# Trim JSON whitespace only and keep every other byte: a control byte
# (NUL included) left inside makes the severity unrecognized, so it gates.
function gating_class(quoted,    bytes, n, first, last, i, severity) {
    if (substr(quoted, 1, 1) != "\"") return "gating"
    n = json_decode(quoted, bytes)
    for (first = 1; first <= n && is_json_space(bytes[first]); first++) ;
    for (last = n; last >= first && is_json_space(bytes[last]); last--) ;
    severity = ""
    for (i = first; i <= last; i++) {
        if (bytes[i] < 32) return "gating"
        severity = severity sprintf("%c", bytes[i])
    }
    severity = tolower(severity)
    return severity == "medium" || severity == "low" ? severity : "gating"
}

# awk cannot see a NUL byte: stock macOS awk drops the rest of its line,
# so a document could validate as a prefix of the file. Count NULs with
# tr instead; a file that cannot be re-read counts as one.
FNR == 1 { input_files[++input_count] = FILENAME }

function nul_free(file,    quoted, command, count) {
    if (file == "" || file == "-") return 0
    quoted = file
    gsub(/'/, "'\\''", quoted)
    command = "(LC_ALL=C tr -cd '\\000' <'" quoted "' || echo unreadable) | wc -c"
    count = ""
    command | getline count
    close(command)
    return count != "" && count + 0 == 0
}

function inputs_nul_free(    i) {
    if (input_count == 0) return 0
    for (i = 1; i <= input_count; i++)
        if (!nul_free(input_files[i])) return 0
    return 1
}

# Every byte of the document must be well-formed UTF-8 (RFC 3629): no
# stray continuation byte, truncated sequence, overlong form, UTF-16
# surrogate, or code point above U+10FFFF. One anchored regex over the
# byte ranges, so the scan stays linear (NUL is already excluded).
function utf8_valid(text) {
    return text ~ /^([\001-\177]|[\302-\337][\200-\277]|\340[\240-\277][\200-\277]|[\341-\354\356\357][\200-\277][\200-\277]|\355[\200-\237][\200-\277]|\360[\220-\277][\200-\277][\200-\277]|[\361-\363][\200-\277][\200-\277][\200-\277]|\364[\200-\217][\200-\277][\200-\277])*$/
}

function string_or_empty(name, field) {
    return substr(field[name], 1, 1) == "\"" ? field[name] : ""
}

# One findings entry: keep the string token of each column's key (the
# last one wins, as in jq), skip everything else.
function entry(    field, key, row) {
    if (token != "{") invalid()
    split("", field)
    next_token()
    if (token != "}") {
        while (1) {
            if (substr(token, 1, 1) != "\"") invalid()
            key = plain_text(token)
            next_token()
            if (token != ":") invalid()
            next_token()
            if (key ~ /^(severity|fix_location|file|outcome|title)$/) field[key] = token
            skip_value(2)
            if (token == "}") break
            if (token != ",") invalid()
            next_token()
        }
    }
    next_token()
    row = gating_class(field["severity"])
    row = row "\t" plain_text(string_or_empty("fix_location", field))
    row = row "\t" plain_text(string_or_empty("file", field))
    row = row "\t" plain_text(string_or_empty("outcome", field))
    row = row "\t" base64(string_or_empty("title", field))
    rows[++row_count] = row
}

function entries() {
    if (token != "[") invalid()
    next_token()
    if (token == "]") { next_token(); return }
    while (1) {
        entry()
        if (token == "]") { next_token(); return }
        if (token != ",") invalid()
        next_token()
    }
}

END {
    if (!inputs_nul_free() || !utf8_valid(document)) invalid()
    position = 1
    next_token()
    if (token != "{") invalid()
    next_token()
    if (token != "}") {
        while (1) {
            if (substr(token, 1, 1) != "\"") invalid()
            key = plain_text(token)
            next_token()
            if (token != ":") invalid()
            next_token()
            if (key == "findings") {
                if (found_findings) invalid()
                found_findings = 1
                entries()
            } else skip_value(1)
            if (token == "}") break
            if (token != ",") invalid()
            next_token()
        }
    }
    next_token()
    if (token != "" || !found_findings) invalid()
    for (i = 1; i <= row_count; i++) print rows[i]
}
