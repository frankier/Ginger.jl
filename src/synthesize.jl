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

"""
    synthesize(src, virtual_path, cfg) -> Synthesis

Consume the token stream and build synthetic Julia source plus its offset map.
Text becomes a `print` call, expressions become `__ginger_print__` calls, and
statements are emitted verbatim. Whitespace control is applied here, where the
preceding and following text chunks are known.
"""
function synthesize(src::AbstractString, virtual_path::AbstractString, cfg::Config)
    lx = Lexer(src, virtual_path, cfg)
    buf = IOBuffer()
    entries = MapEntry[]
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
            tok.kind === COMMENT || _emit_tag!(buf, entries, tok)
            strip_next = _right_strip_mode(tok, cfg)
        end
    end
    if pending !== nothing
        text, pos = pending
        _emit_text!(buf, entries, text, pos)
    end
    return Synthesis(String(take!(buf)), OffsetMap(entries))
end

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

function _emit_text!(buf::IOBuffer, entries::Vector{MapEntry}, text::AbstractString, pos::Pos)
    isempty(text) && return nothing
    _emit_chunk!(buf, entries, string("print(out, ", repr(text), ')'), pos)
    return nothing
end

function _emit_tag!(buf::IOBuffer, entries::Vector{MapEntry}, tok::Token)
    isempty(tok.text) && return nothing
    chunk = tok.kind === EXPRESSION ? string("__ginger_print__(", tok.text, ')') : tok.text
    _emit_chunk!(buf, entries, chunk, tok.pos)
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
