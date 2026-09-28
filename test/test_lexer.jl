using Test
using Ginger

const G = Ginger

function tokenize(src; cfg = Config())
    lx = G.Lexer(src, "t.html", cfg)
    tokens = G.Token[]
    while (tok = G.next_token!(lx)) !== nothing
        push!(tokens, tok)
    end
    return tokens
end

@testset "lexer: text" begin
    toks = tokenize("hello world")
    @test length(toks) == 1
    @test toks[1].kind == G.TEXT
    @test toks[1].text == "hello world"
    @test toks[1].pos == G.Pos("t.html", 1, 1, 1)
end

@testset "lexer: expression and statement" begin
    toks = tokenize("a{{ x }}b")
    @test [t.kind for t in toks] == [G.TEXT, G.EXPRESSION, G.TEXT]
    @test toks[2].text == "x"
    @test toks[2].pos == G.Pos("t.html", 1, 2, 2)
    @test toks[3].text == "b"

    toks = tokenize("{% x = 1 %}")
    @test length(toks) == 1
    @test toks[1].kind == G.STATEMENT
    @test toks[1].text == "x = 1"
end

@testset "lexer: positions across lines" begin
    toks = tokenize("ab\n{{ x }}")
    @test toks[2].pos.line == 2
    @test toks[2].pos.col == 1
end

@testset "lexer: whitespace control flags" begin
    tok = tokenize("{{- x +}}")[1]
    @test tok.lstrip && tok.rkeep
    @test !tok.lkeep && !tok.rstrip

    tok = tokenize("{{+ x -}}")[1]
    @test tok.lkeep && tok.rstrip
end

@testset "lexer: comments" begin
    toks = tokenize("{# a comment #}")
    @test length(toks) == 1
    @test toks[1].kind == G.COMMENT
    @test toks[1].text == "a comment"

    toks = tokenize("a{# nested {# inner #} tail #}b")
    @test [t.kind for t in toks] == [G.TEXT, G.COMMENT, G.TEXT]
    @test toks[2].text == "nested {# inner #} tail"
end

@testset "lexer: quote- and bracket-aware scanning" begin
    @test tokenize("{{ \"}}\" }}")[1].text == "\"}}\""
    @test tokenize("{{ raw\"}}\" }}")[1].text == "raw\"}}\""
    @test tokenize("{{ '}' }}")[1].text == "'}'"
    @test tokenize("{{ '\\n' }}")[1].text == "'\\n'"
    @test tokenize("{{ `echo }}` }}")[1].text == "`echo }}`"
    @test tokenize("{{ f(\"a}}b\") }}")[1].text == "f(\"a}}b\")"
    @test tokenize("{{ f(a[1], \"}\") }}")[1].text == "f(a[1], \"}\")"
    @test tokenize("{{ A' }}")[1].text == "A'"
    @test tokenize("{% X = \"%}\" %}")[1].text == "X = \"%}\""
end

@testset "lexer: custom delimiters" begin
    toks = tokenize("a<< x >>b"; cfg = Config(expression_start = "<<", expression_end = ">>"))
    @test [t.kind for t in toks] == [G.TEXT, G.EXPRESSION, G.TEXT]
    @test toks[2].text == "x"
end

@testset "lexer: errors" begin
    err = try
        tokenize("{{ x ")
        nothing
    catch e
        e
    end
    @test err isa G.TemplateSyntaxError
    @test err.pos !== nothing
    @test err.pos.line == 1
end

@testset "lexer: raw" begin
    toks = tokenize("a{% raw %}{{ x }} {% if %}{% endraw %}b")
    @test [t.kind for t in toks] == [G.TEXT, G.RAW, G.TEXT]
    @test toks[1].text == "a"
    @test toks[2].text == "{{ x }} {% if %}"
    @test toks[3].text == "b"

    toks = tokenize("x   {%- raw -%}   y   {%- endraw -%}   z")
    @test toks[2].text == "y"

    # Other tags inside a raw body are literal text, not structure.
    toks = tokenize("{% raw %}{% if x %}y{% endraw %}")
    @test toks[1].kind == G.RAW
    @test toks[1].text == "{% if x %}y"
    toks = tokenize("{% raw %}{% {% endraw %}")
    @test toks[1].text == "{% "

    @test_throws G.TemplateSyntaxError tokenize("a{% raw %}b")
end
