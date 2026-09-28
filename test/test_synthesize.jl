using Test
using Ginger

const G = Ginger

@testset "synthesize: text repr safety" begin
    src = "quotes \" backslash \\ dollar \$ newline\nend"
    syn = G.synthesize(src, "t.html", Config())
    @test occursin("print(out, ", syn.source)
    @test length(syn.map.entries) == 1
    @test G.parse_source(syn, "t.html") isa Expr
end

@testset "synthesize: offset map" begin
    syn = G.synthesize("a\n{{ x }}", "t.html", Config())
    @test G.line_map(syn.map) == [1, 2]
    @test length(G.line_map(syn.map)) == length(syn.map.entries)
    @test G.lookup(syn.map, 0).line == 1
    @test G.lookup(syn.map, 0).file == "t.html"
    @test G.lookup(syn.map, ncodeunits(syn.source)).line == 2
end

@testset "synthesize: whitespace control" begin
    syn = G.synthesize("a   {{- v -}}   b", "t.html", Config())
    @test occursin("print(out, \"a\")", syn.source)
    @test occursin("print(out, \"b\")", syn.source)

    syn = G.synthesize("a\n   {% if true %}X{% end %}", "t.html", Config(lstrip_blocks = true))
    @test occursin("print(out, \"a\\n\")", syn.source)

    syn = G.synthesize("{% if true %}\nX{% end %}", "t.html", Config(trim_blocks = true))
    @test occursin("print(out, \"X\")", syn.source)

    syn = G.synthesize("{% if true +%}\nX{% end %}", "t.html", Config(trim_blocks = true))
    @test occursin("print(out, \"\\nX\")", syn.source)
end
