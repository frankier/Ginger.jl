"""
    @template path [as NAME] [config = CONFIG]

Compile the template at `path` during macro expansion and bind a `Template` value
to `NAME` (default: the uppercased file stem) in the host module.

The file is read at expansion time; `Base.include_dependency` registers it so
editing the template invalidates the host package. `path` must be a string
literal; a relative path is resolved against the directory of the file that
contains the macro call.

```julia
@template "emails/welcome.html" as WELCOME
render(WELCOME; user = "frank")
```
"""
macro template(args...)
    mod = __module__
    path_arg, name, cfg_expr = _parse_template_args(args)
    path_arg isa String || throw(ArgumentError("@template path must be a string literal"))
    cfg = cfg_expr === nothing ? Config() : Core.eval(mod, cfg_expr)
    cfg isa Config || throw(ArgumentError("@template config must evaluate to a Config"))
    abs_path = _resolve_template_path(path_arg, __source__)
    isfile(abs_path) || throw(ArgumentError("template not found: $abs_path"))
    const_name = name === nothing ? _default_name(path_arg) : name
    return esc(_compile_template(path_arg, abs_path, const_name, mod, cfg, __source__))
end

function _parse_template_args(args)
    isempty(args) && throw(ArgumentError("@template requires a path"))
    path = args[1]
    name = nothing
    cfg_expr = nothing
    i = 2
    while i <= length(args)
        arg = args[i]
        if arg === :as
            i += 1
            i <= length(args) || throw(ArgumentError("@template `as` requires a name"))
            name = args[i]
            name isa Symbol || throw(ArgumentError("@template name must be a symbol"))
        elseif arg isa Expr && arg.head === :(=) && arg.args[1] === :config
            cfg_expr = arg.args[2]
        else
            throw(ArgumentError("unexpected @template argument: $(repr(arg))"))
        end
        i += 1
    end
    return path, name, cfg_expr
end

function _default_name(path::AbstractString)
    stem = first(splitext(basename(path)))
    chars = [isletter(c) || isdigit(c) ? uppercase(c) : '_' for c in stem]
    return Symbol(String(chars))
end

function _resolve_template_path(path::AbstractString, source::LineNumberNode)
    isabspath(path) && return normpath(path)
    file = source.file
    base = (file === nothing || String(file) in ("none", "REPL")) ? pwd() : dirname(String(file))
    return normpath(joinpath(base, path))
end

function _compile_template(virtual_path::AbstractString, abs_path::AbstractString, name::Symbol, mod::Module, cfg::Config, source::LineNumberNode)
    unit = CompilationUnit(mod, cfg, _unit_id(cfg, virtual_path, source))
    root = compile_template!(unit, String(virtual_path), String(abs_path))
    registry_sym = Symbol("__ginger_sources_", unit.unit_id, "__")
    registry_def = Expr(:const, Expr(:(=), registry_sym, _sources_expr(unit.sources)))
    const_def = Expr(
        :const,
        Expr(
            :(=),
            name,
            Expr(
                :call, GlobalRef(Ginger, :Template),
                root.virtual_path, root.enter_sym,
                GlobalRef(mod, registry_sym), unit.cfg.source_root,
            ),
        ),
    )
    return Expr(:block, unit.defs..., registry_def, const_def)
end

# Emit the provenance registry as a typed `Dict` literal. Sorted by generated
# function name so macro expansion is deterministic.
function _sources_expr(sources::Dict{Symbol, SourceInfo})
    dict_type = Expr(:curly, GlobalRef(Base, :Dict), GlobalRef(Base, :Symbol), GlobalRef(Ginger, :SourceInfo))
    pairs = Any[
        Expr(:call, GlobalRef(Base, :Pair), QuoteNode(func), _sourceinfo_expr(sources[func]))
            for func in sort!(collect(keys(sources)))
    ]
    return Expr(:call, dict_type, pairs...)
end

function _sourceinfo_expr(info::SourceInfo)
    name = info.name === nothing ? nothing : QuoteNode(info.name)
    return Expr(:call, GlobalRef(Ginger, :SourceInfo), info.path, QuoteNode(info.kind), name)
end

function _fetchvar_expr(var::Symbol, virtual_path::String, undefined::Symbol)
    mode = Expr(:call, GlobalRef(Base, :Val), QuoteNode(undefined))
    return Expr(:call, GlobalRef(Ginger, :fetchvar), :ctx, mode, QuoteNode(var), virtual_path, 1)
end
