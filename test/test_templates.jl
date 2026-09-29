using Test
using Ginger

@templates "views" as V

module GingerTestHelpers
    export shout
    shout(x) = uppercase(string(x)) * "!"
end

@templates "helpers_views" as HTPL helpers = (Main.GingerTestHelpers,)

module DefaultNameTemplates
    using Ginger
    @templates "views_small"
end

module NoEscapeTemplates
    using Ginger
    @templates "views_small" as RAW config = Config(autoescape = false)
end

@testset "@templates: directory discovery" begin
    @test keys(V) == (:base, :index, :widgets, :admin, :partials)
    @test V.base isa Template
    @test V.admin.dashboard isa Template
    @test V.partials.head isa Template
    @test V.widgets isa Template
    @test endswith(V.index.path, "views/index.html")
    @test endswith(V.admin.dashboard.path, "views/admin/dashboard.html")
end

@testset "@templates: rendering across the set" begin
    @test render(V.partials.head) == "<meta charset=\"utf-8\">\n"
    @test render(V.base) ==
        "<!DOCTYPE html>\n<html>\n  <head></head>\n  <body>nothing yet</body>\n</html>\n"
    @test render(V.widgets) == "\n"
    @test render(V.index; heading = "Hello", user = "frank") ==
        "<!DOCTYPE html>\n<html>\n  <head><meta charset=\"utf-8\">\n</head>\n" *
        "  <body>\n<h1>Hello</h1>\n<span class=\"badge\">frank</span>\n</body>\n</html>\n"
    @test render(V.admin.dashboard; who = "root") ==
        "<!DOCTYPE html>\n<html>\n  <head></head>\n  <body><p>admin: root</p></body>\n</html>\n"
end

@testset "@templates: escaping" begin
    @test render(V.index; heading = "<x>", user = "<y>") ==
        "<!DOCTYPE html>\n<html>\n  <head><meta charset=\"utf-8\">\n</head>\n" *
        "  <body>\n<h1>&lt;x&gt;</h1>\n<span class=\"badge\">&lt;y&gt;</span>\n</body>\n</html>\n"
end

@testset "@templates: default name and config" begin
    @test DefaultNameTemplates.TEMPLATES.only isa Template
    @test render(DefaultNameTemplates.TEMPLATES.only; payload = "<b>") == "&lt;b&gt;"
    @test NoEscapeTemplates.RAW.only isa Template
    @test render(NoEscapeTemplates.RAW.only; payload = "<b>") == "<b>"
end

@testset "@templates: helpers" begin
    @test render(HTPL.greeting; who = "frank") == "FRANK!\n"
end

# A compile error must not be triggered at include time, so the failing
# expansions go through `macroexpand`.
function templates_error(path, extra...)
    return try
        ex = Expr(:macrocall, Symbol("@templates"), LineNumberNode(0, Symbol(@__FILE__)), path, extra...)
        macroexpand(@__MODULE__, ex)
        nothing
    catch e
        e
    end
end

@testset "@templates: compile-time errors" begin
    @test templates_error("no_such_views") isa ArgumentError
    @test templates_error("views_collision") isa ArgumentError
    @test templates_error("views_file_dir") isa ArgumentError
end
