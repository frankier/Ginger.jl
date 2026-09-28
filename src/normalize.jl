"""
    BlockInfo

One `{% block name %}` definition found while normalizing a template. `sym` is
the generated module-level function that implements the block's default body.
"""
struct BlockInfo
    name::Symbol
    sym::Symbol
    body::Any
    pos::Pos
end

"""
    Normalized

The result of [`normalize`](@ref): the flattened body statements, the
`{% macro %}` definitions found while expanding markers, the `{% block %}`
definitions, the top-level `{% import %}` / `{% from %}` bindings, and the
compiled parent template when `{% extends %}` is present.
"""
struct Normalized
    stmts::Vector{Any}
    macros::Vector{MacroInfo}
    blocks::Vector{BlockInfo}
    imports::Vector{Pair{Symbol, Any}}
    parent::Union{Nothing, CompiledTemplate}
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
    blocks::Vector{BlockInfo}
    imports::Vector{Pair{Symbol, Any}}
    parent::Union{Nothing, CompiledTemplate}
end

"""
    normalize(parsed, syn, virtual_path, cfg, unit, abs_path) -> Normalized

Turn the parsed synthetic `Expr` into normal body statements:

1. extract `{% extends %}` (compiling the parent template first, so that
   `super()` can resolve against it),
2. expand `__ginger_print__`, `__ginger_macro__`, `__ginger_block__`,
   `__ginger_include__`, `__ginger_import__`, and `__ginger_fromimport__`
   markers (recursively compiling referenced templates into `unit`),
3. resolve `super()` / `super(n)` inside blocks to static ancestor calls,
4. rewrite synthetic line numbers to template line numbers.

Context inference and the generated function definitions happen in
`compose.jl`, once every macro and block name is known.
"""
function normalize(parsed::Expr, syn::Synthesis, virtual_path::AbstractString, cfg::Config, unit::CompilationUnit, abs_path::AbstractString)
    virtual_path = String(virtual_path)
    state = NormalizeState(
        unit, cfg, virtual_path, String(abs_path), syn,
        _template_id(unit, virtual_path), nothing, MacroInfo[], BlockInfo[],
        Pair{Symbol, Any}[], nothing,
    )
    pre = _extract_extends!(state, parsed)
    _check_block_placement!(state, pre)
    expanded = MacroTools.postwalk(x -> _expand_node(x, state), pre)
    rewritten = _rewrite_lines(expanded, line_map(syn.map), virtual_path)
    stmts = rewritten.head === :toplevel ? rewritten.args : Any[rewritten]
    _check_duplicate_blocks(state.blocks)
    for m in state.macros
        _check_no_super(m.lambda)
    end
    _check_no_super(rewritten)
    state.parent === nothing || _check_no_loose_text(state, stmts)
    return Normalized(stmts, state.macros, state.blocks, state.imports, state.parent)
end

# `{% extends %}` must be handled before blocks are expanded, because `super()`
# resolves against the parent's block functions at expansion time. It is a
# top-level marker, so a pre-pass over the parsed statements is enough.
function _extract_extends!(st::NormalizeState, parsed::Expr)
    parsed.head === :toplevel || return parsed
    out = Any[]
    found = false
    for a in parsed.args
        if a isa LineNumberNode
            st.last_lnn = a
            push!(out, a)
        elseif a isa Expr && a.head === :call && a.args[1] === :__ginger_extends__
            found && throw(
                TemplateSyntaxError("`{% extends %}` may appear at most once", _marker_pos(st)),
            )
            length(a.args) == 2 && a.args[2] isa String || throw(
                TemplateSyntaxError("`{% extends %}` path must be a string literal", _marker_pos(st)),
            )
            st.parent = _compile_reference!(st.unit, st.virtual_path, st.abs_path, a.args[2], _marker_pos(st))
            found = true
        else
            push!(out, a)
        end
    end
    return Expr(:toplevel, out...)
end

# Heads that put a `{% block %}` under control flow. Synthesis already rejects
# the common cases; this walk is the backstop for a control-flow keyword that
# appears mid-statement rather than as the leading keyword.
const _CONTROL_HEADS = Set{Symbol}(
    [:if, :for, :while, :let, :try, :function, :(->), :do, :comprehension, :generator, :filter]
)

function _check_block_placement!(st::NormalizeState, x)
    _walk_block_placement(st, x, false)
    return nothing
end

function _walk_block_placement(st::NormalizeState, x, in_control::Bool)
    if x isa LineNumberNode
        st.last_lnn = x
        return nothing
    end
    x isa Expr || return nothing
    if _is_block_marker(x)
        in_control && throw(
            TemplateSyntaxError("`{% block %}` may not appear under control flow", _marker_pos(st)),
        )
        # A block body is `InBlock`: nested blocks directly inside it are allowed.
        # Recurse into the lambda body, not the `->` wrapper, which would itself
        # look like control flow.
        lambda = x.args[2]
        body = lambda isa Expr && lambda.head === :(->) ? lambda.args[2] : lambda
        _walk_block_placement(st, body, false)
        return nothing
    end
    child = in_control || x.head in _CONTROL_HEADS
    for a in x.args
        _walk_block_placement(st, a, child)
    end
    return nothing
end

function _is_block_marker(x::Expr)
    x.head === :do || return false
    call = x.args[1]
    return call isa Expr && call.head === :call && call.args[1] === :__ginger_block__
end

function _expand_node(x, st::NormalizeState)
    if x isa LineNumberNode
        st.last_lnn = x
        return x
    elseif x isa Expr
        x.head === :do && return _expand_do(x, st)
        return _expand_marker(x, st)
    end
    return x
end

# A `{% block name %}` is emitted as `__ginger_block__(:name) do … end`. The
# lambda body becomes a generated module-level function and the call site becomes
# a static block dispatch.
function _expand_do(x::Expr, st::NormalizeState)
    _is_block_marker(x) && return _expand_block(x, st)
    return x
end

function _expand_block(x::Expr, st::NormalizeState)
    call = x.args[1]
    lambda = length(x.args) >= 2 ? x.args[2] : nothing
    ok = length(call.args) == 2 && call.args[2] isa QuoteNode && call.args[2].value isa Symbol &&
        lambda isa Expr && lambda.head === :(->) && length(lambda.args) == 2
    ok || throw(TemplateSyntaxError("malformed `{% block %}` tag", _marker_pos(st)))
    name = call.args[2].value
    body = _rewrite_lines(lambda.args[2], line_map(st.syn.map), st.virtual_path)
    resolved = _resolve_super(body, name, st)
    sym = Symbol("__ginger_block_", st.id, "_", name, "__")
    push!(st.blocks, BlockInfo(name, sym, resolved, _marker_pos(st)))
    return Expr(
        :call, GlobalRef(Ginger, :__ginger_render_block__),
        :blocks, QuoteNode(name), GlobalRef(st.unit.mod, sym), :out, :ctx,
    )
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
    elseif f === :super
        return _expand_super(x, st)
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
    fresh_blocks = Expr(:call, GlobalRef(Base, :NamedTuple))
    return Expr(:call, GlobalRef(st.unit.mod, dep.body_sym), :out, ctx_expr, fresh_blocks)
end

function _expand_import(x::Expr, st::NormalizeState)
    ok = length(x.args) == 3 && x.args[2] isa QuoteNode && x.args[2].value isa Symbol && x.args[3] isa String
    ok || throw(TemplateSyntaxError("malformed `{% import %}` tag", _marker_pos(st)))
    dep = _compile_reference!(st.unit, st.virtual_path, st.abs_path, x.args[3], _marker_pos(st))
    push!(st.imports, x.args[2].value => GlobalRef(st.unit.mod, dep.namespace_sym))
    return Expr(:block)
end

function _expand_fromimport(x::Expr, st::NormalizeState)
    ok = length(x.args) == 3 && x.args[2] isa String &&
        x.args[3] isa Expr && x.args[3].head === :tuple
    ok || throw(TemplateSyntaxError("malformed `{% from %}` tag", _marker_pos(st)))
    dep = _compile_reference!(st.unit, st.virtual_path, st.abs_path, x.args[2], _marker_pos(st))
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
        value = Expr(:., GlobalRef(st.unit.mod, dep.namespace_sym), QuoteNode(remote.value))
        push!(st.imports, pair.args[1] => value)
    end
    return Expr(:block)
end

# `super()` / `super(n)` become a placeholder resolved once the enclosing block is
# expanded. The placeholder carries its template position so an out-of-block
# `super()` can be reported precisely.
function _expand_super(x::Expr, st::NormalizeState)
    if length(x.args) == 1
        n = 1
    elseif length(x.args) == 2 && x.args[2] isa Integer && x.args[2] >= 1
        n = Int(x.args[2])
    else
        throw(TemplateSyntaxError("`super()` takes no arguments or a positive integer", _marker_pos(st)))
    end
    return Expr(:call, :__ginger_super__, n, QuoteNode(_marker_pos(st)))
end

# Resolve `__ginger_super__` markers in a block body to static calls on the
# nearest ancestor definitions of the block. `super()` is the nearest ancestor,
# `super(2)` the one above it, and so on.
function _resolve_super(body, name::Symbol, st::NormalizeState)
    chain = _ancestor_block_syms(st.parent, name)
    return MacroTools.postwalk(body) do e
        if e isa Expr && e.head === :call && e.args[1] === :__ginger_super__
            k = Int(e.args[2])
            block = k <= length(chain) ? GlobalRef(st.unit.mod, chain[k]) : GlobalRef(Ginger, :__ginger_empty_block__)
            return Expr(:call, GlobalRef(Ginger, :__ginger_render_super__), block, :ctx, :blocks)
        end
        return e
    end
end

function _ancestor_block_syms(parent::Union{Nothing, CompiledTemplate}, name::Symbol)
    syms = Symbol[]
    p = parent
    while p !== nothing
        haskey(p.blocks, name) && push!(syms, p.blocks[name])
        p = p.parent
    end
    return syms
end

function _print_call(value, cfg::Config)
    if cfg.autoescape
        escaped = Expr(:call, GlobalRef(Ginger, :escape), value)
        return Expr(:call, GlobalRef(Base, :print), :out, escaped)
    end
    return Expr(:call, GlobalRef(Base, :print), :out, value)
end

function _check_duplicate_blocks(blocks::Vector{BlockInfo})
    seen = Set{Symbol}()
    for b in blocks
        b.name in seen && throw(TemplateSyntaxError("duplicate block `$(b.name)`", b.pos))
        push!(seen, b.name)
    end
    return nothing
end

# An extending template contributes only blocks; any real output outside a block
# is a template authoring error. Whitespace between tags is ignored.
function _check_no_loose_text(st::NormalizeState, stmts)
    last = nothing
    for a in stmts
        if a isa LineNumberNode
            last = a
        elseif _is_loose_print(a)
            last === nothing || (st.last_lnn = last)
            throw(
                TemplateSyntaxError(
                    "output outside a `{% block %}` in an extending template",
                    _marker_pos(st),
                ),
            )
        end
    end
    return nothing
end

function _is_loose_print(e)
    e isa Expr || return false
    e.head === :call || return false
    _is_print(e.args[1]) || return false
    length(e.args) == 3 || return true
    arg = e.args[3]
    arg isa String && return !all(isspace, arg)
    return true
end

function _is_print(f)
    f === :print && return true
    return f isa GlobalRef && f.mod === Base && f.name === :print
end

function _check_no_super(e)
    found = false
    pos = nothing
    MacroTools.postwalk(e) do x
        if x isa Expr && x.head === :call && x.args[1] === :__ginger_super__
            found = true
            if pos === nothing && length(x.args) >= 3 && x.args[3] isa QuoteNode &&
                    x.args[3].value isa Pos
                pos = x.args[3].value
            end
        end
        return x
    end
    found && throw(TemplateSyntaxError("`super()` may only appear inside a block", pos))
    return nothing
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
