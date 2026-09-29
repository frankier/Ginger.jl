using Documenter
using Ginger

makedocs(
    sitename = "Ginger.jl",
    authors = "Frank Fischer",
    modules = [Ginger, Ginger.DefaultHelpers],
    pages = [
        "Home" => "index.md",
        "Syntax" => "syntax.md",
        "Context" => "context.md",
        "Filters and helpers" => "filters.md",
        "Composition and inheritance" => "inheritance.md",
        "Errors" => "errors.md",
        "Templates and precompilation" => "precompilation.md",
        "API reference" => "api.md",
        "Migrating from OteraEngine" => "migration-from-otera.md",
    ],
    checkdocs = :none,
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
    ),
)

deploydocs(
    repo = "github.com/frankier/Ginger.jl.git",
    devbranch = "main",
    push_preview = true,
)
