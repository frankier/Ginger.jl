# Templates and precompilation

## `@template` and `@templates`

[`@template`](@ref) compiles one file and binds a [`Template`](@ref) const:

```julia
@template "views/index.html" as INDEX
render(INDEX; user = "frank")
```

The default const name is the uppercased file stem. A relative path is resolved
against the directory of the file that contains the macro call.

[`@templates`](@ref) discovers every file under a directory recursively and binds
a `NamedTuple` of `Template`s named `TEMPLATES` (override with `as NAME`).
Subdirectories become nested `NamedTuple`s and a file is keyed by its stem, so
`views/partials/head.html` is `TPL.partials.head`:

```julia
module MyApp

using Ginger

@templates "views" as TPL

end

render(TPL.index; user = "frank")          # views/index.html
render(TPL.partials.head)                  # views/partials/head.html
```

A file is discovered whatever its extension, and hidden entries (a leading `.`)
are skipped. Two files whose stems map to the same key, or a file that collides
with a subdirectory name, is a compile-time `ArgumentError`.

## Helpers

`helpers = (MyHelpers, MyFilters)` emits `using MyHelpers, MyFilters` into the
host module before the templates are compiled, so the exported functions and
macros of those modules are available in every template:

```julia
@templates "views" helpers = (MyFilters,)
```

The entries must name modules, not values.

## Precompilation

`@templates` and `@template` read every template and every directory at
macro-expansion time and register them with `Base.include_dependency`. The
generated functions therefore land in the host package's precompile image, and
no template is parsed or compiled at runtime.

There is no `Module`, no `Core.eval`, no cache, no lock, no dev-mode hashing, and
no world-age handling. `Config` is an immutable value passed as a macro argument.

## The dev loop

The dependency registration drives development. Editing a template changes the
package's precompile key, so the next `using MyApp` recompiles it. Adding a
template changes the recorded directory contents, so a new file is discovered and
bound on the next load. Removing a template invalidates the package as well.

Ginger does not implement its own file watching or hashing; this is delegated to
the standard Julia dev loop. Reload the package, or use `Revise.jl`, and the
macros re-expand.

Because the whole set is compiled in one expansion, a template that is only used
internally (a partial, a macro library) still becomes a key in the `NamedTuple`.
Use the keys you need and ignore the rest.

## Single file

For one file, use `@template`:

```julia
@template "views/index.html" as INDEX
render(INDEX; user = "frank")
```

`@template` reads the file at expansion time and registers it with
`include_dependency` in the same way.

## Inline templates

For a template that lives in the source, use the `ginger"…"` string macro. It
compiles during expansion and returns a [`Template`](@ref):

```julia
const GREETING = ginger"Hello {{ name }}!"
render(GREETING; name = "frank")     # -> "Hello frank!"
GREETING(name = "frank")             # the same
```

Any reference inside the string resolves relative to the file that contains the
macro call. Because the source is part of the host package's AST, an inline
template is precompiled like a file-based one and needs no `include_dependency`
entry.

## Cost model

- No runtime template discovery or dynamic paths.
- Name isolation comes from mangled identifiers rather than modules.
- Adding a template file requires recompiling the host package.
- Cross-package `{% extends %}` is limited (see
  [Composition and inheritance](inheritance.md)).
