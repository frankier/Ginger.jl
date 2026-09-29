using Aqua
using CheckConcreteStructs
using JET

# `TemplateError.cause` deliberately holds whatever was thrown, which is not
# necessarily an `Exception`, so it is exempt from the concrete-field check.
const ABSTRACT_FIELD_EXEMPT = (TemplateError,)

"""
Check every type defined in `mod` for concretely typed fields, skipping the
`exempt` types. `CheckConcreteStructs.all_concrete` has no exclusion API, so the
module walk is repeated here.
"""
function all_concrete_except(mod::Module, exempt)
    ok = true
    for name in names(mod; all = true)
        T = getproperty(mod, name)
        T isa Type || continue
        T isa Union && continue
        isabstracttype(T) && continue
        parentmodule(T) === mod || continue
        T in exempt && continue
        all_concrete(T; verbose = true) || (ok = false)
    end
    return ok
end

@testset "Code quality" begin
    @testset "CheckConcreteStructs" begin
        @test all_concrete_except(Ginger, ABSTRACT_FIELD_EXEMPT)
    end

    @testset "Aqua" begin
        Aqua.test_all(Ginger)
    end

    @testset "JET" begin
        JET.test_package(Ginger; target_modules = (Ginger,), toplevel_logger = nothing)
    end
end
