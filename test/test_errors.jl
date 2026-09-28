using Test
using Ginger

const G = Ginger
const TEST_DIR = @__DIR__

@template "templates/err.html" as ERRT
@template "templates/err.html" as ERRT_ROOT config = Config(source_root = TEST_DIR)
@template "templates/err2.html" as ERRT2
@template "templates/errloop.html" as ERRTLOOP
@template "templates/err_child.html" as ERR_CHILD
@template "templates/err_macro.html" as ERR_MACRO
@template "templates/err_include_main.html" as ERR_INC

macro_error(path, name) =
try
    macroexpand(@__MODULE__, :(@template $path as $name))
    nothing
catch e
    e
end

# Offset of the caret from the rendered gutter, in template columns.
function caret_column(out)
    for line in split(out, '\n')
        i = findfirst('^', line)
        i === nothing && continue
        bar = findfirst('|', line)
        return i - bar - 1
    end
    return nothing
end

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

@testset "errors: line rewriting through control flow" begin
    syn = G.synthesize("a\n{% for x in xs %}\n{{ 1 + }}\n{% endfor %}", "t.html", Config())
    err = try
        G.parse_source(syn, "t.html")
        nothing
    catch e
        e
    end
    @test err isa G.TemplateSyntaxError
    @test err.pos.line == 3
end

@testset "errors: caret diagnostics" begin
    err = macro_error("templates/syntax_err.html", :SYNTAXERR)
    @test err isa G.TemplateSyntaxError
    @test err.source !== nothing
    @test err.pos.line == 3

    msg = sprint(showerror, err)
    @test occursin("--> templates/syntax_err.html:3:", msg)
    @test occursin("3 | {{ 1 + }}", msg)
    @test caret_column(msg) !== nothing

    # A hand-built error with a known position renders the exact caret column.
    src = "alpha\nbeta gamma\n"
    e2 = G.TemplateSyntaxError("bad token", G.Pos("t.html", 2, 6, 7), src)
    out = sprint(showerror, e2)
    @test occursin("t.html:2:6", out)
    @test occursin("2 | beta gamma", out)
    @test caret_column(out) == 6

    # Without a source, the location line is still printed and no caret appears.
    plain = sprint(showerror, G.TemplateSyntaxError("nope", G.Pos("t.html", 1, 1, 1)))
    @test occursin("--> t.html:1:1", plain)
    @test !occursin("^", plain)
end

@testset "errors: runtime template provenance" begin
    err = try
        render(ERRT)
        nothing
    catch e
        e
    end
    @test err isa G.TemplateError
    @test err.cause isa ErrorException

    chain = G.template_backtrace(err)
    @test !isempty(chain)
    @test chain[1].kind === :body
    @test chain[1].path == "templates/err.html"
    @test chain[1].line == 3
    @test chain[1].abs_path == joinpath(pwd(), "templates", "err.html")
    @test chain[end].kind === :render

    msg = sprint(showerror, err)
    @test occursin("TemplateError: boom", msg)
    @test occursin("at templates/err.html:3", msg)
    @test occursin("rendered from", msg)
end

@testset "errors: block, macro, and include provenance" begin
    err = try
        render(ERR_CHILD)
        nothing
    catch e
        e
    end
    chain = G.template_backtrace(err)
    @test chain[1].kind === :block
    @test chain[1].name === :content
    @test chain[1].path == "templates/err_child.html"
    @test any(fr -> fr.path == "templates/err_base.html", chain)

    err = try
        render(ERR_MACRO)
        nothing
    catch e
        e
    end
    chain = G.template_backtrace(err)
    @test chain[1].kind === :macro
    @test chain[1].name === :boom
    @test chain[1].path == "templates/err_macro.html"

    err = try
        render(ERR_INC)
        nothing
    catch e
        e
    end
    chain = G.template_backtrace(err)
    @test chain[1].path == "templates/err.html"
    @test chain[2].path == "templates/err_include_main.html"
end

@testset "errors: render! wraps too" begin
    @test_throws G.TemplateError render!(IOBuffer(), ERRT)
end

@testset "errors: source_root resolution" begin
    err = try
        render(ERRT_ROOT)
        nothing
    catch e
        e
    end
    chain = G.template_backtrace(err)
    @test chain[1].abs_path == joinpath(@__DIR__, "templates", "err.html")
end

@testset "errors: template_backtrace() inside a catch" begin
    try
        render(ERRT)
        @test false
    catch
        chain = G.template_backtrace()
        @test !isempty(chain)
        @test chain[1].path == "templates/err.html"
    end
    @test isempty(G.template_backtrace())
end

@testset "errors: raw Julia backtrace carries virtual paths" begin
    # Rendering directly through the generated entry function bypasses the
    # `TemplateError` wrapper, so the native backtrace must carry the template.
    frames = try
        ERRT.entry(IOBuffer())
        nothing
    catch
        stacktrace(catch_backtrace())
    end
    @test frames !== nothing
    @test any(fr -> occursin("err.html", string(fr.file)) && fr.line == 3, frames)

    frames = try
        ERRT2.entry(IOBuffer())
        nothing
    catch
        stacktrace(catch_backtrace())
    end
    @test any(fr -> occursin("err2.html", string(fr.file)) && fr.line == 3, frames)

    frames = try
        ERRTLOOP.entry(IOBuffer())
        nothing
    catch
        stacktrace(catch_backtrace())
    end
    @test any(fr -> occursin("errloop.html", string(fr.file)) && fr.line == 2, frames)
end
