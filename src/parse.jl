"""
    parse_source(syn, virtual_path) -> Expr

Parse the synthetic source with `Base.JuliaSyntax`, using the virtual path as the
filename so that `LineNumberNode`s and `@__FILE__` already carry template paths.
`Base.JuliaSyntax.ParseError` diagnostics are translated through the offset map
into a `TemplateSyntaxError` at a template position.
"""
function parse_source(syn::Synthesis, virtual_path::AbstractString)
    try
        return Base.JuliaSyntax.parseall(Expr, syn.source; filename = String(virtual_path))
    catch err
        err isa Base.JuliaSyntax.ParseError || rethrow()
        diag = isempty(err.diagnostics) ? nothing : first(err.diagnostics)
        if diag === nothing
            throw(TemplateSyntaxError("syntax error in template", nothing))
        end
        throw(TemplateSyntaxError(String(diag.message), lookup(syn.map, diag.first_byte)))
    end
end

"""
    lookup(map, out_offset) -> Union{Pos,Nothing}

Map a byte offset in the synthetic source back to a template position.
"""
function lookup(map::OffsetMap, out_offset::Integer)
    isempty(map.entries) && return nothing
    lo, hi = 1, length(map.entries)
    idx = 1
    while lo <= hi
        mid = (lo + hi) >>> 1
        if map.entries[mid].out_start <= out_offset
            idx = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    entry = map.entries[idx]
    delta = max(out_offset - entry.out_start, 0)
    return Pos(entry.pos.file, entry.pos.line, entry.pos.col + delta, entry.pos.offset + delta)
end

"""
    line_map(map) -> Vector{Int}

Synthetic line number -> template line number, for rewriting `LineNumberNode`s.
"""
line_map(map::OffsetMap) = Int[entry.pos.line for entry in map.entries]
