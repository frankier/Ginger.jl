"""
    Normalized

The result of [`normalize`](@ref): the flattened body statements plus the
`{% macro %}` definitions found while expanding markers.
"""
struct Normalized
    stmts::Vector{Any}
    macros::Vector{MacroInfo}
end

"""
    NormalizeState

Mutable state threaded through the marker-expansion walk. `last_lnn` tracks the
most recently visited `LineNumberNode` so that structural markers can be
reported at a template position.
"""
mutable struct NormalizeState
    unit::CompilationUnit
    cfg::Config
    virtual_path::String
    abs_path::String
    syn::Synthesis
    id::String
    last_lnn::Union{LineNumberNode, Nothing}
    macros::Vector{MacroInfo}
end

"""
    normalize(parsed, syn, virtual_path, cfg, unit, abs_path) -> Normalized

Turn the parsed synthetic `Expr` into normal body statements:

1. expand `__ginger_print__`, `__ginger_macro__`, `__ginger_include__`,
   `__ginger_import__`, and `__ginger_fromimport__` markers (recursively
   compiling referenced templates into `unit`),
2. rewrite synthetic line numbers to template line numbers.

Context inference and the generated function definitions happen in
`compose.jl`, once every macro name is known.
"""
function normalize(parsed::Expr, syn::Synthesis, virtual_path::AbstractString, cfg::Config, unit::CompilationUnit, abs_path::AbstractString)
    virtual_path = String(virtual_path)
    state = NormalizeState(
        unit, cfg, virtual_path, String(abs_path), syn,
        _template_id(unit, virtual_path), nothing, MacroInfo[],
    )
    expanded = MacroTools.postwalk(x -> _expand_node(x, state), parsed)
    rewritten = _rewrite_lines(expanded, line_map(syn.map), virtual_path)
    stmts = rewritten.head === :toplevel ? rewritten.args : Any[rewritten]
    return Normalized(stmts, state.macros)
end

function _expand_node(x, st::NormalizeState)
    if x isa LineNumberNode
        st.last_lnn = x
        return x
    elseif x isa Expr
        return _expand_marker(x, st)
    end
    return x
end

function _expand_marker(x::Expr, st::NormalizeState)
    x.head === :call || return x
    f = x.args[1]
    if f === :__ginger_print__
        return _print_call(x.args[2], st.cfg)
    elseif f === :__ginger_macro__
        return _expand_macro(x, st)
    elseif f === :__ginger_include__
        return _expand_include(x, st)
    elseif f === :__ginger_import__
        return _expand_import(x, st)
    elseif f === :__ginger_fromimport__
        return _expand_fromimport(x, st)
    end
    return x
end

function _marker_pos(st::NormalizeState)
    lnn = st.last_lnn
    line = lnn === nothing ? 1 : lnn.line
    tmpl = 1 <= line <= length(st.syn.map.entries) ? line_map(st.syn.map)[line] : line
    return Pos(st.virtual_path, tmpl, 1, 0)
end

# --- marker expansion -------------------------------------------------------

function _expand_macro(x::Expr, st::NormalizeState)
    ok = length(x.args) == 3 && x.args[2] isa QuoteNode && x.args[2].value isa Symbol &&
        x.args[3] isa Expr && x.args[3].head === :(->)
    ok || throw(TemplateSyntaxError("malformed `{% macro %}` tag", _marker_pos(st)))
    name = x.args[2].value
    sym = Symbol("__ginger_macro_", st.id, "_", name, "__")
    push!(st.macros, MacroInfo(name, sym, x.args[3], _marker_pos(st)))
    # The definition site emits nothing; macro bindings are added to the body
    # and to every macro function prologue by `compose.jl`.
    return Expr(:block)
end

function _expand_include(x::Expr, st::NormalizeState)
    args = x.args[2:end]
    params = nothing
    if !isempty(args) && args[1] isa Expr && args[1].head === :parameters
        params = args[1]
        args = args[2:end]
    end
    length(args) == 1 || throw(TemplateSyntaxError("`{% include %}` expects a single path", _marker_pos(st)))
    path = args[1]
    path isa String || throw(TemplateSyntaxError("`{% include %}` path must be a string literal", _marker_pos(st)))
    dep = _compile_reference!(st.unit, st.virtual_path, st.abs_path, path, _marker_pos(st))
    ctx_expr = if params === nothing || isempty(params.args)
        :ctx
    else
        pairs = Any[Expr(:(=), kw.args[1], kw.args[2]) for kw in params.args]
        Expr(:call, GlobalRef(Base, :merge), :ctx, Expr(:tuple, pairs...))
    end
    return Expr(:call, GlobalRef(st.unit.mod, dep.body_sym), :out, ctx_expr)
end

function _expand_import(x::Expr, st::NormalizeState)
    ok = length(x.args) == 3 && x.args[2] isa QuoteNode && x.args[2].value isa Symbol && x.args[3] isa String
    ok || throw(TemplateSyntaxError("malformed `{% import %}` tag", _marker_pos(st)))
    dep = _compile_reference!(st.unit, st.virtual_path, st.abs_path, x.args[3], _marker_pos(st))
    return Expr(:(=), x.args[2].value, GlobalRef(st.unit.mod, dep.namespace_sym))
end

function _expand_fromimport(x::Expr, st::NormalizeState)
    ok = length(x.args) == 3 && x.args[2] isa String &&
        x.args[3] isa Expr && x.args[3].head === :tuple
    ok || throw(TemplateSyntaxError("malformed `{% from %}` tag", _marker_pos(st)))
    dep = _compile_reference!(st.unit, st.virtual_path, st.abs_path, x.args[2], _marker_pos(st))
    assignments = Any[]
    for pair in x.args[3].args
        pair isa Expr && pair.head === :(=) ||
            throw(TemplateSyntaxError("malformed `{% from %}` import list", _marker_pos(st)))
        remote = pair.args[2]
        remote isa QuoteNode && remote.value isa Symbol ||
            throw(TemplateSyntaxError("malformed `{% from %}` import list", _marker_pos(st)))
        remote.value in dep.macros || throw(
            TemplateSyntaxError(
                "template $(repr(dep.virtual_path)) has no macro `$(remote.value)`",
                _marker_pos(st),
            ),
        )
        push!(assignments, Expr(:(=), pair.args[1], Expr(:., GlobalRef(st.unit.mod, dep.namespace_sym), QuoteNode(remote.value))))
    end
    return Expr(:block, assignments...)
end

function _print_call(value, cfg::Config)
    if cfg.autoescape
        escaped = Expr(:call, GlobalRef(Ginger, :escape), value)
        return Expr(:call, GlobalRef(Base, :print), :out, escaped)
    end
    return Expr(:call, GlobalRef(Base, :print), :out, value)
end

function _rewrite_lines(x, linemap::Vector{Int}, file::String)
    if x isa LineNumberNode
        line = x.line
        template_line = 1 <= line <= length(linemap) ? linemap[line] : line
        return LineNumberNode(template_line, Symbol(file))
    elseif x isa Expr
        return Expr(x.head, (_rewrite_lines(a, linemap, file) for a in x.args)...)
    end
    return x
end
