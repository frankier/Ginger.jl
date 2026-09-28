using Test
using Ginger

const G = Ginger

@template "templates/uses_macro.html" as USES_MACRO
@template "templates/macro_loop.html" as MACRO_LOOP
@template "templates/macro_in_loop.html" as MACRO_IN_LOOP
@template "templates/include_main.html" as INCLUDE_MAIN
@template "templates/include_with.html" as INCLUDE_WITH
@template "templates/include_nested.html" as INCLUDE_NESTED
@template "templates/import_main.html" as IMPORT_MAIN
@template "templates/from_main.html" as FROM_MAIN

@testset "macros: definition and call" begin
    @test render(USES_MACRO) == "<span class=\"info\">Hi</span><span class=\"warn\">Bye</span>"
end

@testset "macros: escaping and control flow" begin
    @test render(MACRO_LOOP; items = ["a", "b"]) == "<li>a</li><li>b</li>"
    @test render(MACRO_LOOP; items = ["<x>"]) == "<li>&lt;x&gt;</li>"
    @test render(MACRO_LOOP; items = String[]) == ""
    @test render(MACRO_IN_LOOP; items = ["a", "b"]) == "<b>a</b><b>b</b>"
end

@testset "include" begin
    @test render(INCLUDE_MAIN; heading = "T") == "<body><title>T</title></body>"
    @test render(INCLUDE_WITH) == "<body><title>Local</title></body>"
    @test render(INCLUDE_NESTED; x = "V") == "<o>[V]</o>"
end

@testset "import and from" begin
    @test render(IMPORT_MAIN) == "<b>Ann</b>|<b>A</b><b>B</b>"
    @test render(FROM_MAIN) == "<b>Bo</b>|<input type=\"text\" name=\"q\" value=\"\">"
end

# A compile error must not be triggered at include time, so the failing
# templates are expanded lazily through `macroexpand`.
macro_error(path, name) =
try
    macroexpand(@__MODULE__, :(@template $path as $name))
    nothing
catch e
    e
end

@testset "macros: compile-time errors" begin
    @test macro_error("templates/macro_badctx.html", :BADCTX) isa G.TemplateSyntaxError
    @test macro_error("templates/macro_dupe.html", :DUPEMACRO) isa G.TemplateSyntaxError
    @test macro_error("templates/macro_in_if.html", :IFMACRO) isa G.TemplateSyntaxError
    @test macro_error("templates/include_missing.html", :MISSINGINC) isa G.TemplateSyntaxError
    @test macro_error("templates/from_missing.html", :MISSINGFROM) isa G.TemplateSyntaxError
    @test macro_error("templates/cycle_a.html", :CYCLEA) isa G.TemplateSyntaxError
end
