"""
    MacroInfo

One `{% macro name(params) %}` definition found while normalizing a template.
`sym` is the generated module-level function that implements the macro.
"""
struct MacroInfo
    name::Symbol
    sym::Symbol
    lambda::Expr
    pos::Pos
end

"""
    CompiledTemplate

A template that has been synthesized, parsed, and normalized. `body_sym` is the
generated body function `body(out, ctx, blocks)`; `enter_sym` is the entry
function `enter(out; kwargs...)`; `namespace_sym` is a `const` binding a
`NamedTuple` of the template's macros for `{% import %}` / `{% from %}`.
`blocks` maps each `{% block %}` name to its generated default function, and
`parent` is the compiled `{% extends %}` target (or `nothing`).
"""
struct CompiledTemplate
    virtual_path::String
    body_sym::Symbol
    enter_sym::Symbol
    namespace_sym::Symbol
    macros::Vector{Symbol}
    blocks::Dict{Symbol, Symbol}
    parent::Union{Nothing, CompiledTemplate}
end

"""
    CompilationUnit

State shared by every template compiled from one `@template` / `@templates`
expansion. `defs` accumulates generated top-level expressions in dependency
order; `compiled` deduplicates templates reached through several references and
`in_progress` detects reference cycles.
"""
mutable struct CompilationUnit
    mod::Module
    cfg::Config
    unit_id::String
    defs::Vector{Any}
    compiled::Dict{String, CompiledTemplate}
    in_progress::Set{String}
end

CompilationUnit(mod::Module, cfg::Config, unit_id::AbstractString) =
    CompilationUnit(mod, cfg, String(unit_id), Any[], Dict{String, CompiledTemplate}(), Set{String}())

# A stable identifier for a virtual path, used to name generated functions. FNV-1a
# keeps generated names reproducible across Julia versions and processes.
function _stable_id(path::AbstractString)
    h = UInt64(0xcbf29ce484222325)
    for byte in codeunits(path)
        h ⊻= byte
        h *= 0x00000100000001b3
    end
    return string(h; base = 16)
end

function _config_signature(cfg::Config)
    return string(
        cfg.expression_start, cfg.expression_end,
        cfg.statement_start, cfg.statement_end,
        cfg.comment_start, cfg.comment_end,
        cfg.trim_blocks, cfg.lstrip_blocks, cfg.autoescape,
        cfg.source_root, cfg.undefined,
    )
end

# Identify one `@template` / `@templates` expansion. The macro call site makes
# the id unique even when the same file is compiled by several macros.
function _unit_id(cfg::Config, root_virtual_path::AbstractString, source::LineNumberNode)
    site = source === nothing ? "" : string(source.file, ':', source.line)
    return _stable_id(_config_signature(cfg) * "\0" * root_virtual_path * "\0" * site)
end

# Generated names carry the unit id as well as the template path, so two separate
# `@template` expansions that reference the same file do not redefine each
# other's methods. `unit_id` is derived from the macro call site.
_template_id(unit::CompilationUnit, virtual_path::AbstractString) =
    _stable_id(unit.unit_id * "\0" * virtual_path)

"""
    compile_template!(unit, virtual_path, abs_path) -> CompiledTemplate

Compile one template into `unit`, recursively compiling every template it
references with `{% include %}`, `{% extends %}`, `{% import %}`, or
`{% from %}`. Results are memoized by virtual path, so a template included from
several places is compiled once. A reference cycle is a `TemplateSyntaxError`.
"""
function compile_template!(unit::CompilationUnit, virtual_path::AbstractString, abs_path::AbstractString)
    virtual_path = String(normpath(virtual_path))
    abs_path = String(normpath(abs_path))
    haskey(unit.compiled, virtual_path) && return unit.compiled[virtual_path]
    if virtual_path in unit.in_progress
        throw(TemplateSyntaxError("circular template reference involving $virtual_path"))
    end
    push!(unit.in_progress, virtual_path)
    Base.include_dependency(abs_path)

    src = read(abs_path, String)
    syn = synthesize(src, virtual_path, unit.cfg)
    parsed = parse_source(syn, virtual_path)
    normalized = normalize(parsed, syn, virtual_path, unit.cfg, unit, abs_path)
    macros = normalized.macros
    _check_duplicate_macros(macros)
    _check_duplicate_blocks(normalized.blocks)

    id = _template_id(unit, virtual_path)
    macro_names = Symbol[m.name for m in macros]
    bindings = Pair{Symbol, Any}[m.name => GlobalRef(unit.mod, m.sym) for m in macros]
    append!(bindings, normalized.imports)
    binding_names = Set{Symbol}(first.(bindings))

    body_sym = Symbol("__ginger_body_", id, "__")
    enter_sym = Symbol("__ginger_enter_", id, "__")
    namespace_sym = Symbol("__ginger_macros_", id, "__")
    blocks_sym = Symbol("__ginger_blocks_", id, "__")

    macro_defs = Any[_macro_function(m, bindings, unit, virtual_path) for m in macros]
    namespace_def = Expr(:const, Expr(:(=), namespace_sym, Expr(:tuple, (Expr(:(=), m.name, m.sym) for m in macros)...)))
    block_defs = Any[_block_function(b, bindings, unit, virtual_path) for b in normalized.blocks]
    blocks_def = Expr(:const, Expr(:(=), blocks_sym, _blocks_tuple(normalized.blocks, unit.mod)))
    body_def = _body_function(body_sym, blocks_sym, normalized, bindings, binding_names, unit, virtual_path)
    enter_def = _enter_function(enter_sym, body_sym, virtual_path)

    append!(unit.defs, macro_defs)
    append!(unit.defs, block_defs)
    push!(unit.defs, namespace_def, blocks_def)
    push!(unit.defs, body_def, enter_def)

    block_map = Dict{Symbol, Symbol}(b.name => b.sym for b in normalized.blocks)
    compiled = CompiledTemplate(virtual_path, body_sym, enter_sym, namespace_sym, macro_names, block_map, normalized.parent)
    unit.compiled[virtual_path] = compiled
    delete!(unit.in_progress, virtual_path)
    return compiled
end

# `stmts` is already a flat list; rewrap for scope analysis so that top-level
# `let`/`function` heads are visible as they are in the parsed tree.
_toplevel(stmts) = Expr(:toplevel, stmts...)

function _check_duplicate_macros(macros::Vector{MacroInfo})
    seen = Set{Symbol}()
    for m in macros
        m.name in seen && throw(TemplateSyntaxError("duplicate macro `$(m.name)`", m.pos))
        push!(seen, m.name)
    end
    return nothing
end

# --- generated function shapes ----------------------------------------------

function _body_function(body_sym::Symbol, blocks_sym::Symbol, normalized, bindings, binding_names, unit::CompilationUnit, virtual_path::String)
    lnn = LineNumberNode(1, Symbol(virtual_path))
    if normalized.parent !== nothing
        # A child body contributes its blocks and delegates to its parent. The
        # incoming blocks (from a more-derived template) win over the child's own,
        # so `merge(own, incoming)` is the correct order.
        merged = Expr(
            :(=), :blocks,
            Expr(:call, GlobalRef(Base, :merge), GlobalRef(unit.mod, blocks_sym), :blocks),
        )
        call = Expr(:call, GlobalRef(unit.mod, normalized.parent.body_sym), :out, :ctx, :blocks)
        block = Expr(:block, lnn, merged, Expr(:return, call))
    else
        vars = context_vars(_toplevel(normalized.stmts), unit.mod, binding_names)
        prologue = _prologue(bindings, vars, virtual_path, unit.cfg.undefined)
        block = Expr(:block, lnn, prologue..., normalized.stmts...)
    end
    fn = Expr(:function, Expr(:call, body_sym, :out, :ctx, :blocks), block)
    return Expr(:macrocall, Symbol("@noinline"), lnn, fn)
end

function _blocks_tuple(blocks, mod::Module)
    isempty(blocks) && return Expr(:call, GlobalRef(Base, :NamedTuple))
    return Expr(:tuple, (Expr(:(=), b.name, GlobalRef(mod, b.sym)) for b in blocks)...)
end

# A block body is a module-level function taking the same `(out, ctx, blocks)`
# arguments as a body function, so `super()` and nested blocks dispatch uniformly.
function _block_function(b, bindings, unit::CompilationUnit, virtual_path::String)
    vars = context_vars(b.body, unit.mod, Set{Symbol}(first.(bindings)))
    prologue = _prologue(bindings, vars, virtual_path, unit.cfg.undefined)
    lnn = LineNumberNode(1, Symbol(virtual_path))
    block = Expr(:block, lnn, prologue..., b.body)
    fn = Expr(:function, Expr(:call, b.sym, :out, :ctx, :blocks), block)
    return Expr(:macrocall, Symbol("@noinline"), lnn, fn)
end

function _prologue(bindings, vars, virtual_path::String, undefined::Symbol)
    prologue = Any[Expr(:(=), name, value) for (name, value) in bindings]
    append!(prologue, (Expr(:(=), var, _fetchvar_expr(var, virtual_path, undefined)) for var in vars))
    return prologue
end

function _enter_function(sym::Symbol, body_sym::Symbol, virtual_path::String)
    lnn = LineNumberNode(1, Symbol(virtual_path))
    sig = Expr(:call, sym, Expr(:parameters, Expr(:..., :kwargs)), :out)
    args = Expr(:call, GlobalRef(Base, :NamedTuple), :kwargs)
    fresh = Expr(:call, GlobalRef(Base, :NamedTuple))
    ret = Expr(:return, Expr(:call, body_sym, :out, args, fresh))
    return Expr(:function, sig, Expr(:block, lnn, ret))
end

"""
    _macro_function(m, macro_syms, unit, virtual_path)

Build the module-level function for one macro. A macro body sees its arguments,
the template's other macros, and host-module globals; it does **not** see the
caller's context. A free variable that is none of those is a compile-time error.
"""
function _macro_function(m::MacroInfo, bindings, unit::CompilationUnit, virtual_path::String)
    params = _lambda_params(m.lambda.args[1])
    body = m.lambda.args[2]
    bound = union(Set{Symbol}(first.(bindings)), _params(params))
    vars = context_vars(body, unit.mod, bound)
    if !isempty(vars)
        throw(
            TemplateSyntaxError(
                "macro `$(m.name)` references undefined variable(s): " *
                    join(sort!(collect(vars)), ", "),
                m.pos,
            ),
        )
    end

    lnn = LineNumberNode(1, Symbol(virtual_path))
    prologue = Any[
        Expr(:(=), :out, Expr(:call, GlobalRef(Base, :IOBuffer))),
        Expr(:(=), :ctx, Expr(:call, GlobalRef(Base, :NamedTuple))),
    ]
    append!(prologue, (Expr(:(=), name, value) for (name, value) in bindings))
    bodyargs = body isa Expr && body.head === :block ? body.args : Any[body]
    ret = Expr(
        :return,
        Expr(
            :call, GlobalRef(Ginger, :HTMLString),
            Expr(:call, GlobalRef(Base, :String), Expr(:call, GlobalRef(Base, :take!), :out)),
        ),
    )
    block = Expr(:block, lnn, prologue..., bodyargs..., ret)
    fn = Expr(:function, Expr(:call, m.sym, params...), block)
    return Expr(:macrocall, Symbol("@noinline"), lnn, fn)
end

# Turn a lambda parameter spec into a parameter list for a function signature.
# A lambda writes a default as `x = v`; a function signature wants `Expr(:kw)`.
function _lambda_params(arg)
    params = arg isa Expr && arg.head === :tuple ? Any[arg.args...] : Any[arg]
    return Any[_function_param(p) for p in params]
end

function _function_param(p)
    if p isa Expr && p.head === :(=)
        return Expr(:kw, p.args[1], p.args[2])
    end
    return p
end

# --- references -------------------------------------------------------------

"""
    _reference_paths(virtual_path, abs_path, rel) -> (virtual, absolute)

Resolve a template reference (as written inside `{% include %}` or
`{% import %}`) against the referencing template. The virtual path stays
package-relative; the absolute path is only used to read the file.
"""
function _reference_paths(virtual_path::AbstractString, abs_path::AbstractString, rel::AbstractString)
    if isabspath(rel)
        return String(normpath(rel)), String(normpath(rel))
    end
    dep_virtual = normpath(joinpath(dirname(virtual_path), rel))
    dep_abs = normpath(joinpath(dirname(abs_path), rel))
    return String(dep_virtual), String(dep_abs)
end

"""
    _compile_reference!(unit, virtual_path, abs_path, rel, pos)

Resolve and compile a referenced template, returning its `CompiledTemplate`.
"""
function _compile_reference!(unit::CompilationUnit, virtual_path::AbstractString, abs_path::AbstractString, rel::AbstractString, pos::Pos)
    dep_virtual, dep_abs = _reference_paths(virtual_path, abs_path, rel)
    isfile(dep_abs) || throw(
        TemplateSyntaxError("template not found: $(repr(String(rel))) (looked in $(dirname(abs_path)))", pos),
    )
    return compile_template!(unit, dep_virtual, dep_abs)
end
