"""
    HTMLString(s)

A string that is already safe for HTML output. `escape` is the identity on an
`HTMLString`, which makes escaping idempotent.
"""
struct HTMLString
    s::String
end

Base.string(h::HTMLString) = h.s
Base.print(io::IO, h::HTMLString) = print(io, h.s)
Base.write(io::IO, h::HTMLString) = write(io, h.s)
Base.:(==)(a::HTMLString, b::HTMLString) = a.s == b.s
Base.hash(h::HTMLString, hsh::UInt) = hash(h.s, hsh)

const _ESCAPE_REPLACEMENTS = ('&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;", '\'' => "&#39;")

"""
    escape_string(s) -> String

HTML-escape `&`, `<`, `>`, `"`, and `'`.
"""
function escape_string(s::AbstractString)
    return replace(s, _ESCAPE_REPLACEMENTS...)
end

"""
    escape(x) -> HTMLString

HTML-escape `x` for safe interpolation. Idempotent: `escape(escape(x)) == escape(x)`,
and `escape(::HTMLString)` is the identity.
"""
escape(x) = HTMLString(escape_string(string(x)))
escape(h::HTMLString) = h

"""
    safe(x) -> HTMLString

Mark `x` as already HTML-safe, bypassing autoescaping. Idempotent.
"""
safe(x) = x isa HTMLString ? x : HTMLString(string(x))
safe(h::HTMLString) = h

"""
    Undefined

Placeholder bound by the `:lenient` and `:default` undefined modes. Renders as
the empty string and raises `MissingContextVariable` on property or index access.
"""
struct Undefined
    name::Symbol
    path::String
    line::Int
end

Base.string(::Undefined) = ""
Base.print(io::IO, ::Undefined) = nothing

function Base.getproperty(u::Undefined, name::Symbol)
    return throw(MissingContextVariable(name, getfield(u, :path), getfield(u, :line)))
end

"""
    default(x, fallback)

Return `fallback` when `x` is an `Undefined` context variable, else `x`.
"""
default(::Undefined, fallback) = fallback
default(x, _) = x

"""
    fetchvar(ctx, Val(mode), name, path, line)

Bind context variable `name` from the `NamedTuple` `ctx`. The undefined mode is a
type parameter, so `:strict` compiles to a checked field access and `:lenient` to
an `Undefined` fallback.
"""
@inline function fetchvar(ctx, ::Val{:strict}, name::Symbol, path::AbstractString, line::Integer)
    hasproperty(ctx, name) || throw(MissingContextVariable(name, String(path), Int(line)))
    return getproperty(ctx, name)
end

@inline function fetchvar(ctx, ::Val{:lenient}, name::Symbol, path::AbstractString, line::Integer)
    hasproperty(ctx, name) || return Undefined(name, String(path), Int(line))
    return getproperty(ctx, name)
end

@inline function fetchvar(ctx, ::Val{:default}, name::Symbol, path::AbstractString, line::Integer)
    return fetchvar(ctx, Val(:lenient), name, path, line)
end

"""
    __ginger_render_block__(blocks, name, default, out, ctx)

Dispatch a `{% block %}`: call the override installed in `blocks`, or `default`
when no template in the chain overrides the block. `blocks` always has a
concrete `NamedTuple` type at the call site, so `hasproperty` constant-folds and
the call devirtualizes.
"""
@inline function __ginger_render_block__(blocks, name::Symbol, default, out, ctx)
    return hasproperty(blocks, name) ? getproperty(blocks, name)(out, ctx, blocks) :
        default(out, ctx, blocks)
end

"""
    __ginger_render_super__(block, ctx, blocks)

Render an ancestor block into a fresh buffer and return it as an `HTMLString`.
`super()` appears inside `{{ }}`, so it must produce a value rather than write to
the caller's output stream. The result is already escaped by the block body, and
`escape` is idempotent on `HTMLString`.
"""
@inline function __ginger_render_super__(block, ctx, blocks)
    buf = IOBuffer()
    block(buf, ctx, blocks)
    return HTMLString(String(take!(buf)))
end

"""
    __ginger_empty_block__(out, ctx, blocks)

Fallback for `super(n)` when fewer than `n` ancestors define the block. Renders
nothing.
"""
__ginger_empty_block__(out, ctx, blocks) = HTMLString("")

"""
    Template

A compiled template. `path` is the package-relative virtual path; `entry` is the
generated entry function `entry(out; kwargs...)`. `sources` is the compilation
unit's provenance registry, mapping each generated function name to its
[`SourceInfo`](@ref), and `source_root` resolves virtual paths to absolute paths
for diagnostics.
"""
struct Template{F <: Function}
    path::String
    entry::F
    sources::Dict{Symbol, SourceInfo}
    source_root::String
end

function Base.show(io::IO, t::Template)
    print(io, "Template(", repr(t.path), ')')
    return nothing
end
