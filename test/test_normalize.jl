using Test
using Ginger

const G = Ginger

# Escape elision reads `cfg`, `virtual_path`, and `safe_names` from a
# `NormalizeState`. Build a minimal one without compiling a template.
function normalize_state(; autoescape::Bool = true, safe::Vector{Symbol} = Symbol[])
    cfg = Config(autoescape = autoescape)
    syn = G.synthesize("", "t.html", cfg)
    st = G.NormalizeState(
        G.CompilationUnit(Main, cfg, "test"), cfg, "t.html", "t.html", syn, "id",
        nothing, G.MacroInfo[], G.BlockInfo[], Pair{Symbol, Any}[], nothing, Set{Symbol}(),
    )
    union!(st.safe_names, safe)
    return st
end

@testset "normalize: escape elision" begin
    st = normalize_state(safe = [:greet, :forms])

    # Values that are statically known to be `HTMLString`.
    @test G._statically_safe(:(safe(x)), st)
    @test G._statically_safe(:(escape(x)), st)
    @test G._statically_safe(:(HTMLString(x)), st)
    @test G._statically_safe(:(greet(x)), st)
    @test G._statically_safe(:(forms.field(x)), st)
    @test G._statically_safe(:(Ginger.safe(x)), st)
    @test G._statically_safe(:(__ginger_super__(1, p)), st)

    # Values whose outermost call is not known to return `HTMLString`.
    @test !G._statically_safe(:(upper(x)), st)
    @test !G._statically_safe(:greet, st)
    @test !G._statically_safe(:(safe(x) |> upper), st)
    @test !G._statically_safe(:(greet(x) * "!"), st)
    @test !G._statically_safe(:(forms.field(x)), normalize_state())

    # The autoescape wrapper is dropped only for a safe value.
    safe_call = G._print_call(:(greet(x)), st)
    @test !occursin("escape", string(safe_call))
    unsafe_call = G._print_call(:(upper(x)), st)
    @test occursin("escape", string(unsafe_call))

    # With autoescaping off there is never an `escape` wrapper.
    raw_call = G._print_call(:(upper(x)), normalize_state(autoescape = false))
    @test !occursin("escape", string(raw_call))
end
