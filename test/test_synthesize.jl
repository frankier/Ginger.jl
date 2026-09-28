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

@testset "synthesize: for/else lowering" begin
    syn = G.synthesize("{% for x in xs %}a{% else %}e{% endfor %}", "t.html", Config())
    @test occursin("let __ginger_ran_1__ = false", syn.source)
    @test occursin("if !__ginger_ran_1__", syn.source)
    @test !occursin("else", syn.source)

    syn = G.synthesize("{% if x %}a{% else %}b{% endif %}", "t.html", Config())
    @test occursin("else", syn.source)
    @test !occursin("__ginger_ran", syn.source)
end

@testset "synthesize: raw" begin
    syn = G.synthesize("a{% raw %}{{ x }}{% endraw %}b", "t.html", Config())
    @test occursin("print(out, \"a\")", syn.source)
    @test occursin("print(out, \"{{ x }}\")", syn.source)
    @test occursin("print(out, \"b\")", syn.source)
    @test !occursin("__ginger_print__", syn.source)
end

@testset "synthesize: template-only tags" begin
    syn = G.synthesize("{% macro f(a, b = 1) %}x{% endmacro %}", "t.html", Config())
    @test occursin("__ginger_macro__(:f, (a, b = 1) -> begin", syn.source)
    @test occursin("end)", syn.source)

    syn = G.synthesize("{% macro g() %}x{% endmacro %}", "t.html", Config())
    @test occursin("__ginger_macro__(:g, () -> begin", syn.source)

    syn = G.synthesize("{% include \"x.html\" %}", "t.html", Config())
    @test occursin("__ginger_include__(\"x.html\")", syn.source)

    syn = G.synthesize("{% include \"x.html\" with a=1 %}", "t.html", Config())
    @test occursin("__ginger_include__(\"x.html\"; a=1)", syn.source)

    syn = G.synthesize("{% import \"x.html\" as m %}", "t.html", Config())
    @test occursin("__ginger_import__(:m, \"x.html\")", syn.source)

    syn = G.synthesize("{% from \"x.html\" import a, b as c %}", "t.html", Config())
    @test occursin("__ginger_fromimport__(\"x.html\", (a = :a, c = :b,))", syn.source)
end

@testset "synthesize: macro restrictions" begin
    @test_throws G.TemplateSyntaxError G.synthesize("{% macro f() %}x", "t.html", Config())
    @test_throws G.TemplateSyntaxError G.synthesize(
        "{% if true %}{% macro f() %}x{% endmacro %}{% endif %}", "t.html", Config(),
    )
    @test_throws G.TemplateSyntaxError G.synthesize("{% import \"x\" %}", "t.html", Config())
end

@testset "synthesize: structural restrictions" begin
    @test_throws G.TemplateSyntaxError G.synthesize("{% for x in xs %}hi", "t.html", Config())
    @test_throws G.TemplateSyntaxError G.synthesize("{% if x %}hi", "t.html", Config())

    err = try
        G.synthesize("{% for x in xs %}hi", "t.html", Config())
        nothing
    catch e
        e
    end
    @test err isa G.TemplateSyntaxError
    @test occursin("unclosed", err.msg)
    @test err.pos.line == 1
end
