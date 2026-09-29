"""
    Pos

A position in a template source file. `file` is a package-relative *virtual* path
(for example `templates/index.html`), never an absolute build-time path, so that
precompile images stay relocatable.
"""
struct Pos
    file::String
    line::Int
    col::Int
    offset::Int # 1-based byte offset into the template source
end

Base.show(io::IO, p::Pos) = print(io, p.file, ':', p.line, ':', p.col)

"""
    TemplateSyntaxError(msg, pos=nothing; source=nothing)

Raised at macro-expansion time when a template cannot be lexed, parsed, or
normalized. `pos` points at the offending template position when one is known.

`source` is the full template text. When it is present, `Base.showerror`
renders the offending line with a caret under `pos`. `compile_template!` attaches
the source to every error that belongs to the template it is compiling, so macro
users get carets without doing anything.
"""
struct TemplateSyntaxError <: Exception
    msg::String
    pos::Union{Pos, Nothing}
    source::Union{Nothing, String}
end

TemplateSyntaxError(msg::AbstractString) = TemplateSyntaxError(String(msg), nothing, nothing)

function TemplateSyntaxError(msg::AbstractString, pos::Union{Pos, Nothing})
    return TemplateSyntaxError(String(msg), pos, nothing)
end

function Base.showerror(io::IO, e::TemplateSyntaxError)
    print(io, "TemplateSyntaxError: ", e.msg)
    e.pos === nothing && return nothing
    if e.source === nothing
        print(io, "\n  --> ", e.pos)
        return nothing
    end
    line, col, text = _diagnostic_line_col(e.source, e.pos)
    print(io, "\n  --> ", e.pos.file, ':', line, ':', col)
    num = string(line)
    pad = " "^length(num)
    print(io, "\n  ", pad, " |")
    print(io, "\n  ", num, " | ", text)
    print(io, "\n  ", pad, " | ", " "^max(col - 1, 0), "^")
    return nothing
end

# The offset map records one position per emitted chunk, so a diagnostic column is
# a byte delta into the synthetic source, not the template. Use the mapped line
# and clamp the column to it so the caret stays on the offending chunk's line.
function _diagnostic_line_col(source::AbstractString, pos::Pos)
    lines = split(source, '\n')
    line = clamp(pos.line, 1, length(lines))
    text = rstrip(lines[line], '\r')
    col = clamp(pos.col, 1, length(text) + 1)
    return line, col, text
end

"""
    MissingContextVariable(name, path, line)

Raised at render time when the `:strict` undefined mode is active and a context
variable was not passed to `render`.
"""
struct MissingContextVariable <: Exception
    name::Symbol
    path::String
    line::Int
end

function Base.showerror(io::IO, e::MissingContextVariable)
    print(io, "MissingContextVariable: context variable `", e.name, "` was not passed")
    if !isempty(e.path)
        print(io, " at ", e.path, ':', e.line)
    end
    return nothing
end

"""
    SourceInfo

Provenance for one generated function: the package-relative virtual path of the
template it came from, its role (`:body`, `:block`, or `:macro`), and the block
or macro name when one applies. `compile_template!` records one of these per
generated function in the compilation unit's registry.
"""
struct SourceInfo
    path::String
    kind::Symbol
    name::Union{Nothing, Symbol}
end

"""
    TemplateFrame

One entry in a [`TemplateError`](@ref) provenance chain. `path` is the
package-relative virtual path (or the host source file for the final `:render`
frame); `abs_path` is that path resolved against the template's `Config.source_root`.
`line` and `col` locate the failing statement inside the template (`col` is `0`
when the native backtrace does not carry a column).
"""
struct TemplateFrame
    kind::Symbol # :body, :block, :macro, or :render
    name::Union{Nothing, Symbol}
    path::String
    abs_path::String
    line::Int
    col::Int
end

"""
    TemplateError(cause, chain)

Wraps an exception raised while rendering a template, together with the
provenance `chain` recovered from the native backtrace. `cause` is the original
exception. `render` throws this only when at least one template frame is found;
otherwise the original exception propagates unchanged.
"""
struct TemplateError <: Exception
    cause::Any
    chain::Vector{TemplateFrame}
end

function Base.showerror(io::IO, e::TemplateError)
    print(io, "TemplateError: ", _error_summary(e.cause))
    for fr in e.chain
        print(io, "\n  ", _frame_label(fr))
    end
    return nothing
end

# The headline of the wrapped error, without the location that the provenance
# chain already supplies.
function _error_summary(e)
    if e isa MissingContextVariable
        return string("MissingContextVariable: context variable `", e.name, "` was not passed")
    end
    return sprint(showerror, e)
end

function _frame_label(fr::TemplateFrame)
    loc = _frame_location(fr)
    if fr.kind === :block
        return string("in block \"", something(fr.name, :?), "\" at ", loc)
    elseif fr.kind === :macro
        return string("in macro \"", something(fr.name, :?), "\" at ", loc)
    elseif fr.kind === :render
        return string("rendered from ", loc)
    end
    return string("at ", loc)
end

_frame_location(fr::TemplateFrame) =
    fr.col > 0 ? string(fr.path, ':', fr.line, ':', fr.col) : string(fr.path, ':', fr.line)
