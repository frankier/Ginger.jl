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
    remotes = nothing, # no remote configured in this checkout
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
    ),
)

# Deployment is left to the repository owner. Set the remote and uncomment:
#
# deploydocs(
#     repo = "github.com/<owner>/Ginger.jl.git",
#     push_preview = true,
# )
