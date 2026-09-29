# Context

Templates do not declare their context. Ginger infers it at macro-expansion time
from the free variables of the generated body.

Rendering passes the context as keyword arguments:

```julia
render(TPL.index; user = "frank", posts = posts)
```

## What counts as context

A name in a template is one of three things:

1. **A local.** Loop binders, `let` bindings, function and `do` parameters,
   assignments, and this template's own blocks and macros are not context.
2. **A host-module global.** A name that is defined or imported in the host
   module, or exported by a module passed to `helpers`, is a global. This is how
   helper functions and filters work without a registry.
3. **A context variable.** Everything else is bound from the render context.

The classification is a free-variable analysis over the parsed template body.
The generated prologue binds each context variable from the context
`NamedTuple`.

## Undefined variables

A missing context variable follows the `undefined` config mode:

| Mode | Behaviour |
|------|-----------|
| `:strict` (default) | Throw [`MissingContextVariable`](@ref) |
| `:lenient` | Bind an `Undefined` singleton; renders as `""` and throws on property or index access |
| `:default` | Bind `Undefined`; the `default(value, fallback)` helper substitutes a fallback |

```julia
@template "page.html" as PAGE config = Config(undefined = :lenient)
```

```jinja
{{ nickname |> default_to("Anonymous") }}
```

## Caveat: names that collide with host globals

A name that is already defined in the host module is treated as a host global,
not as a context variable. This is deliberate: it is how helper functions work
without a registry. The consequence is that a context variable named after a
`Base` export or a `DefaultHelpers` name (for example `count`, `name`, `title`,
or `missing`) resolves to the global instead.

Give such values a different render keyword:

```julia
render(TPL.page; heading = "Posts")     # not `title`, which is a helper
```

The same rule applies to filters: do not use a variable name that is also a
filter name.
