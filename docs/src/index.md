# Ginger.jl

A Jinja-style template engine for Julia that compiles templates to Julia code
during macro expansion. Rendering is ordinary, type-specialized Julia: no runtime
parsing, no runtime compilation, and no modules generated at runtime.

The syntax is inspired by
[OteraEngine.jl](https://mommawatasu.github.io/OteraEngine.jl/dev/tutorial/) and
Jinja2. The execution model is different, and Ginger is **not** a drop-in
replacement for either. See [Migrating from OteraEngine](migration-from-otera.md) for the
differences.

## Why compile at macro-expansion time?

A template is read once, while the host package is being compiled. Ginger turns
it into ordinary Julia functions and splices those functions into the host
module. The result is cached in the host package's precompile image, so there is
no runtime loader, no cache, no `Core.eval`, and no world-age handling.

At render time, a template is a typed Julia function call. Context variables are
`NamedTuple` fields, block dispatch is a `NamedTuple` lookup that constant-folds,
and filters are plain function calls.

## Quick start

```julia
module MyApp

using Ginger
using Ginger.DefaultHelpers     # upper, lower, excerpt, …

@templates "templates" as TPL

end

Ginger.render(TPL.index; user = "frank", posts = posts)   # -> String
Ginger.render!(stdout, TPL.index; user = "frank")
```

`templates/index.html`:

```jinja
Hello, {{ user }}!
{% for post in posts %}
  <article>{{ post.title }}</article>
{% else %}
  <p>No posts yet.</p>
{% endfor %}
```

`render` builds an `IOBuffer`, calls the generated entry function, and returns a
`String`. `render!` writes to any `IO`. A `Template` is also callable:

```julia
TPL.index(; user = "frank")      # shorthand for render(TPL.index; user = "frank")
TPL.index(io; user = "frank")    # shorthand for render!(io, TPL.index; user = "frank")
```

## Feature summary

- **One grammar.** `{% %}` holds arbitrary Julia statements, and `{{ }}` holds an
  arbitrary Julia expression. Julia's parser matches nesting and precedence.
- **Inferred context.** Free-variable analysis decides which names come from the
  render context. There is no `{% context %}` declaration.
- **HTML escaping by default.** `escape` is idempotent and `safe` bypasses it.
- **Composition.** `{% macro %}`, `{% include %}`, `{% import %}`, `{% from %}`,
  and static inheritance through `{% extends %}`, `{% block %}`, and `super()`.
- **HTML stack traces.** Backtraces point at `templates/index.html:42`, and a
  render error reports the include/extends provenance chain.
- **Precompilation-aware.** Editing a template invalidates the host package
  through `Base.include_dependency`, so the standard Julia dev loop re-expands it.

## Documentation map

| Page | Contents |
|------|----------|
| [Syntax](syntax.md) | Delimiters, whitespace control, raw, comments, control flow |
| [Context](context.md) | Inferred context, undefined modes |
| [Filters and helpers](filters.md) | Pipe filters, `DefaultHelpers`, custom helpers |
| [Composition and inheritance](inheritance.md) | Macros, includes, imports, `extends`/`block`/`super` |
| [Errors](errors.md) | Caret diagnostics, provenance chains, virtual paths |
| [Templates and precompilation](precompilation.md) | `@template`, `@templates`, the dev loop |
| [API reference](api.md) | The frozen 1.0 public API |
| [Migrating from OteraEngine](migration-from-otera.md) | Differences and a step-by-step migration |
