"""
    MapEntry

A byte range `[out_start, out_end]` of the synthetic Julia source (0-based, as
returned by `position`) together with the template position it came from. One
entry is recorded per synthetic line.
"""
struct MapEntry
    out_start::Int
    out_end::Int
    pos::Pos
end

"""
    OffsetMap

The synthetic-source to template-source offset map, built in the same pass as
the synthetic source. `entries` is indexed by synthetic line number.
"""
struct OffsetMap
    entries::Vector{MapEntry}
end

"""
    Synthesis(source, map)

The synthetic Julia source for one template plus its offset map.
"""
struct Synthesis
    source::String
    map::OffsetMap
end

# Julia block keywords the template-level scanner tracks. Only constructs that
# span more than one `{% %}` tag matter: a tag that opens and closes its own
# block is emitted verbatim and never changes the stack.
const _STRUCT_KEYWORDS = Set{String}(
    [
        "if", "elseif", "else", "for", "while", "let", "begin", "end",
        "try", "catch", "finally", "function", "quote", "do", "struct",
        "module", "baremodule", "macro", "abstract", "primitive", "type",
        "endif", "endfor", "endwhile", "endlet", "endblock", "endmacro",
    ]
)

const _STRUCT_OPENERS = Set{String}(
    [
        "if", "for", "while", "let", "begin", "try", "function", "quote",
        "struct", "module", "baremodule", "abstract", "primitive",
    ]
)

const _STRUCT_CONTINUATIONS = Set{String}(["else", "elseif", "catch", "finally"])

# `end*` aliases all translate to `end`. Alias-name mismatch is not verified;
# the frame that is popped decides the emitted structure.
const _END_ALIASES = Set{String}(
    ["end", "endif", "endfor", "endwhile", "endlet", "endblock", "endmacro"]
)

# A tracked, still-open template-level block.
mutable struct _Frame
    kind::Symbol
    pos::Pos
    ran::Union{Nothing, Symbol} # lowering flag for `{% for %}`, else `nothing`
    has_else::Bool
end

# Synthesis state for template-only structure. Julia's parser remains the
# authority on matching; the stack exists so `{% for %}…{% else %}` can be
# lowered and so unclosed blocks get a clear diagnostic.
mutable struct _SynthState
    stack::Vector{_Frame}
    loops::Int
end

_SynthState() = _SynthState(_Frame[], 0)

"""
    synthesize(src, virtual_path, cfg) -> Synthesis

Consume the token stream and build synthetic Julia source plus its offset map.
Text becomes a `print` call, expressions become `__ginger_print__` calls, and
statements are emitted mostly verbatim. Two transformations happen here:

- `{% for x in it %}…{% else %}…{% endfor %}` is lowered to a `let`-scoped
  `ran_any` flag, a `for` loop, and a trailing `if` for the `else` body, because
  Julia has no `for`/`else`.
- `end*` aliases (`endif`, `endfor`, …) become `end`.

Whitespace control is applied here, where the preceding and following text
chunks are known.
"""
function synthesize(src::AbstractString, virtual_path::AbstractString, cfg::Config)
    lx = Lexer(src, virtual_path, cfg)
    buf = IOBuffer()
    entries = MapEntry[]
    state = _SynthState()
    strip_next = :none
    pending = nothing # pending TEXT token: (text, pos)
    while true
        tok = next_token!(lx)
        tok === nothing && break
        if tok.kind === TEXT
            text = tok.text
            if strip_next === :all
                text = lstrip(text)
            elseif strip_next === :newline
                text = _strip_one_newline(text)
            end
            strip_next = :none
            pending = pending === nothing ? (text, tok.pos) : (pending[1] * text, pending[2])
        else
            if pending !== nothing
                text, pos = pending
                pending = nothing
                text = _apply_left_strip(text, tok, cfg)
                _emit_text!(buf, entries, text, pos)
            end
            if tok.kind === RAW
                text = tok.text
                if strip_next === :all
                    text = lstrip(text)
                elseif strip_next === :newline
                    text = _strip_one_newline(text)
                end
                _emit_text!(buf, entries, text, tok.pos)
            elseif tok.kind === EXPRESSION
                _emit_chunk!(buf, entries, string("__ginger_print__(", tok.text, ')'), tok.pos)
            elseif tok.kind === STATEMENT
                _emit_statement!(buf, entries, tok, state)
            end
            strip_next = _right_strip_mode(tok, cfg)
        end
    end
    if pending !== nothing
        text, pos = pending
        _emit_text!(buf, entries, text, pos)
    end
    if !isempty(state.stack)
        frame = state.stack[end]
        throw(TemplateSyntaxError("unclosed `{% $(frame.kind) %}`", frame.pos))
    end
    return Synthesis(String(take!(buf)), OffsetMap(entries))
end

# --- statement lowering -----------------------------------------------------

"""
    _emit_statement!(buf, entries, tok, state)

Emit one `{% %}` statement, updating the template-level structure stack. A
statement that opens a tracked block extends the stack; a closer pops it and
emits the `end` (or `end`/`end` pair) that closes the lowered shape.
"""
function _emit_statement!(buf::IOBuffer, entries::Vector{MapEntry}, tok::Token, state::_SynthState)
    text = tok.text
    isempty(text) && return nothing
    leading = _leading_keyword(text)
    keywords = _top_level_keywords(text)

    if leading == "macro"
        _emit_macro_opener!(buf, entries, tok, state)
    elseif leading == "include"
        _emit_include!(buf, entries, tok)
    elseif leading == "import"
        _emit_import!(buf, entries, tok)
    elseif leading == "from"
        _emit_fromimport!(buf, entries, tok)
    elseif leading !== nothing && leading in _END_ALIASES && length(keywords) == 1
        _emit_closer!(buf, entries, tok.pos, state)
    elseif leading !== nothing && leading in _STRUCT_CONTINUATIONS
        _emit_continuation!(buf, entries, tok, leading, keywords, state)
    elseif leading !== nothing && leading in _STRUCT_OPENERS && !("end" in keywords)
        _emit_opener!(buf, entries, tok, Symbol(leading), state)
    elseif "do" in keywords && !("end" in keywords)
        push!(state.stack, _Frame(:do, tok.pos, nothing, false))
        _emit_chunk!(buf, entries, text, tok.pos)
    else
        _emit_chunk!(buf, entries, text, tok.pos)
    end
    return nothing
end

function _emit_closer!(buf::IOBuffer, entries::Vector{MapEntry}, pos::Pos, state::_SynthState)
    if isempty(state.stack)
        # Unmatched close: let Julia report the structure error at this offset.
        _emit_chunk!(buf, entries, "end", pos)
        return nothing
    end
    frame = pop!(state.stack)
    if frame.kind === :for
        # Close the `for` (or the `else` `if`), then close the `let`.
        _emit_chunk!(buf, entries, "end", pos)
        _emit_chunk!(buf, entries, "end", pos)
    elseif frame.kind === :macro
        # Close the lambda body opened by `{% macro %}`.
        _emit_chunk!(buf, entries, "end)", pos)
    else
        _emit_chunk!(buf, entries, "end", pos)
    end
    return nothing
end

function _emit_continuation!(buf::IOBuffer, entries::Vector{MapEntry}, tok::Token, leading::String, keywords::Vector{String}, state::_SynthState)
    if leading == "else" && !isempty(state.stack) && state.stack[end].kind === :for &&
            !state.stack[end].has_else && length(keywords) == 1
        frame = state.stack[end]
        frame.has_else = true
        _emit_chunk!(buf, entries, "end", tok.pos)          # close the `for`
        _emit_chunk!(buf, entries, string("if !", frame.ran), tok.pos)
    else
        _emit_chunk!(buf, entries, tok.text, tok.pos)
    end
    return nothing
end

function _emit_opener!(buf::IOBuffer, entries::Vector{MapEntry}, tok::Token, kind::Symbol, state::_SynthState)
    if kind === :for
        state.loops += 1
        ran = Symbol("__ginger_ran_", state.loops, "__")
        push!(state.stack, _Frame(:for, tok.pos, ran, false))
        _emit_chunk!(buf, entries, string("let ", ran, " = false"), tok.pos)
        _emit_chunk!(buf, entries, tok.text, tok.pos)
        _emit_chunk!(buf, entries, string(ran, " = true"), tok.pos)
    else
        push!(state.stack, _Frame(kind, tok.pos, nothing, false))
        _emit_chunk!(buf, entries, tok.text, tok.pos)
    end
    return nothing
end

# --- template-only tags -----------------------------------------------------

function _emit_macro_opener!(buf::IOBuffer, entries::Vector{MapEntry}, tok::Token, state::_SynthState)
    isempty(state.stack) || throw(
        TemplateSyntaxError("`{% macro %}` must appear at the top level", tok.pos),
    )
    sig = _macro_signature(_after_keyword(tok.text, "macro"))
    sig === nothing && throw(TemplateSyntaxError("invalid `{% macro %}` tag", tok.pos))
    name, params = sig
    push!(state.stack, _Frame(:macro, tok.pos, nothing, false))
    _emit_chunk!(buf, entries, string("__ginger_macro__(:", name, ", (", params, ") -> begin"), tok.pos)
    return nothing
end

function _emit_include!(buf::IOBuffer, entries::Vector{MapEntry}, tok::Token)
    rest = _after_keyword(tok.text, "include")
    split = _split_top_level(rest, "with")
    chunk = if split === nothing
        string("__ginger_include__(", strip(rest), ')')
    else
        left, right = split
        string("__ginger_include__(", strip(left), "; ", strip(right), ')')
    end
    _emit_chunk!(buf, entries, chunk, tok.pos)
    return nothing
end

function _emit_import!(buf::IOBuffer, entries::Vector{MapEntry}, tok::Token)
    rest = _after_keyword(tok.text, "import")
    split = _split_top_level(rest, "as")
    split === nothing && throw(
        TemplateSyntaxError("invalid `{% import %}` tag: expected `as`", tok.pos),
    )
    path, alias = strip(split[1]), strip(split[2])
    _valid_identifier(alias) || throw(TemplateSyntaxError("invalid `{% import %}` alias", tok.pos))
    _emit_chunk!(buf, entries, string("__ginger_import__(:", alias, ", ", path, ')'), tok.pos)
    return nothing
end

function _emit_fromimport!(buf::IOBuffer, entries::Vector{MapEntry}, tok::Token)
    rest = _after_keyword(tok.text, "from")
    split = _split_top_level(rest, "import")
    split === nothing && throw(
        TemplateSyntaxError("invalid `{% from %}` tag: expected `import`", tok.pos),
    )
    path, names = strip(split[1]), split[2]
    pairs = String[]
    for item in _split_top_level_commas(names)
        item = strip(item)
        isempty(item) && continue
        as = _split_top_level(item, "as")
        local_name, remote = as === nothing ? (item, item) : (strip(as[2]), strip(as[1]))
        (_valid_identifier(local_name) && _valid_identifier(remote)) || throw(
            TemplateSyntaxError("invalid `{% from %}` import name", tok.pos),
        )
        push!(pairs, string(local_name, " = :", remote))
    end
    isempty(pairs) && throw(TemplateSyntaxError("`{% from %}` imports no names", tok.pos))
    chunk = string("__ginger_fromimport__(", path, ", (", join(pairs, ", "), ",))")
    _emit_chunk!(buf, entries, chunk, tok.pos)
    return nothing
end

function _after_keyword(text::AbstractString, kw::AbstractString)
    s = String(text)
    return strip(SubString(s, nextind(s, firstindex(s), ncodeunits(kw))))
end

_valid_identifier(s::AbstractString) = occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", s)

# `name`, `name(params)`, or `name()`. Returns `(name, params)` with `params`
# empty for the first form, or `nothing` when the signature is malformed.
function _macro_signature(rest::AbstractString)
    s = strip(rest)
    isempty(s) && return nothing
    open = findfirst('(', s)
    open === nothing && return _valid_identifier(s) ? (String(s), "") : nothing
    open == firstindex(s) && return nothing
    name = strip(SubString(s, firstindex(s), prevind(s, open)))
    _valid_identifier(name) || return nothing
    close = findlast(')', s)
    (close === nothing || close < open) && return nothing
    params = strip(SubString(s, nextind(s, open), prevind(s, close)))
    return String(name), String(params)
end

# Find `word` at the top level (outside strings, brackets, and comments) and
# split around it. Returns `(left, right)` or `nothing`.
function _split_top_level(s::AbstractString, word::AbstractString)
    s = String(s)
    n = ncodeunits(s)
    depth = 0
    j = firstindex(s)
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
            depth = max(depth - 1, 0)
            j = nextind(s, j)
        elseif depth == 0 && (isletter(c) || c == '_')
            k = j
            while k <= n && (isletter(s[k]) || isdigit(s[k]) || s[k] == '_')
                k = nextind(s, k)
            end
            if String(SubString(s, j, prevind(s, k))) == word
                before_ok = j == firstindex(s) || isspace(s[prevind(s, j)])
                after_ok = k > n || isspace(s[k])
                if before_ok && after_ok
                    left = String(SubString(s, firstindex(s), prevind(s, j)))
                    right = k > n ? "" : String(SubString(s, k, lastindex(s)))
                    return left, right
                end
            end
            j = k
        else
            j = nextind(s, j)
        end
    end
    return nothing
end

function _split_top_level_commas(s::AbstractString)
    s = String(s)
    n = ncodeunits(s)
    parts = String[]
    depth = 0
    start = firstindex(s)
    j = firstindex(s)
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
            depth = max(depth - 1, 0)
            j = nextind(s, j)
        elseif c == ',' && depth == 0
            push!(parts, j == start ? "" : String(SubString(s, start, prevind(s, j))))
            j = nextind(s, j)
            start = j
        else
            j = nextind(s, j)
        end
    end
    start <= n && push!(parts, String(SubString(s, start)))
    return parts
end

"""
    _leading_keyword(text) -> Union{String,Nothing}

The first identifier at the start of `text`, or `nothing` when the statement
does not begin with one.
"""
function _leading_keyword(text::AbstractString)
    n = ncodeunits(text)
    j = 1
    while j <= n && isspace(text[j])
        j = nextind(text, j)
    end
    k = j
    while k <= n && (isletter(text[k]) || text[k] == '_')
        k = nextind(text, k)
    end
    return k == j ? nothing : String(SubString(text, j, prevind(text, k)))
end

"""
    _top_level_keywords(text) -> Vector{String}

Every Julia block keyword (from [`_STRUCT_KEYWORDS`](@ref)) that appears outside
strings, comments, brackets, and nested code. Used to decide whether a tag opens
or closes a tracked block.
"""
function _top_level_keywords(text::AbstractString)
    s = String(text)
    n = ncodeunits(s)
    out = String[]
    depth = 0
    j = 1
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
            depth = max(depth - 1, 0)
            j = nextind(s, j)
        elseif depth == 0 && (isletter(c) || c == '_')
            k = j
            while k <= n && (isletter(s[k]) || isdigit(s[k]) || s[k] == '_')
                k = nextind(s, k)
            end
            word = String(SubString(s, j, prevind(s, k)))
            word in _STRUCT_KEYWORDS && push!(out, word)
            j = k
        else
            j = nextind(s, j)
        end
    end
    return out
end

# --- whitespace control -----------------------------------------------------

function _apply_left_strip(text::AbstractString, tok::Token, cfg::Config)
    if tok.lstrip
        return String(rstrip(text))
    elseif cfg.lstrip_blocks && !tok.lkeep
        return _strip_line_end(text)
    end
    return String(text)
end

function _right_strip_mode(tok::Token, cfg::Config)
    if tok.rstrip
        return :all
    elseif cfg.trim_blocks && !tok.rkeep
        return :newline
    end
    return :none
end

# Remove trailing spaces/tabs only when they make up a whole line, so that
# `lstrip_blocks` never eats significant indentation after text.
function _strip_line_end(text::AbstractString)
    stripped = rstrip(text, [' ', '\t'])
    return (isempty(stripped) || last(stripped) == '\n') ? String(stripped) : String(text)
end

function _strip_one_newline(text::AbstractString)
    i = firstindex(text)
    while i <= lastindex(text) && (text[i] == ' ' || text[i] == '\t')
        i = nextind(text, i)
    end
    if i <= lastindex(text) && text[i] == '\n'
        return String(SubString(text, nextind(text, i)))
    end
    return String(text)
end

# --- emission ---------------------------------------------------------------

function _emit_text!(buf::IOBuffer, entries::Vector{MapEntry}, text::AbstractString, pos::Pos)
    isempty(text) && return nothing
    _emit_chunk!(buf, entries, string("print(out, ", repr(text), ')'), pos)
    return nothing
end

# Emit one chunk, one synthetic line at a time, recording a map entry per line.
function _emit_chunk!(buf::IOBuffer, entries::Vector{MapEntry}, chunk::String, pos::Pos)
    isempty(chunk) && return nothing
    parts = split(chunk, '\n'; keepempty = true)
    for (k, part) in enumerate(parts)
        k > 1 && write(buf, UInt8('\n'))
        out_start = position(buf)
        write(buf, part)
        out_end = position(buf) - 1
        line_pos = k == 1 ? pos : Pos(pos.file, pos.line + k - 1, 1, pos.offset)
        push!(entries, MapEntry(out_start, out_end, line_pos))
    end
    write(buf, UInt8('\n'))
    return nothing
end
