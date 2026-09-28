using Test
using Ginger
using Ginger.DefaultHelpers

const G = Ginger
const DH = Ginger.DefaultHelpers

# A host-module helper is callable from a template with no registry.
banner(x) = "[" * string(x) * "]"

@template "templates/filters.html" as FILTERS
@template "templates/filters_curried.html" as FILTERSCURRIED config = Config(undefined = :lenient)
@template "templates/filters_chained.html" as FILTERSCHAINED
@template "templates/filters_safe.html" as FILTERSSAFE
@template "templates/filters_autoescape.html" as FILTERSRAW config = Config(autoescape = false)
@template "templates/helpers.html" as HELPERS

@testset "filters: one-argument helpers" begin
    @test render(FILTERS) == "&lt;B&gt;|&lt;b&gt;|Hello World|Hello|x"
end

@testset "filters: curried helpers" begin
    @test render(FILTERSCURRIED) == "abcd…|abc|heLLo|a, b|n/a"
end

@testset "filters: chaining and Base.Fix1" begin
    @test render(FILTERSCHAINED) == "The &lt;b&gt;title&lt;/b&gt;|abcde|true|true"
end

@testset "filters: escape and safe" begin
    @test render(FILTERSSAFE) == "<B>X</B>|&lt;B&gt;|<b>"
    @test escape(safe("<b>")) == safe("<b>")
    @test safe(escape("<b>")) == escape("<b>")
end

@testset "filters: autoescape off" begin
    @test render(FILTERSRAW) == "<B>|<b>"
end

@testset "filters: host-module helper" begin
    @test render(HELPERS; name = "Frank") == "[Frank]"
end

@testset "helpers: direct calls" begin
    @test DH.upper("<b>") == "<B>"
    @test DH.lower("<B>") == "<b>"
    @test DH.title("hello world") == "Hello World"
    @test DH.capitalize("hello") == "Hello"
    @test DH.trim("  x  ") == "x"

    @test DH.excerpt(4)("abcdefghij") == "abcd…"
    @test DH.excerpt(20)("abc") == "abc"
    @test_throws ArgumentError DH.excerpt(-1)

    @test DH.truncate_at(2) isa Base.Fix2
    @test DH.truncate_at(2)([1, 2, 3]) == [1, 2]
    @test DH.truncate_at(2)("abcdefghij") == "ab"

    @test DH.starts_with("ab") isa Base.Fix2
    @test DH.starts_with("ab")("abcdefghij")
    @test !DH.starts_with("xy")("abcdefghij")

    @test DH.replace_with("a", "b")("banana") == "bbnbnb"
    @test DH.replace_with("a")("banana") == "bnn"

    @test DH.join_with("-")([1, 2, 3]) == "1-2-3"
    @test DH.join_with()([1, 2, 3]) == "123"

    @test DH.default_to("x")(G.Undefined(:a, "t.html", 1)) == "x"
    @test DH.default_to("x")("v") == "v"
end

@testset "helpers: shared runtime values" begin
    @test DH.HTMLString === G.HTMLString
    @test DH.escape === G.escape
    @test DH.safe === G.safe
    @test DH.default === G.default
end
