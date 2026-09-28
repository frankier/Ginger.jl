using Test
using Ginger

const G = Ginger

@template "templates/err.html" as ERRT

@testset "errors: compile-time syntax" begin
    @test_throws G.TemplateSyntaxError G.synthesize("{{ x ", "t.html", Config())

    syn = G.synthesize("a\n{{ 1 + }}\n", "t.html", Config())
    err = try
        G.parse_source(syn, "t.html")
        nothing
    catch e
        e
    end
    @test err isa G.TemplateSyntaxError
    @test err.pos !== nothing
    @test err.pos.file == "t.html"
    @test err.pos.line == 2
end

@testset "errors: runtime template provenance" begin
    frames = try
        render(ERRT)
        nothing
    catch
        stacktrace(catch_backtrace())
    end
    @test frames !== nothing
    @test any(fr -> occursin("err.html", string(fr.file)), frames)
end
