"""
    Ginger

A Jinja-style template engine that compiles templates to Julia code during
macro expansion. Rendering is plain, type-specialized Julia: there is no runtime
parsing, no runtime compilation, and no generated modules at runtime.

See `PLAN.md` for the full design. The current implementation covers milestone
M2: single-file rendering with the full Julia control-flow surface, inferred
context, HTML escaping, and the `DefaultHelpers` filter library.
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
include("normalize.jl")
include("macros.jl")
include("api.jl")

export @template, Template, render, render!, Config, HTMLString, escape, safe, default
export DefaultHelpers

end # module Ginger
