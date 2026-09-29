"""
    Ginger

A Jinja-style template engine that compiles templates to Julia code during
macro expansion. Rendering is plain, type-specialized Julia: there is no runtime
parsing, no runtime compilation, and no generated modules at runtime.

See `PLAN.md` for the full design. The current implementation covers milestone
M7: single-file rendering with the full Julia control-flow surface, inferred
context, HTML escaping with compile-time escape elision, the `DefaultHelpers`
filter library, template composition through `{% macro %}`, `{% include %}`,
`{% import %}`, and `{% from %}`, static inheritance through `{% extends %}`,
`{% block %}`, and `super()` / `super(n)`, provenance diagnostics (caret
`TemplateSyntaxError`s, a compile-time provenance registry, `TemplateError`, and
`template_backtrace`), and `@templates` directory discovery with
precompilation-aware dependency tracking. The public API is frozen at 1.0.
"""
module Ginger

import MacroTools

include("config.jl")
include("errors.jl")
include("runtime.jl")
include("helpers.jl")
include("lexer.jl")
include("synthesize.jl")
include("parse.jl")
include("scope.jl")
include("compose.jl")
include("normalize.jl")
include("loader.jl")
include("macros.jl")
include("api.jl")

export @template, @templates, @ginger_str, Template, render, render!, Config, HTMLString, escape, safe, default

export TemplateSyntaxError, TemplateError, TemplateFrame, MissingContextVariable
export template_backtrace

export DefaultHelpers

end # module Ginger
