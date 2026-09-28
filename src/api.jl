"""
    render(template; kwargs...) -> String

Render `template` to a `String`. Keyword arguments make up the render context.
"""
function render(template::Template; kwargs...)
    out = IOBuffer()
    template.entry(out; kwargs...)
    return String(take!(out))
end

"""
    render!(io, template; kwargs...) -> io

Render `template` to `io`.
"""
function render!(io::IO, template::Template; kwargs...)
    template.entry(io; kwargs...)
    return io
end

(template::Template)(io::IO; kwargs...) = render!(io, template; kwargs...)
(template::Template)(; kwargs...) = render(template; kwargs...)
