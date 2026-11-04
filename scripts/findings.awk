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
# Opt-in variables (orca.sh rounds uses them):
#   -v response=1        the document is an implementer's response and
#                        must be a complete one, each required key
#                        exactly once: checks{commands: array of
#                        strings, pass: boolean, failure: string},
#                        findings, followups (array of objects, each
#                        with title (string), file (string or null),
#                        and why (string), each once), status (done |
#                        needs_input | infeasible), questions (array of
#                        strings), optionally tree (a 40- or
#                        64-hex-digit tree id, at most once),
#                        and every findings entry title (string), file
#                        (string or null), outcome (fixed | disputed |
#                        declined | out_of_scope), reason (string).
#                        Anything less exits 1 with no output. One
#                        `pass<TAB>true|false<TAB>failure.b64<TAB>status<TAB>tree`
#                        line (tree empty when absent) prints ahead of
#                        the rows.
#   -v plain_title=1     the title column is plain text like file
#                        (control bytes as spaces) instead of base64 —
#                        a matching key, never for display.
#   -v severity_name=1   a sixth column names the severity: critical,
#                        high, medium, or low under the same trimming
#                        and case rule, anything else unknown.
#   -v details=1         with response=1: each row gains a last column,
#                        its reason, and after the rows come one
#                        `command<TAB><text>` per checks.commands entry
#                        and one `followup<TAB><title><TAB><file><TAB><why>`
#                        per followups entry — all plain text.
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
# The lower-cased word, or empty when it cannot be one.
function severity_word(quoted,    bytes, n, first, last, i, severity) {
    if (substr(quoted, 1, 1) != "\"") return ""
    n = json_decode(quoted, bytes)
    for (first = 1; first <= n && is_json_space(bytes[first]); first++) ;
    for (last = n; last >= first && is_json_space(bytes[last]); last--) ;
    severity = ""
    for (i = first; i <= last; i++) {
        if (bytes[i] < 32) return ""
        severity = severity sprintf("%c", bytes[i])
    }
    return tolower(severity)
}

function gating_class(quoted,    severity) {
    severity = severity_word(quoted)
    return severity == "medium" || severity == "low" ? severity : "gating"
}

function severity_label(quoted,    severity) {
    severity = severity_word(quoted)
    return severity ~ /^(critical|high|medium|low)$/ ? severity : "unknown"
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
# last one wins, as in jq), skip everything else. In a response, each
# disposition must carry title (string), file (string or null), outcome
# (fixed, disputed, declined, or out_of_scope), and reason (string),
# each exactly once.
function entry(    field, key, row, title, seen) {
    if (token != "{") invalid()
    split("", field)
    split("", seen)
    next_token()
    if (token != "}") {
        while (1) {
            if (substr(token, 1, 1) != "\"") invalid()
            key = plain_text(token)
            next_token()
            if (token != ":") invalid()
            next_token()
            if (response && key ~ /^(title|outcome|reason)$/) require_key(key, "string", seen)
            else if (response && key == "file") require_key(key, "string null", seen)
            if (key ~ /^(severity|fix_location|file|outcome|title|reason)$/) field[key] = token
            skip_value(2)
            if (token == "}") break
            if (token != ",") invalid()
            next_token()
        }
    }
    next_token()
    if (response) {
        require_all("title file outcome reason", seen)
        if (plain_text(field["outcome"]) !~ /^(fixed|disputed|declined|out_of_scope)$/) invalid()
    }
    row = gating_class(field["severity"])
    row = row "\t" plain_text(string_or_empty("fix_location", field))
    row = row "\t" plain_text(string_or_empty("file", field))
    row = row "\t" plain_text(string_or_empty("outcome", field))
    title = string_or_empty("title", field)
    row = row "\t" (plain_title ? plain_text(title) : base64(title))
    if (severity_name) row = row "\t" severity_label(field["severity"])
    if (details) row = row "\t" plain_text(string_or_empty("reason", field))
    rows[++row_count] = row
}

function json_type(t,    c) {
    c = substr(t, 1, 1)
    if (c == "{") return "object"
    if (c == "[") return "array"
    if (c == "\"") return "string"
    if (t == "true" || t == "false") return "boolean"
    if (t == "null") return "null"
    return "number"
}

# A response's required key, at the value's first token: present once,
# its value one of the space-separated JSON types.
function require_key(name, types, seen) {
    if (name in seen) invalid()
    seen[name] = 1
    if (index(" " types " ", " " json_type(token) " ") == 0) invalid()
}

function require_all(names, seen,    list, n, i) {
    n = split(names, list, " ")
    for (i = 1; i <= n; i++)
        if (!(list[i] in seen)) invalid()
}

# A response's checks object: commands an array of strings, pass a boolean,
# failure a string, each exactly once; any other key is skipped.
function checks(    key, seen) {
    if (token != "{") invalid()
    split("", seen)
    next_token()
    if (token != "}") {
        while (1) {
            if (substr(token, 1, 1) != "\"") invalid()
            key = plain_text(token)
            next_token()
            if (token != ":") invalid()
            next_token()
            if (key == "commands") { require_key(key, "array", seen); string_array(details ? "command" : ""); }
            else {
                if (key == "pass") { require_key(key, "boolean", seen); checks_pass = token }
                else if (key == "failure") { require_key(key, "string", seen); checks_failure = token }
                skip_value(2)
            }
            if (token == "}") break
            if (token != ",") invalid()
            next_token()
        }
    }
    next_token()
    require_all("commands pass failure", seen)
}

# A response's array of strings (checks.commands, questions), at its
# opening bracket: every element a string, kept as a <kind> line when
# <kind> is given.
function string_array(kind) {
    if (token != "[") invalid()
    next_token()
    if (token == "]") { next_token(); return }
    while (1) {
        if (json_type(token) != "string") invalid()
        if (kind != "") extra[++extra_count] = kind "\t" plain_text(token)
        next_token()
        if (token == "]") { next_token(); return }
        if (token != ",") invalid()
        next_token()
    }
}

# A response's followups array: every element an object with title
# (string), file (string or null), and why (string), each exactly once;
# any other key is skipped.
function followups(    key, seen, field) {
    if (token != "[") invalid()
    next_token()
    if (token == "]") { next_token(); return }
    while (1) {
        if (token != "{") invalid()
        split("", seen)
        split("", field)
        next_token()
        if (token != "}") {
            while (1) {
                if (substr(token, 1, 1) != "\"") invalid()
                key = plain_text(token)
                next_token()
                if (token != ":") invalid()
                next_token()
                if (key ~ /^(title|why)$/) require_key(key, "string", seen)
                else if (key == "file") require_key(key, "string null", seen)
                if (key ~ /^(title|file|why)$/) field[key] = token
                skip_value(3)
                if (token == "}") break
                if (token != ",") invalid()
                next_token()
            }
        }
        next_token()
        require_all("title file why", seen)
        if (details) extra[++extra_count] = "followup\t" plain_text(string_or_empty("title", field)) "\t" \
            plain_text(string_or_empty("file", field)) "\t" plain_text(string_or_empty("why", field))
        if (token == "]") { next_token(); return }
        if (token != ",") invalid()
        next_token()
    }
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
    split("", top)
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
            } else if (response && key == "checks") {
                require_key(key, "object", top)
                checks()
            } else {
                if (response && key == "questions") { require_key(key, "array", top); string_array() }
                else if (response && key == "followups") { require_key(key, "array", top); followups() }
                else {
                    if (response && key == "status") {
                        require_key(key, "string", top)
                        status = plain_text(token)
                        if (status !~ /^(done|needs_input|infeasible)$/) invalid()
                    } else if (response && key == "tree") {
                        require_key(key, "string", top)
                        tree = plain_text(token)
                        if (tree !~ /^[0-9a-f]+$/ || (length(tree) != 40 && length(tree) != 64)) invalid()
                    }
                    skip_value(1)
                }
            }
            if (token == "}") break
            if (token != ",") invalid()
            next_token()
        }
    }
    next_token()
    if (token != "" || !found_findings) invalid()
    if (response) {
        require_all("checks followups status questions", top)
        print "pass\t" checks_pass "\t" base64(checks_failure) "\t" status "\t" tree
    }
    for (i = 1; i <= row_count; i++) print rows[i]
    for (i = 1; i <= extra_count; i++) print extra[i]
}
