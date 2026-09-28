# Ginger.jl

A Jinja-style template engine for Julia that compiles templates to Julia code
during macro expansion. Rendering is ordinary, type-specialized Julia: no runtime
parsing, no runtime compilation, and no modules generated at runtime.

This repository currently implements **milestone M0** from `PLAN.md`: a
single-file, end-to-end pipeline. See [Status](#status) for what is and is not in
place.

## Example

```julia
module MyApp

using Ginger

@template "templates/index.html" as INDEX

end

Ginger.render(INDEX; user = "frank", posts = posts)   # -> String
Ginger.render!(stdout, INDEX; user = "frank")
```

`templates/index.html`:

```jinja
Hello, {{ user }}!
{% for post in posts %}
  <article>{{ post.title }}</article>
{% end %}
```

`render` builds an `IOBuffer`, calls the generated entry function, and returns a
`String`. `render!` writes to any `IO`.

## What works today

- **Lexer**: `{{ }}`, `{% %}`, and `{# #}` (nestable comments), configurable
  delimiters, whitespace control (`{{-`, `-}}`, `+` variants, `trim_blocks`,
  `lstrip_blocks`, and `autospace`), and quote/bracket-aware tag scanning so a
  `}}` inside a string, char, backtick, or comment does not close the tag.
- **Synthesis**: text becomes `print(out, "…")`, expressions become
  `__ginger_print__(…)`, statements are emitted verbatim, and an offset map
  records synthetic-source to template-source positions per line.
- **Parsing**: `Base.JuliaSyntax.parseall` parses the synthetic source with the
  virtual template path as the filename. Syntax errors are translated through the
  offset map into `TemplateSyntaxError` at a template position.
- **Normalization**: `__ginger_print__` expands to `print(out, escape(e))` (or
  without `escape` when autoescaping is off) and synthetic line numbers are
  rewritten to real template line numbers.
- **Inferred context**: free variables are classified into locals, host-module
  globals, and context variables. Locals from assignments, `let`, `for`, `while`,
  comprehensions, and function/lambda parameters are not context. The generated
  prologue binds context variables from the render context with the configured
  `undefined` mode (`:strict`, `:lenient`, or `:default`).
- **Escaping**: `HTMLString`, `escape` (idempotent), `safe`, and `default`.
- **Macro**: `@template "path" [as NAME] [config = Config(...)]`, with
  `include_dependency` so template edits invalidate the host package.

Because everything is ordinary Julia, `{% `...` %}` statements already cover
`if`/`else`/`for`/`while`/function definitions as long as they are closed with
`{% end %}`.

## Status

M0 covers single-file rendering. Not yet implemented (see `PLAN.md` §18):

- `raw` blocks, the `end*` tag aliases, `for`/`else`, and compile-time
  restriction checks (M1);
- `DefaultHelpers`, curried-filter polish, and the full scope pass (M2);
- `{% macro %}`, `{% include %}`, `{% import %}`, `{% from %}` (M3);
- `{% extends %}`, `{% block %}`, `super()` (M4);
- the provenance registry and structured `template_backtrace` (M5);
- `@templates` directory discovery and the precompile probe (M6).

### Context inference caveat

A name that is already defined in the host module is treated as a host global,
not as a context variable. This is how helper functions work without a registry,
but it also means that a context variable named after a `Base` export (for
example `count`, `name`, or `missing`) resolves to the global instead. Give such
values a different render keyword.

## Configuration

```julia
@template "page.html" as PAGE config = Config(
    autoescape = false,
    trim_blocks = true,
    lstrip_blocks = true,
    undefined = :lenient,
)
```

`Config` is an immutable value; there is no TOML file and no mutable environment.
The `config` expression is evaluated in the host module at macro-expansion time.

## Tests

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

Source and tests are formatted with [Runic](https://github.com/fredrikekre/Runic.jl).
