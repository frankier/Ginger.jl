# Migrating from OteraEngine

Ginger shares OteraEngine's Jinja-like surface (`{{ }}`, `{% %}`, `{# #}`,
`|>` filters, `{% extends %}` / `{% block %}`), but the execution model is
different. This page lists the differences and a migration path.

## The conceptual shift

OteraEngine builds a renderer when you call `Template(path)` at runtime. Ginger
compiles a template during macro expansion, when the host package is parsed:

```julia
# OteraEngine
tmp = Template("templates/index.html")
tmp(init = Dict(:user => "frank"))

# Ginger
@template "templates/index.html" as INDEX
render(INDEX; user = "frank")
```

Ginger has no runtime `Template(...)` constructor. The compiled value is a
[`Template`](@ref) that holds the generated entry function, and `render` calls
it. Because compilation is part of parsing the host package, the precompile image
caches the result and no template is parsed at runtime.

| Topic | Ginger | OteraEngine |
|-------|--------|-------------|
| When compiled | macro expansion | `Template(...)` call |
| Context | inferred from free variables | inferred from undefined symbols |
| Implementation | synthetic Julia source + Julia parser | template AST |
| Filters | `\|>` with user-curried arguments | `\|>` with a zero-argument filter name |
| Scope | Julia scoping | Julia-ish |
| `extends` | static, same unit | literal path |
| Blocks | static function composition | text substitution |
| `super.super()` | `super(2)` | `super.super()` |
| Config | immutable [`Config`](@ref) | TOML / `Dict` |
| Safe value | [`HTMLString`](@ref) | `SafeString` |

## Step by step

### 1. Compile templates at package scope

Replace runtime construction with `@template` or `@templates`. `@templates`
discovers a whole directory and binds a `NamedTuple`:

```julia
module MyApp

using Ginger
using Ginger.DefaultHelpers

@templates "templates" as TPL

end
```

### 2. Render with keywords, not `init`

OteraEngine passes a `Dict`:

```julia
tmp(init = Dict(:user => "frank", :posts => posts))
```

Ginger passes keyword arguments, and the generated function specializes on the
context `NamedTuple`:

```julia
render(TPL.index; user = "frank", posts = posts)
```

### 3. Rename safe values

`OteraEngine.SafeString` and `safe` become [`HTMLString`](@ref) and
[`safe`](@ref). Both are idempotent, so `{{ x |> safe }}` keeps working.

### 4. Replace `@filter` registrations

OteraEngine registers filters with `@filter` and looks them up by name at render
time. Ginger has no registry. A filter is any function in the host module, and a
parameterized filter returns a callable.

```julia
# OteraEngine
@filter repeat say_twice(txt) = txt * txt
```

```julia
# Ginger: a one-argument function is used directly
say_twice(txt) = txt * txt
```

A filter that needs an argument returns a callable:

```julia
excerpt(n) = s -> length(s) <= n ? s : first(s, n) * "…"
```

```jinja
{{ body |> excerpt(80) }}
```

OteraEngine's built-in `upper`, `lower`, `escape`, `e`, and `safe` have Ginger
equivalents in [`DefaultHelpers`](@ref). Import the module with
`using Ginger.DefaultHelpers`. `quote_sql` has no equivalent. Write it as a host
function if you need it.

### 5. Port control blocks

`if`, `for`, and `let` map directly. Ginger also accepts `{% endfor %}`,
`{% endif %}`, `{% endwhile %}`, and `{% endlet %}` as aliases for `{% end %}`.
OteraEngine's `{% set %}` becomes an ordinary Julia assignment:

```jinja
{% x = compute() %}
```

OteraEngine's `{% end %}` is accepted unchanged.

### 6. Port inheritance

`{% extends %}`, `{% block %}`, `{% endblock %}`, and `{% include %}` map
directly, and all references resolve inside the `@templates` unit. `super()`
maps directly, and `super.super()` becomes `super(2)`.

Ginger does not support cross-package `extends`. Keep shared bases inside the
same unit.

### 7. Port macros

`{% macro name(args) %}…{% endmacro %}` maps directly. Ginger macros compile to
functions that return `HTMLString`, and Ginger collects them in the template's
namespace for `{% import %}` and `{% from %}`. Ginger rejects duplicate names,
and a macro body sees its arguments and host helpers, not the caller's context.

### 8. Port configuration

OteraEngine reads a TOML file or a `Dict`. Ginger takes an immutable
[`Config`](@ref) value as a macro argument:

```julia
@template "page.html" as PAGE config = Config(
    autoescape = false,
    trim_blocks = true,
    lstrip_blocks = true,
    undefined = :lenient,
)
```

## Gotchas

- **Whitespace.** OteraEngine defaults to `autospace = true`. Ginger defaults to
  `trim_blocks = false` and `lstrip_blocks = false`. Set `autospace = true` to
  match. Ginger also trims the newline after expression tags when `trim_blocks`
  is on, so keep the newline with `+` if that matters.
- **Context collisions.** A name that is a host-module global (a helper, a `Base`
  export) is not a context variable. Do not use a variable name that is also a
  filter name. Rename the render keyword instead.
- **No runtime paths.** A template path is a string literal known at macro
  expansion. Dynamic template selection needs an `if`/`elseif` over statically
  compiled templates.
- **Precompilation.** Editing a template invalidates the host package and
  triggers a reload. Use `Revise.jl` or reload the package.
