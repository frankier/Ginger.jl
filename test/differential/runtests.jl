# Differential comparison against OteraEngine (dev-only).
#
# Run with:
#
#     julia --project=test/differential test/differential/runtests.jl
#
# This environment is deliberately separate from the package's test target so
# that `Pkg.test()` does not depend on a third-party template engine. It renders
# the overlapping subset of the syntax with both engines and asserts identical
# output.

using Test
using Ginger
import OteraEngine

const TEMPLATE_DIR = joinpath(@__DIR__, "templates")

module DiffTemplates
    using Ginger
    using Ginger.DefaultHelpers
    # Match OteraEngine's default whitespace handling (`autospace` = trim + lstrip).
    @templates "templates" as TPL config = Config(autospace = true)
end

otera_template(name) = OteraEngine.Template(joinpath(TEMPLATE_DIR, name))

ginger_render(name; kwargs...) =
    render(getproperty(DiffTemplates.TPL, Symbol(first(splitext(name)))); kwargs...)

otera_render(name; kwargs...) = otera_template(name)(init = Dict{Symbol, Any}(kwargs))

@testset "differential vs OteraEngine" begin
    cases = [
        ("plain.html", (name = "Frank",)),
        ("escape.html", (value = "<b>",)),
        ("cond.html", (flag = true,)),
        ("cond.html", (flag = false,)),
        ("loop.html", (items = ["a", "b", "c"],)),
        ("upper.html", (name = "frank",)),
        ("include.html", (x = "V",)),
        ("page.html", (heading = "T",)),
        ("macro.html", ()),
    ]
    for (name, kwargs) in cases
        ginger = ginger_render(name; kwargs...)
        otera = otera_render(name; kwargs...)
        @test ginger == otera
    end
end
