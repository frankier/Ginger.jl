@enum TokenKind::UInt8 begin
    TEXT = 0
    EXPRESSION = 1
    STATEMENT = 2
    COMMENT = 3
    RAW = 4
end

"""
    Token

One lexed chunk. `text` is the literal text for `TEXT`, the expression source for
`EXPRESSION`, the statement source for `STATEMENT`, and the comment body for
`COMMENT`. The four flags record whitespace control: `lstrip`/`rstrip` come from
`-` markers, `lkeep`/`rkeep` from `+` markers.
"""
struct Token
    kind::TokenKind
    text::String
    pos::Pos
    lstrip::Bool
    lkeep::Bool
    rstrip::Bool
    rkeep::Bool
end

"""
    Lexer

Streaming tokenizer state. Call [`next_token!`](@ref) until it returns `nothing`.
The token stream is consumed directly by `synthesize.jl`; no segment vector is
materialized.
"""
mutable struct Lexer
    src::String
    file::String
    cfg::Config
    i::Int
    n::Int
    pending::Union{Nothing, Token}
    line_starts::Vector{Int}
end

function Lexer(src::AbstractString, file::AbstractString, cfg::Config)
    s = String(src)
    n = ncodeunits(s)
    starts = Int[1]
    j = 1
    while j <= n
        if s[j] == '\n'
            push!(starts, j + 1)
        end
        j = nextind(s, j)
    end
    return Lexer(s, String(file), cfg, 1, n, nothing, starts)
end

Base.IteratorSize(::Type{Lexer}) = Base.SizeUnknown()

function Base.iterate(lx::Lexer)
    tok = next_token!(lx)
    return tok === nothing ? nothing : (tok, nothing)
end

Base.iterate(lx::Lexer, ::Nothing) = iterate(lx)

function _pos_at(lx::Lexer, i::Int)
    k = searchsortedlast(lx.line_starts, i)
    ls = lx.line_starts[k]
    col = 1
    j = ls
    while j < i
        col += 1
        j = nextind(lx.src, j)
    end
    return Pos(lx.file, k, col, i)
end

"""
    next_token!(lx) -> Union{Token,Nothing}

Return the next token, or `nothing` at end of input. Raises
`TemplateSyntaxError` for an unterminated tag.
"""
function next_token!(lx::Lexer)
    if lx.pending !== nothing
        tok = lx.pending
        lx.pending = nothing
        return tok
    end
    lx.i > lx.n && return nothing

    tag_start, kind = _next_opener(lx)
    if tag_start === nothing
        pos = _pos_at(lx, lx.i)
        text = String(SubString(lx.src, lx.i))
        lx.i = lx.n + 1
        return Token(TEXT, text, pos, false, false, false, false)
    end

    tag, next_i = _parse_tag(lx, tag_start, kind)
    if tag.kind === STATEMENT && tag.text == "raw"
        tag, next_i = _scan_raw(lx, next_i, tag)
    end
    if tag_start > lx.i
        text_pos = _pos_at(lx, lx.i)
        text = String(SubString(lx.src, lx.i, prevind(lx.src, tag_start)))
        lx.pending = tag
        lx.i = next_i
        return Token(TEXT, text, text_pos, false, false, false, false)
    end
    lx.i = next_i
    return tag
end

"""
    _scan_raw(lx, content_start, opener) -> (Token, Int)

Scan a `{% raw %}` block. `content_start` is the index just after the opening
tag. The body up to the matching `{% endraw %}` becomes a single `RAW` token and
is never interpreted. Returns the token together with the index just after the
closing tag. Explicit `-` markers on the two tags trim the body edges; the
`trim_blocks`/`lstrip_blocks` config deliberately does not touch raw bodies.
"""
function _scan_raw(lx::Lexer, content_start::Int, opener::Token)
    j = content_start
    while true
        found = findnext(lx.cfg.statement_start, lx.src, j)
        if found === nothing
            throw(
                TemplateSyntaxError(
                    "unterminated `{% raw %}` (expected `{% endraw %}`)", opener.pos,
                ),
            )
        end
        k = first(found)
        # Only a tag whose body is exactly `endraw` closes the block; anything
        # else is literal raw text, so keep scanning just past this opener.
        if _looks_like_endraw(lx.src, k, lx.cfg.statement_start)
            closer, after = _parse_tag(lx, k, STATEMENT)
            if closer.text == "endraw"
                content = k > content_start ?
                    String(SubString(lx.src, content_start, prevind(lx.src, k))) : ""
                opener.rstrip && (content = lstrip(content))
                closer.lstrip && (content = rstrip(content))
                tok = Token(
                    RAW, content, _pos_at(lx, content_start),
                    opener.lstrip, opener.lkeep, closer.rstrip, closer.rkeep,
                )
                return tok, after
            end
        end
        j = nextind(lx.src, k)
    end
    return
end

# True when the tag beginning at `k` is `endraw`, allowing whitespace-control
# flags and surrounding whitespace. Used to tell a real `{% endraw %}` apart from
# a `{%` that is just literal raw text.
function _looks_like_endraw(s::String, k::Int, start_delim::AbstractString)
    n = ncodeunits(s)
    p = k + ncodeunits(start_delim)
    p > n && return false
    if s[p] == '-' || s[p] == '+'
        p = nextind(s, p)
    end
    while p <= n && isspace(s[p])
        p = nextind(s, p)
    end
    startswith(SubString(s, p), "endraw") || return false
    q = p + ncodeunits("endraw")
    return q > n || !(isletter(s[q]) || isdigit(s[q]) || s[q] == '_')
end

function _next_opener(lx::Lexer)
    best = 0
    bestkind = TEXT
    for (kind, delim) in (
            (EXPRESSION, lx.cfg.expression_start),
            (STATEMENT, lx.cfg.statement_start),
            (COMMENT, lx.cfg.comment_start),
        )
        match = findnext(delim, lx.src, lx.i)
        if match !== nothing
            j = first(match)
            if best == 0 || j < best
                best = j
                bestkind = kind
            end
        end
    end
    return best == 0 ? (nothing, TEXT) : (best, bestkind)
end

function _delimiter(cfg::Config, kind::TokenKind)
    if kind === EXPRESSION
        return cfg.expression_start, cfg.expression_end
    elseif kind === STATEMENT
        return cfg.statement_start, cfg.statement_end
    else
        return cfg.comment_start, cfg.comment_end
    end
end

function _parse_tag(lx::Lexer, start::Int, kind::TokenKind)
    opener, closer = _delimiter(lx.cfg, kind)
    p = start + ncodeunits(opener)
    lstrip = false
    lkeep = false
    if p <= lx.n
        c = lx.src[p]
        if c == '-'
            lstrip = true
            p = nextind(lx.src, p)
        elseif c == '+'
            lkeep = true
            p = nextind(lx.src, p)
        end
    end

    close = kind === COMMENT ? _scan_comment_body(lx.src, p, opener, closer) :
        _scan_tag_body(lx.src, p, closer)
    if close === nothing
        throw(TemplateSyntaxError("unterminated `$opener` tag", _pos_at(lx, start)))
    end

    content_end = prevind(lx.src, close)
    rstrip = false
    rkeep = false
    if content_end >= p
        c = lx.src[content_end]
        if c == '-'
            rstrip = true
            content_end = prevind(lx.src, content_end)
        elseif c == '+'
            rkeep = true
            content_end = prevind(lx.src, content_end)
        end
    end

    content = content_end >= p ? strip(SubString(lx.src, p, content_end)) : ""
    return Token(kind, String(content), _pos_at(lx, start), lstrip, lkeep, rstrip, rkeep),
        close + ncodeunits(closer)
end

_match_at(s::String, i::Int, needle::AbstractString) =
    i <= ncodeunits(s) && startswith(SubString(s, i), needle)

"""
Find the closing delimiter of a `{{ }}` or `{% %}` tag, skipping Julia strings,
char literals, backtick commands, comments, and balanced brackets so that a
delimiter inside them does not terminate the tag.
"""
function _scan_tag_body(s::String, p::Int, closer::AbstractString)
    n = ncodeunits(s)
    depth = 0
    j = p
    while j <= n
        depth == 0 && _match_at(s, j, closer) && return j
        c = s[j]
        if c == '"'
            j = _skip_string(s, j)
        elseif c == '\''
            j = _skip_char_or_adjoint(s, j)
        elseif c == '`'
            j = _skip_backtick(s, j)
        elseif c == '#'
            j = _skip_comment(s, j)
        elseif c == '(' || c == '[' || c == '{'
            depth += 1
            j = nextind(s, j)
        elseif c == ')' || c == ']' || c == '}'
            depth = depth > 0 ? depth - 1 : 0
            j = nextind(s, j)
        else
            j = nextind(s, j)
        end
    end
    return nothing
end

"""
Find the end of a comment tag. Comment bodies are not Julia code, so only nested
`{#`/`#}` pairs matter.
"""
function _scan_comment_body(s::String, p::Int, opener::AbstractString, closer::AbstractString)
    n = ncodeunits(s)
    depth = 1
    j = p
    while j <= n
        if opener != closer && _match_at(s, j, opener)
            depth += 1
            j += ncodeunits(opener)
        elseif _match_at(s, j, closer)
            depth -= 1
            depth == 0 && return j
            j += ncodeunits(closer)
        else
            j = nextind(s, j)
        end
    end
    return nothing
end

# Skip a `"`-delimited string (single or triple quoted), including `$(...)`
# interpolations, which may themselves contain strings.
function _skip_string(s::String, i::Int)
    n = ncodeunits(s)
    triple = _match_at(s, i, "\"\"\"")
    j = triple ? i + 3 : i + 1
    while j <= n
        c = s[j]
        if c == '\\'
            k = nextind(s, j)
            j = k <= n ? nextind(s, k) : k
        elseif c == '$' && _match_at(s, nextind(s, j), "(")
            j = _skip_balanced(s, nextind(s, j))
        elseif triple
            _match_at(s, j, "\"\"\"") && return j + 3
            j = nextind(s, j)
        elseif c == '"'
            return nextind(s, j)
        else
            j = nextind(s, j)
        end
    end
    return n + 1
end

function _skip_backtick(s::String, i::Int)
    n = ncodeunits(s)
    j = i + 1
    while j <= n
        c = s[j]
        if c == '\\'
            k = nextind(s, j)
            j = k <= n ? nextind(s, k) : k
        elseif c == '$' && _match_at(s, nextind(s, j), "(")
            j = _skip_balanced(s, nextind(s, j))
        elseif c == '`'
            return nextind(s, j)
        else
            j = nextind(s, j)
        end
    end
    return n + 1
end

# Skip a bracketed run. `i` must point at `(`; returns the index after the
# matching `)`.
function _skip_balanced(s::String, i::Int)
    n = ncodeunits(s)
    depth = 0
    j = i
    while j <= n
        c = s[j]
        if c == '"'
            j = _skip_string(s, j)
        elseif c == '\''
            j = _skip_char_or_adjoint(s, j)
        elseif c == '`'
            j = _skip_backtick(s, j)
        elseif c == '#'
            j = _skip_comment(s, j)
        elseif c == '(' || c == '[' || c == '{'
            depth += 1
            j = nextind(s, j)
        elseif c == ')' || c == ']' || c == '}'
            depth -= 1
            j = nextind(s, j)
            depth == 0 && return j
        else
            j = nextind(s, j)
        end
    end
    return n + 1
end

# A `'` is ambiguous: `'a'` is a char literal, `A'` is adjoint. Treat it as a
# char literal only when a plausible closing quote follows; otherwise consume it
# as an operator.
function _skip_char_or_adjoint(s::String, i::Int)
    n = ncodeunits(s)
    j = nextind(s, i)
    j > n && return j
    if s[j] == '\\'
        escaped = nextind(s, j)
        escaped > n && return n + 1
        closing = nextind(s, escaped)
        return closing <= n && s[closing] == '\'' ? nextind(s, closing) : nextind(s, i)
    end
    closing = nextind(s, j)
    return closing <= n && s[closing] == '\'' ? nextind(s, closing) : nextind(s, i)
end

# Skip a line comment or a nestable `#= =#` block comment. A line comment returns
# the index of its terminating newline (or end of input).
function _skip_comment(s::String, i::Int)
    n = ncodeunits(s)
    if _match_at(s, i, "#=")
        depth = 0
        j = i
        while j <= n
            if _match_at(s, j, "#=")
                depth += 1
                j += 2
            elseif _match_at(s, j, "=#")
                depth -= 1
                j += 2
                depth == 0 && return j
            else
                j = nextind(s, j)
            end
        end
        return n + 1
    end
    j = i
    while j <= n && s[j] != '\n'
        j = nextind(s, j)
    end
    return j
end
