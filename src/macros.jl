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

"""
    ginger"source"

Compile an inline template string during macro expansion and return a
[`Template`](@ref) value. The string must be a literal. The template is compiled
with the default [`Config`](@ref); any reference (`{% include %}`, …) resolves
relative to the file that contains the macro call.

Because the source is part of the host package's AST, an inline template is
precompiled like a file-based one and needs no `include_dependency` entry.

```julia
t = ginger"Hello {{ name }}!"
t(name = "frank")          # -> "Hello frank!"
render(t; name = "frank")
```
"""
macro ginger_str(s)
    s isa String || throw(ArgumentError("ginger\"…\" requires a string literal"))
    mod = __module__
    cfg = Config()
    virtual_path = "<inline>"
    abs_path = _resolve_template_path(virtual_path, __source__)
    unit = CompilationUnit(mod, cfg, _unit_id(cfg, virtual_path, __source__))
    compiled = _compile_inline!(unit, virtual_path, abs_path, s)
    _, registry_def = _registry_def(unit)
    return esc(Expr(:block, unit.defs..., registry_def, _template_value_expr(unit, compiled)))
end

# Compile a source string that is not backed by a file. Shares the pipeline with
# file-based templates; only the dependency registration and error-source
# attachment differ.
function _compile_inline!(unit::CompilationUnit, virtual_path::String, abs_path::String, src::String)
    try
        return _compile_source!(unit, virtual_path, abs_path, src)
    catch err
        if err isa TemplateSyntaxError && err.source === nothing &&
                err.pos !== nothing && err.pos.file == virtual_path
            throw(TemplateSyntaxError(err.msg, err.pos, src))
        end
        rethrow()
    end
end

"""
    @templates path [as NAME] [config = CONFIG] [helpers = (Mod, …)]

Compile every template under the directory `path` during macro expansion and
bind a `NamedTuple` of `Template`s to `NAME` (default `TEMPLATES`) in the host
module. Subdirectories become nested `NamedTuple`s, and a file's key is its file
stem, so `views/partials/head.html` is reached as `TPL.partials.head`.

Every file and every directory under `path` is read at expansion time and
registered with `Base.include_dependency`, so editing a template, adding one, or
removing one invalidates the host package and re-expands the macro. References
(`{% extends %}`, `{% include %}`, `{% import %}`, `{% from %}`) are resolved
inside the set, and a shared template is compiled once.

`helpers = (MyHelpers, MyFilters)` emits `using MyHelpers, MyFilters` into the
host module before the templates are compiled, so helper functions and macros are
available to every template. The entries are module names, not values.

```julia
@templates "templates" as TPL
@templates "templates" helpers = (MyHelpers,) config = Config(autoescape = false)
render(TPL.index; user = "frank")
```
"""
macro templates(args...)
    mod = __module__
    path_arg, name, cfg_expr, helpers_expr = _parse_templates_args(args)
    path_arg isa String || throw(ArgumentError("@templates path must be a string literal"))
    cfg = cfg_expr === nothing ? Config() : Core.eval(mod, cfg_expr)
    cfg isa Config || throw(ArgumentError("@templates config must evaluate to a Config"))
    abs_dir = _resolve_template_path(path_arg, __source__)
    isdir(abs_dir) || throw(ArgumentError("template directory not found: $abs_dir"))
    # Resolve the helper modules now so the scope pass can treat their exported
    # names as host globals. A `using` applied during expansion would not be
    # visible to `isdefined` until the enclosing top-level statement completes,
    # so the emitted `using` is what makes the bare names resolve at runtime.
    helper_mods = helpers_expr === nothing ? Module[] : _helper_modules(mod, helpers_expr)
    using_expr = _helpers_using_expr(helpers_expr)
    const_name = name === nothing ? :TEMPLATES : name
    body = _compile_templates(path_arg, abs_dir, const_name, mod, cfg, __source__; helpers = helper_mods)
    return using_expr === nothing ? esc(body) : esc(Expr(:block, using_expr, body.args...))
end

function _parse_templates_args(args)
    isempty(args) && throw(ArgumentError("@templates requires a path"))
    path = args[1]
    name = nothing
    cfg_expr = nothing
    helpers_expr = nothing
    i = 2
    while i <= length(args)
        arg = args[i]
        if arg === :as
            i += 1
            i <= length(args) || throw(ArgumentError("@templates `as` requires a name"))
            name = args[i]
            name isa Symbol || throw(ArgumentError("@templates name must be a symbol"))
        elseif arg isa Expr && arg.head === :(=) && arg.args[1] === :config
            cfg_expr = arg.args[2]
        elseif arg isa Expr && arg.head === :(=) && arg.args[1] === :helpers
            helpers_expr = arg.args[2]
        else
            throw(ArgumentError("unexpected @templates argument: $(repr(arg))"))
        end
        i += 1
    end
    return path, name, cfg_expr, helpers_expr
end

# `helpers = (A, B)` or `helpers = A` becomes `using A, B`. Each entry must be a
# module name (a bare symbol or a dotted path), not a value.
function _helpers_using_expr(helpers_expr)
    helpers_expr === nothing && return nothing
    mods = helpers_expr isa Expr && helpers_expr.head === :tuple ? helpers_expr.args : Any[helpers_expr]
    isempty(mods) && return nothing
    return Expr(:using, (_using_item(m) for m in mods)...)
end

function _using_item(m)
    m isa Symbol && return Expr(:., m)
    m isa Expr && m.head === :. && return _using_path(m)
    throw(ArgumentError("`helpers` entries must be module names, got $(repr(m))"))
end

# A dotted expression (`Main.Helpers`) carries `QuoteNode` field names, but a
# `using` path wants plain symbols, so strip the quotes.
function _using_path(e::Expr)
    args = Any[a isa QuoteNode && a.value isa Symbol ? a.value : a for a in e.args]
    return Expr(:., args...)
end

# Evaluate the `helpers` expression to the modules themselves, for the scope
# pass. The expression must name modules, not arbitrary values.
function _helper_modules(mod::Module, helpers_expr)
    value = Core.eval(mod, helpers_expr)
    entries = value isa Tuple ? value : (value,)
    mods = Module[]
    for entry in entries
        entry isa Module || throw(ArgumentError("`helpers` entries must be modules, got $(repr(entry))"))
        push!(mods, entry)
    end
    return mods
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
    registry_sym, registry_def = _registry_def(unit)
    const_def = Expr(:const, Expr(:(=), name, _template_value_expr(unit, root)))
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
