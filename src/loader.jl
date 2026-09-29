"""
    _discover_template_files(dir) -> Vector{String}

Recursively list every regular file under `dir`, sorted for deterministic
generated code, skipping hidden entries. Every directory visited and every file
found is registered with `Base.include_dependency`, so editing a template, adding
one, or removing one marks the host package stale and re-expands `@templates`.

`include_dependency` hashes a directory as `join(readdir(dir))`, so a new file in
a nested directory is caught only when that directory is registered. Registering
every directory in the tree, not just the root, is what makes adding a template
anywhere under the root invalidate the package.
"""
function _discover_template_files(dir::AbstractString)
    files = String[]
    _collect_template_files!(files, String(dir))
    return sort!(files)
end

function _collect_template_files!(files::Vector{String}, dir::String)
    Base.include_dependency(dir)
    for entry in readdir(dir; sort = true)
        startswith(entry, ".") && continue
        path = joinpath(dir, entry)
        if isdir(path)
            _collect_template_files!(files, path)
        elseif isfile(path)
            push!(files, path)
        end
    end
    return files
end

# --- directory tree ---------------------------------------------------------

"""
    _TemplateTree

A `@templates` directory becomes a nested `NamedTuple`: files are leaves and
subdirectories are branches. Building the tree first makes duplicate-name
detection and deterministic ordering straightforward.
"""
mutable struct _TemplateTree
    leaves::Dict{Symbol, Any}
    dirs::Dict{Symbol, _TemplateTree}
end

_TemplateTree() = _TemplateTree(Dict{Symbol, Any}(), Dict{Symbol, _TemplateTree}())

function _tree_insert!(root::_TemplateTree, comps::Vector{Symbol}, value)
    node = root
    for comp in comps[1:(end - 1)]
        haskey(node.leaves, comp) && throw(
            ArgumentError("template name `$(join(comps, '.'))` conflicts with a template file"),
        )
        node = get!(_TemplateTree, node.dirs, comp)
    end
    leaf = comps[end]
    (haskey(node.leaves, leaf) || haskey(node.dirs, leaf)) && throw(
        ArgumentError("duplicate template name `$(join(comps, '.'))`"),
    )
    node.leaves[leaf] = value
    return root
end

function _tree_expr(t::_TemplateTree)
    pairs = Any[]
    for key in sort!(collect(keys(t.leaves)))
        push!(pairs, Expr(:(=), key, t.leaves[key]))
    end
    for key in sort!(collect(keys(t.dirs)))
        push!(pairs, Expr(:(=), key, _tree_expr(t.dirs[key])))
    end
    return isempty(pairs) ? Expr(:call, GlobalRef(Base, :NamedTuple)) : Expr(:tuple, pairs...)
end

"""
    _template_name_components(rel) -> Vector{Symbol}

Map a path relative to the `@templates` root to `NamedTuple` keys: each
directory and the file stem becomes a sanitized symbol. `partials/head.html`
becomes `[:partials, :head]`.
"""
function _template_name_components(rel::AbstractString)
    parts = split(rel, r"[/\\]+")
    comps = Symbol[_field_symbol(p) for p in parts[1:(end - 1)]]
    push!(comps, _field_symbol(first(splitext(parts[end]))))
    return comps
end

"""
    _field_symbol(s) -> Symbol

Turn an arbitrary file or directory name into a usable property name. A name
that does not start with a letter or `_` receives a prefix, so `TPL.name` parses.
"""
function _field_symbol(s::AbstractString)
    io = IOBuffer()
    for c in s
        print(io, isletter(c) || isdigit(c) || c == '_' ? c : '_')
    end
    name = String(take!(io))
    isempty(name) && return :_
    (isletter(first(name)) || first(name) == '_') || (name = "_" * name)
    return Symbol(name)
end

"""
    _templates_virtual_path(root_arg, abs_dir, abs_file, source_root) -> String

Return the virtual path for one template. The path stays package-relative,
exactly as for `@template`. For an absolute root, fall back to the path relative
to the configured source root.
"""
function _templates_virtual_path(root_arg::AbstractString, abs_dir::AbstractString, abs_file::AbstractString, source_root::AbstractString)
    if isabspath(root_arg)
        rel = relpath(abs_file, source_root)
        return startswith(rel, "..") ? String(abs_file) : String(normpath(rel))
    end
    return String(normpath(joinpath(root_arg, relpath(abs_file, abs_dir))))
end

"""
    _compile_templates(virtual_root, abs_dir, name, mod, cfg, source) -> Expr

Compile every template under `abs_dir` into one `CompilationUnit` and return the
host-module block that defines the generated functions, the provenance registry,
and the `NamedTuple` const `name`.
"""
function _compile_templates(virtual_root::AbstractString, abs_dir::AbstractString, name::Symbol, mod::Module, cfg::Config, source::LineNumberNode; helpers::Vector{Module} = Module[])
    unit = CompilationUnit(mod, cfg, _unit_id(cfg, virtual_root, source); helpers = helpers)
    files = _discover_template_files(abs_dir)
    isempty(files) && throw(ArgumentError("@templates found no templates under $abs_dir"))
    tree = _TemplateTree()
    for file in files
        comps = _template_name_components(relpath(file, abs_dir))
        virtual_path = _templates_virtual_path(virtual_root, abs_dir, file, cfg.source_root)
        compiled = compile_template!(unit, virtual_path, file)
        _tree_insert!(tree, comps, _template_value_expr(unit, compiled))
    end
    _, registry_def = _registry_def(unit)
    const_def = Expr(:const, Expr(:(=), name, _tree_expr(tree)))
    return Expr(:block, unit.defs..., registry_def, const_def)
end
