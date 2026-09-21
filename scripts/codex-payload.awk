# Validate one complete JSON object with a top-level findings array.
# Exit status only: never rewrite the payload or interpret finding counts.
# POSIX awk keeps this usable on stock macOS as well as Linux.

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

# Recognize the root key even when its ASCII letters use Unicode escapes.
# Other keys need no decoding: their contents do not affect validation.
function is_findings(quoted,    i, c, hex, n, j, key) {
    for (i = 2; i < length(quoted); i++) {
        c = substr(quoted, i, 1)
        if (c == "\\") {
            if (substr(quoted, i + 1, 1) != "u") return 0
            hex = tolower(substr(quoted, i + 2, 4))
            n = 0
            for (j = 1; j <= 4; j++)
                n = n * 16 + index("0123456789abcdef", substr(hex, j, 1)) - 1
            if (n > 127) return 0
            c = sprintf("%c", n)
            i += 5
        }
        key = key c
    }
    return key == "findings"
}

function value(depth,    closing, object, finding) {
    # Findings are shallow; bound recursion for corrupt/unexpected input.
    if (depth > 128) invalid()
    if (token == "{" || token == "[") {
        object = token == "{"
        closing = object ? "}" : "]"
        next_token()
        if (token == closing) { next_token(); return }
        while (1) {
            finding = 0
            if (object) {
                if (substr(token, 1, 1) != "\"") invalid()
                finding = depth == 0 && is_findings(token)
                next_token()
                if (token != ":") invalid()
                next_token()
                if (finding) {
                    if (found_findings || token != "[") invalid()
                    found_findings = 1
                }
            }
            value(depth + 1)
            if (token == closing) { next_token(); return }
            if (token != ",") invalid()
            next_token()
        }
    }
    if (token == "" || token ~ /^[}\],:]$/) invalid()
    next_token()
}

END {
    position = 1
    next_token()
    if (token != "{") invalid()
    value(0)
    if (token != "" || !found_findings) invalid()
}
