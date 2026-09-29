# Filters and helpers

## Pipe semantics

Filters use Julia's pipe operator with ordinary Julia semantics. The engine does
no rewriting:

| Source | Julia meaning |
|--------|---------------|
| `a \|> f` | `f(a)` |
| `a \|> f(1, 2)` | `f(1, 2)(a)` |
| `a \|> f(1) \|> g` | `g(f(1)(a))` |

The rule is: **a parameterized filter returns a callable.**

```julia
upper(s)       = uppercase(s)
excerpt(n)     = s -> length(s) <= n ? s : first(s, n) * "…"
truncate_at(n) = Base.Fix2(first, n)
```

A bare `|` is not reinterpreted; it remains Julia's `bitor`.

## Autoescaping

Every `{{ }}` is emitted as `escape(expr)`. `escape` is idempotent on
[`HTMLString`](@ref), so `{{ x |> safe }}` and `{{ safe(x) }}` pass through
unchanged. `{{ x |> escape }}` is escaped once, not twice.

When the outermost expression is statically known to produce an `HTMLString`—a
call to `safe`, `escape`, `HTMLString`, `super()`, or a template macro—Ginger
elides the redundant `escape` wrapper at compile time. The output is identical.

Set `autoescape = false` to disable escaping:

```julia
@template "email.txt" as EMAIL config = Config(autoescape = false)
```

## `DefaultHelpers`

Import the module into the host module to make its names resolvable from
templates:

```julia
using Ginger
using Ginger.DefaultHelpers
```

| Helper | Form |
|--------|------|
| [`escape`](@ref), [`safe`](@ref) | one argument, idempotent |
| `upper`, `lower`, `title`, `capitalize`, `trim` | one argument |
| `excerpt(n)`, `truncate_at(n)` | parameterized, returns a callable |
| `replace_with(from, to = "")` | parameterized |
| `join_with(sep = "")` | parameterized |
| `starts_with(prefix)` | parameterized |
| `default_to(fallback)` | parameterized, for `undefined = :lenient` |

```jinja
{{ user.name |> upper }}
{{ post.body |> excerpt(80) |> safe }}
{{ heading |> trim |> capitalize }}
{{ path |> starts_with("/admin") }}
```

`escape`, `safe`, `HTMLString`, and `default` are re-exported from Ginger.
Generated code references `escape` fully qualified, so autoescaping works even
without the import.

## Custom helpers

Any function defined or imported in the host module is callable from a template,
with no registry and no declaration:

```julia
module MyApp

using Ginger
using Ginger.DefaultHelpers
include("filters.jl")           # slugify, excerpt, …

@template "templates/page.html" as PAGE

end
```

Alternatively, `@templates` accepts `helpers = (MyFilters,)` and emits
`using MyFilters` into the host module:

```julia
@templates "views" helpers = (MyFilters,)
```

The entries must name modules, not values.
