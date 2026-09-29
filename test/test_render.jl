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
@template "templates/forelse.html" as FORELSE
@template "templates/nested.html" as NESTED
@template "templates/whileloop.html" as WHILELOOP
@template "templates/letblock.html" as LETBLOCK
@template "templates/func.html" as FUNC
@template "templates/trycatch.html" as TRYCATCH
@template "templates/do.html" as DO
@template "templates/raw.html" as RAW
@template "templates/rawtrim.html" as RAWTRIM
@template "templates/comment2.html" as COMMENT2
@template "templates/fileinfo.html" as FILEINFO

const INLINE = ginger"Hello {{ name }}!"
const INLINE_CONTROL = ginger"{% for x in xs %}[{{ x }}]{% end %}"

@testset "render: inline string macro" begin
    @test INLINE isa Template
    @test render(INLINE; name = "frank") == "Hello frank!"
    @test INLINE(name = "frank") == "Hello frank!"
    @test INLINE(; name = "<b>") == "Hello &lt;b&gt;!"
    @test render(INLINE_CONTROL; xs = [1, 2, 3]) == "[1][2][3]"
end

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
    err = try
        render(STRICT)
        nothing
    catch e
        e
    end
    @test err isa Ginger.TemplateError
    @test err.cause isa Ginger.MissingContextVariable
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

@testset "render: for/else" begin
    @test render(FORELSE; items = ["a", "b"]) == "[a][b]"
    @test render(FORELSE; items = String[]) == "empty"
end

@testset "render: nested control flow" begin
    @test render(NESTED; items = [1, 2, 3]) == "1-3"
    @test render(NESTED; items = Int[]) == ""
end

@testset "render: while and let" begin
    @test render(WHILELOOP; limit = 3) == "012"
    @test render(WHILELOOP; limit = 0) == ""
    @test render(LETBLOCK) == "3"
end

@testset "render: functions and try/catch" begin
    @test render(FUNC; name = "Ann") == "<b>Ann</b>"
    @test render(TRYCATCH) == "caught"
end

@testset "render: do blocks" begin
    @test render(DO; items = ["a", "b"]) == "[a][b]"
end

@testset "render: raw" begin
    @test render(RAW) == "a{{ x }} {% if %}b"
    @test render(RAWTRIM) == "xyz"
end

@testset "render: multiline comments" begin
    @test render(COMMENT2) == "a\nb"
end

@testset "render: virtual path" begin
    @test render(FILEINFO) == "templates/fileinfo.html"
end
