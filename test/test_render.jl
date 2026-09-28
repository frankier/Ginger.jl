using Test
using Ginger

@template "templates/hello.html" as HELLO
@template "templates/escape.html" as ESCAPE
@template "templates/escape.html" as RAWESCAPE config = Config(autoescape = false)
@template "templates/stmt.html" as STMT
@template "templates/loop.html" as LOOP
@template "templates/cond.html" as COND
@template "templates/ws.html" as WS
@template "templates/comment.html" as COMMENT
@template "templates/quoted.html" as QUOTED
@template "templates/multiline.html" as MULTILINE
@template "templates/undef.html" as LENIENT config = Config(undefined = :lenient)
@template "templates/undef.html" as STRICT config = Config(undefined = :strict)
@template "templates/defaultname.html"

@testset "render: text and context" begin
    @test render(HELLO; name = "Frank") == "Hello, Frank!"
    @test render(HELLO; name = "Wo<rld") == "Hello, Wo&lt;rld!"
end

@testset "render: escaping and safe" begin
    @test render(ESCAPE; value = "<b>") == "&lt;b&gt;|<b>|<b>"
    @test render(RAWESCAPE; value = "<b>") == "<b>|<b>|<b>"

    @test escape("<b>") == HTMLString("&lt;b&gt;")
    @test escape(escape("<b>")) == escape("<b>")
    @test escape(safe("<b>")) == safe("<b>")
    @test safe("<b>") isa HTMLString
    @test string(safe("<b>")) == "<b>"
end

@testset "render: statements and control flow" begin
    @test render(STMT) == "x=5"
    @test render(LOOP; items = ["a", "b"]) == "<li>a</li><li>b</li>"
    @test render(COND; flag = true) == "Y"
    @test render(COND; flag = false) == "N"
end

@testset "render: whitespace and comments" begin
    @test render(WS; v = 7) == "a7b"
    @test render(COMMENT) == "ab"
end

@testset "render: quote-aware delimiters" begin
    @test render(QUOTED) == "}}|x}}y|1"
end

@testset "render: multiline" begin
    @test render(MULTILINE; name = "Bob") == "line one\nline two Bob\nline three"
end

@testset "render: undefined modes" begin
    @test render(LENIENT) == "[]"
    @test_throws Ginger.MissingContextVariable render(STRICT)
    @test default(Ginger.Undefined(:x, "t.html", 1), "fallback") == "fallback"
    @test default("value", "fallback") == "value"
end

@testset "render: io and callable template" begin
    io = IOBuffer()
    @test render!(io, HELLO; name = "x") === io
    @test String(take!(io)) == "Hello, x!"
    @test HELLO(; name = "y") == "Hello, y!"
    @test HELLO(io; name = "z") === io
    @test String(take!(io)) == "Hello, z!"
end

@testset "render: default template name" begin
    @test render(DEFAULTNAME) == "default name"
end
