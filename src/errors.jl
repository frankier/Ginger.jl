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
    TemplateSyntaxError(msg, pos=nothing)

Raised at macro-expansion time when a template cannot be lexed, parsed, or
normalized. `pos` points at the offending template position when one is known.
"""
struct TemplateSyntaxError <: Exception
    msg::String
    pos::Union{Pos, Nothing}
end

TemplateSyntaxError(msg::AbstractString) = TemplateSyntaxError(String(msg), nothing)

function Base.showerror(io::IO, e::TemplateSyntaxError)
    print(io, "TemplateSyntaxError: ", e.msg)
    if e.pos !== nothing
        print(io, "\n  --> ", e.pos)
    end
    return nothing
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
