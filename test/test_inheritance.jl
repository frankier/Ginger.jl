using Test
using Ginger

const G = Ginger

@template "templates/base.html" as BASE
@template "templates/child.html" as CHILD
@template "templates/child_title.html" as CHILD_TITLE
@template "templates/super_child.html" as SUPER_CHILD
@template "templates/grandchild.html" as GRANDCHILD
@template "templates/super2.html" as SUPER2
@template "templates/nested_blocks.html" as NESTED_BLOCKS
@template "templates/nested_override.html" as NESTED_OVERRIDE
@template "templates/import_in_child.html" as IMPORT_CHILD
@template "templates/child_inherit.html" as CHILD_INHERIT
@template "templates/macro_in_block.html" as MACRO_IN_BLOCK
@template "templates/include_in_block.html" as INCLUDE_IN_BLOCK
@template "templates/super_no_parent.html" as SUPER_NO_PARENT

const BASE_EXPECTED = "<!DOCTYPE html><html><head><title>Base</title></head><body>base content</body></html>"

@testset "inheritance: base and override" begin
    @test render(BASE) == BASE_EXPECTED
    @test render(CHILD; user = "Ann") ==
        "<!DOCTYPE html><html><head><title>Base</title></head><body><h1>Ann</h1></body></html>"
    @test render(CHILD_TITLE; heading = "T") ==
        "<!DOCTYPE html><html><head><title>T</title></head><body>C</body></html>"
end

@testset "inheritance: escaping inside a block" begin
    @test render(CHILD; user = "<b>") ==
        "<!DOCTYPE html><html><head><title>Base</title></head><body><h1>&lt;b&gt;</h1></body></html>"
end

@testset "inheritance: super and multi-level" begin
    @test render(SUPER_CHILD) ==
        "<!DOCTYPE html><html><head><title>Base</title></head><body>[base content]</body></html>"
    @test render(GRANDCHILD) ==
        "<!DOCTYPE html><html><head><title>Base</title></head><body><b>[base content]</b></body></html>"
    @test render(SUPER2) == BASE_EXPECTED
end

@testset "inheritance: super without an ancestor definition" begin
    @test render(SUPER_NO_PARENT) == "xy"
end

@testset "inheritance: nested blocks" begin
    @test render(NESTED_BLOCKS) == "ABC"
    @test render(NESTED_OVERRIDE) == "AXC"
end

@testset "inheritance: intermediate override" begin
    @test render(CHILD_INHERIT) ==
        "<!DOCTYPE html><html><head><title>Inherited</title></head><body>[base content]</body></html>"
end

@testset "inheritance: same-template macros visible inside blocks" begin
    @test render(MACRO_IN_BLOCK) ==
        "<!DOCTYPE html><html><head><title>Base</title></head><body><b>Bo</b></body></html>"
end

@testset "inheritance: include inside a block" begin
    @test render(INCLUDE_IN_BLOCK) ==
        "<!DOCTYPE html><html><head><title>Base</title></head><body><title>H</title></body></html>"
end

@testset "inheritance: imports visible inside blocks" begin
    @test render(IMPORT_CHILD) ==
        "<!DOCTYPE html><html><head><title>Base</title></head><body><b>Ann</b></body></html>"
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

@testset "inheritance: compile-time errors" begin
    @test macro_error("templates/extends_text.html", :EXTENDSTEXT) isa G.TemplateSyntaxError
    @test macro_error("templates/block_in_if.html", :BLOCKINIF) isa G.TemplateSyntaxError
    @test macro_error("templates/block_in_assign.html", :BLOCKINASSIGN) isa G.TemplateSyntaxError
    @test macro_error("templates/block_dupe.html", :BLOCKDUPE) isa G.TemplateSyntaxError
    @test macro_error("templates/extends_twice.html", :EXTENDSTWICE) isa G.TemplateSyntaxError
    @test macro_error("templates/extends_missing.html", :EXTENDSMISSING) isa G.TemplateSyntaxError
    @test macro_error("templates/super_outside.html", :SUPEROUTSIDE) isa G.TemplateSyntaxError
end
