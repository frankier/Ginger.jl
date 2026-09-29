const _GINGER_SRC_DIR = dirname(@__FILE__)

"""
    render(template; kwargs...) -> String

Render `template` to a `String`. Keyword arguments make up the render context.

If rendering throws and the native backtrace contains at least one generated
template function, the exception is wrapped in a [`TemplateError`](@ref) that
carries the include/extends provenance chain. Otherwise the original exception
propagates unchanged.
"""
function render(template::Template; kwargs...)
    out = IOBuffer()
    try
        template.entry(out; kwargs...)
    catch err
        _throw_template_error(template, err)
    end
    return String(take!(out))
end

"""
    render!(io, template; kwargs...) -> io

Render `template` to `io`. Errors are wrapped as for [`render`](@ref).
"""
function render!(io::IO, template::Template; kwargs...)
    try
        template.entry(io; kwargs...)
    catch err
        _throw_template_error(template, err)
    end
    return io
end

(template::Template)(io::IO; kwargs...) = render!(io, template; kwargs...)
(template::Template)(; kwargs...) = render(template; kwargs...)

"""
    _throw_template_error(template, err)

Wrap `err` in a `TemplateError` with the recovered provenance chain. This
function runs inside a `catch`, so `catch_backtrace()` and `rethrow()` refer to
the exception being handled. An error with no template frame is not ours to
wrap.
"""
function _throw_template_error(template::Template, err)
    err isa TemplateError && rethrow()
    chain = _template_chain(template, catch_backtrace())
    isempty(chain) && rethrow()
    throw(TemplateError(err, chain))
end

"""
    template_backtrace(err::TemplateError) -> Vector{TemplateFrame}
    template_backtrace() -> Vector{TemplateFrame}

Return the structured provenance chain of a [`TemplateError`](@ref): one
[`TemplateFrame`](@ref) per generated body, block, or macro that took part in
the failing render, innermost first, followed by the host call site of `render`.
Each frame carries the package-relative `path` and the same path resolved to an
absolute `abs_path` under the template's `Config.source_root`.

The no-argument form returns the chain of the `TemplateError` currently being
handled, or an empty vector when there is none.
"""
template_backtrace(e::TemplateError) = e.chain

function template_backtrace()
    for (exc, _) in Base.current_exceptions()
        exc isa TemplateError && return exc.chain
    end
    return TemplateFrame[]
end

"""
    _template_chain(template, bt) -> Vector{TemplateFrame}

Recover the provenance chain from a native backtrace. Generated functions are
registered in the compilation unit's `sources` under their own names, which is
what `StackFrame.func` reports for them.
"""
function _template_chain(template::Template, bt)
    frames = stacktrace(bt)
    chain = TemplateFrame[]
    last_template = 0
    for (i, fr) in enumerate(frames)
        info = get(template.sources, fr.func, nothing)
        info === nothing && continue
        last_template = i
        line = fr.line > 0 ? Int(fr.line) : 1
        push!(
            chain,
            TemplateFrame(
                info.kind, info.name, info.path,
                _abs_source_path(template.source_root, info.path), line, 0,
            ),
        )
    end
    # The first host frame above the outermost template frame is the `render`
    # call site. Frames below the error site (for example `error` in Base) are
    # skipped by starting after the last template frame, and unregistered
    # generated functions (the entry function) are skipped by file.
    template_paths = Set(info.path for info in values(template.sources))
    for i in (last_template + 1):length(frames)
        fr = frames[i]
        get(template.sources, fr.func, nothing) === nothing || continue
        file = string(fr.file)
        (normpath(file) in template_paths || startswith(file, _GINGER_SRC_DIR)) && continue
        line = fr.line > 0 ? Int(fr.line) : 0
        push!(chain, TemplateFrame(:render, nothing, file, file, line, 0))
        break
    end
    return chain
end

function _abs_source_path(source_root::AbstractString, virtual_path::AbstractString)
    isempty(virtual_path) && return ""
    isabspath(virtual_path) && return String(virtual_path)
    return normpath(joinpath(source_root, virtual_path))
end
