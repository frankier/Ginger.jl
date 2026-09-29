# Ginger.jl

A Jinja-style template engine for Julia. Ginger compiles templates to Julia code
during macro expansion, so rendering is ordinary, type-specialized Julia. There
is no runtime parsing, no runtime compilation, and no module generated at
runtime.

The syntax is inspired by
[OteraEngine.jl](https://mommawatasu.github.io/OteraEngine.jl/dev/tutorial/) and
Jinja2. The execution model is different, and Ginger is not a drop-in
replacement for either.

Ginger supports the full Julia control-flow surface, inferred context, HTML
escaping with compile-time escape elision, the `DefaultHelpers` filter library,
template composition, static template inheritance, and provenance diagnostics.
See [`docs/`](docs) for the full documentation site and
[`docs/src/api.md`](docs/src/api.md) for the public API.

## Example

```julia
module MyApp

using Ginger

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
`String`. `render!` writes to any `IO`.

## Features

- **Lexer**: Ginger reads `{{ }}`, `{% %}`, and `{# #}` (nestable comments). It
  supports configurable delimiters, whitespace control (`{{-`, `-}}`, `+`
  variants, `trim_blocks`, `lstrip_blocks`, and `autospace`), and
  quote/bracket-aware tag scanning. A `}}` inside a string, char, backtick, or
  comment does not close the tag.
- **Synthesis**: Text becomes `print(out, "…")`, and expressions become
  `__ginger_print__(…)`. An offset map records synthetic-source to
  template-source positions per line. `{% for %}…{% else %}…{% endfor %}` lowers
  to a `let`-scoped `ran_any` flag plus a trailing `if`, because Julia has no
  `for`/`else`.
- **Parsing**: `Base.JuliaSyntax.parseall` parses the synthetic source with the
  virtual template path as the filename. Ginger translates syntax errors through
  the offset map into a `TemplateSyntaxError` at a template position.
- **Normalization**: `__ginger_print__` expands to `print(out, escape(e))` (or
  without `escape` when autoescaping is off), and Ginger rewrites synthetic line
  numbers to real template line numbers.
- **Inferred context**: Ginger classifies free variables into locals,
  host-module globals, and context variables. Locals from assignments, `let`,
  `for`, `while`, comprehensions, and function/lambda parameters are not context.
  The generated prologue binds context variables from the render context with
  the configured `undefined` mode (`:strict`, `:lenient`, or `:default`).
- **Escaping**: `HTMLString`, `escape` (idempotent), `safe`, and `default`. When
  the outermost expression is statically known to produce an `HTMLString` (a
  `safe`/`escape`/`HTMLString` call, `super()`, or a template macro), Ginger
  elides the autoescape wrapper at compile time. The output does not change.
- **Helpers and filters**: Any function in the host module is callable from a
  template. `Ginger.DefaultHelpers` supplies `upper`, `lower`, `title`,
  `capitalize`, `trim`, `excerpt`, `truncate_at`, `replace_with`, `join_with`,
  `starts_with`, and `default_to`. Filters use ordinary Julia pipe semantics.
- **Control flow**: `{% %}` statements contain arbitrary Julia, so `if` /
  `elseif` / `else`, `for`, `while`, `let`, `begin`, `try` / `catch` /
  `finally`, `function`, `do` blocks, and `quote` all work when closed with
  `{% end %}`. The `end*` aliases `endif`, `endfor`, `endwhile`, and `endlet`
  translate to `end`. `{% for x in it %}…{% else %}…{% endfor %}` runs the
  `else` body only when the iterator produces nothing.
- **Composition**: `{% macro name(args) %}…{% endmacro %}` defines a reusable
  fragment as a generated function that returns `HTMLString`. `{% include
  "partial.html" %}` renders another template in place, and `with k = v` adds
  bindings to the current context. `{% import "forms.html" as forms %}` and
  `{% from "forms.html" import field, label as lbl %}` expose another template's
  macros as a `NamedTuple` namespace. Ginger resolves references relative to the
  referencing template and compiles them into the same expansion. A missing
  reference or a reference cycle is a `TemplateSyntaxError`.
- **Inheritance**: `{% extends "base.html" %}` composes a base template with the
  child's `{% block name %}…{% endblock %}` overrides. Composition is static: a
  block is a generated function, dispatch is a `NamedTuple` lookup that
  constant-folds, and `super()` / `super(n)` resolve at compile time to the
  nearest ancestor definitions. Nested blocks and multi-level inheritance work,
  and a child's macros and imports are visible inside its blocks.
- **Raw**: `{% raw %}…{% endraw %}` emits its body verbatim, and Ginger never
  interprets delimiters inside it. Explicit `-` markers on the two tags trim the
  body edges, and the `trim_blocks`/`lstrip_blocks` config never touches raw
  text.
- **Diagnostics**: Ginger reports unclosed template blocks (`{% for %}`,
  `{% if %}`, …) and an unterminated `{% raw %}` as a `TemplateSyntaxError` at
  the opening tag. It translates Julia syntax errors in a tag through the offset
  map to the template line and renders a caret diagnostic against the template
  source. Generated `LineNumberNode`s carry the virtual template path, so runtime
  backtraces point at `templates/index.html:42`. Ginger wraps render errors in a
  `TemplateError` whose provenance chain is available through
  `template_backtrace`. See [Errors](#errors).
- **Macro**: `@template "path" [as NAME] [config = Config(...)]` compiles one
  file. `@templates "dir" [as NAME] [config = ...] [helpers = (Mod, …)]`
  compiles every template under a directory. `ginger"…"` compiles an inline
  string literal. All three compile at expansion time, and the file-based forms
  use `include_dependency` so template edits invalidate the host package. See
  [Templates and precompilation](#templates-and-precompilation).

## Helpers and filters

Any function that is defined or imported in the host module is callable from a
template. The scope pass treats it as a host global, so no registry and no
declaration are necessary:

```julia
module MyApp

using Ginger
using Ginger.DefaultHelpers     # escape, safe, upper, lower, …
include("filters.jl")           # slugify, excerpt, …

@template "templates/page.html" as PAGE

end
```

Alternatively, `@templates` accepts `helpers = (MyFilters,)` and emits
`using MyFilters` into the host module, so the exported names of a helper package
are available without a separate `using` at the call site. See
[Templates and precompilation](#templates-and-precompilation).

`Ginger.DefaultHelpers` supplies these helpers:

| Helper | Form |
|--------|------|
| `escape`, `safe` | one argument, idempotent |
| `upper`, `lower`, `title`, `capitalize`, `trim` | one argument |
| `excerpt(n)`, `truncate_at(n)` | parameterized, returns a callable |
| `replace_with(from, to = "")` | parameterized |
| `join_with(sep = "")` | parameterized |
| `starts_with(prefix)` | parameterized |
| `default_to(fallback)` | parameterized, for `undefined = :lenient` |

Filters follow one rule: a one-argument function is used directly, and a filter
that takes extra arguments returns a callable. This is plain Julia pipe
semantics, so `Base.Fix1` and `Base.Fix2` work as filters too:

```jinja
{{ user.name |> upper }}
{{ post.body |> excerpt(80) |> safe }}
{{ title |> trim |> capitalize }}
{{ path |> starts_with("/admin") }}
```

`escape` is idempotent on `HTMLString`, so `{{ x |> safe }}`, `{{ safe(x) }}`,
and `{{ x |> escape }}` never double-escape. `safe` bypasses autoescaping, and
ordinary filters return plain `String`s and are escaped as usual.

## Composition

Macros are reusable fragments. They compile to generated functions that build an
`IOBuffer` and return an `HTMLString`, so a macro result is not escaped twice:

```jinja
{% macro badge(text, kind = "info") %}<span class="{{ kind }}">{{ text }}</span>{% endmacro %}
{{ badge("Hi") }}          {# <span class="info">Hi</span> #}
```

A macro body sees its arguments, the template's other macros, and host-module
helpers. It does **not** see the caller's context, and a free variable that is
not one of those is a compile-time error. Macro definitions must appear at the
top level, and Ginger rejects duplicate macro names.

`{% include %}` renders another template in place. The render context passes
through, and `with` adds or overrides bindings:

```jinja
{% include "partials/head.html" %}
{% include "partials/head.html" with heading = "Posts" %}
```

Only the render context crosses an include boundary. A loop variable or other
local is not visible inside the included template unless the caller passes it
with `with`.

`{% import %}` binds another template's macro namespace, and `{% from %}` binds
individual macros (with `as` for a local name):

```jinja
{% import "forms.html" as forms %}
{{ forms.field("email") }}

{% from "forms.html" import field, label as lbl %}
{{ lbl("Email") }} {{ field("email") }}
```

Ginger resolves every reference relative to the referencing template and
compiles it into the same expansion. It compiles a shared template once per
`@template` expansion, even when several templates in that expansion reference
it.

## Inheritance

`{% extends %}` composes templates. The child overrides named `{% block %}`
regions of its base, and non-whitespace output outside a block is a compile-time
error:

```jinja
{# base.html #}
<html><body>{% block content %}nothing yet{% endblock %}</body></html>

{# index.html #}
{% extends "base.html" %}
{% block content %}<h1>{{ user }}</h1>{% endblock %}
```

A block that a child does not override falls back to the base's default.
`super()` renders the nearest ancestor's version of the block, and `super(n)`
the version `n` levels up:

```jinja
{% extends "base.html" %}
{% block content %}<main>{{ super() }}</main>{% endblock %}
```

Composition is entirely static. Each template compiles to a body function and
one function per block. A child body passes its blocks to its parent with
`merge`, and a block site dispatches through the resulting concrete
`NamedTuple`, which constant-folds. `super()` is a direct call on a
compile-time-known function, so there is no runtime block registry and no
`super` object.

Ginger checks restrictions at macro-expansion time. `{% extends %}` must appear
once at the top level, `{% block %}` may not appear under control flow, block
and macro names must be unique within a template, and an extending template may
not emit text outside a block (Ginger ignores whitespace between tags).

## Errors

Ginger reports two kinds of problems: compile-time template errors and
render-time provenance.

A template that Ginger cannot lex, parse, or normalize raises
`TemplateSyntaxError`. When the offending template text is available, the error
renders the line with a caret:

```
TemplateSyntaxError: unexpected `)`
  --> templates/syntax_err.html:3:10
    |
  3 | {{ 1 + }}
    |          ^
```

The line and caret come from the synthetic-to-template offset map, which records
one position per emitted chunk. The diagnostic points at the template line where
the offending chunk starts, with the caret column clamped to that line.

At render time, Ginger wraps an exception raised inside a generated body, block,
or macro in `TemplateError`. The wrapper carries the provenance chain, which
Ginger recovers from the native backtrace through the compile-time registry that
`@template` emits:

```
TemplateError: MissingContextVariable: context variable `user` was not passed
  in block "content" at templates/index.html:3
  at templates/base.html:12
  rendered from app.jl:20
```

`template_backtrace(err)` returns the same chain as a `Vector{TemplateFrame}`,
innermost first. Each frame has `kind` (`:body`, `:block`, `:macro`, or
`:render`), `name` (the block or macro name when one applies), the
package-relative `path`, and `abs_path` resolved against `Config.source_root`.
`template_backtrace()` with no argument returns the chain of the `TemplateError`
currently being handled. An exception with no template frame propagates
unchanged, so a helper called outside a template keeps its own exception type.

## Templates and precompilation

`@templates "views"` discovers every file under `views/` recursively and binds a
`NamedTuple` of `Template`s named `TEMPLATES` (override with `as NAME`). The path
is relative to the file that contains the macro call, exactly as for `@template`.
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

All references (`{% extends %}`, `{% include %}`, `{% import %}`, `{% from %}`)
resolve inside the set, and Ginger compiles a template referenced from several
places once. Ginger compiles `{% extends %}` parents before their children, so
the generated definitions are always in dependency order.

`helpers = (MyHelpers, MyFilters)` emits `using MyHelpers, MyFilters` into the
host module before Ginger compiles the templates, so the exported functions and
macros of those modules are available in every template. The entries must name
modules, not values:

```julia
@templates "views" helpers = (MyFilters,)
```

Ginger discovers a file whatever its extension, and skips hidden entries (a
leading `.`). Two files whose stems map to the same key, or a file that collides
with a subdirectory name, is a compile-time `ArgumentError`.

### Precompilation and the dev loop

`@templates` and `@template` read every template and every directory at
macro-expansion time and register them with `Base.include_dependency`. The
generated functions therefore land in the host package's precompile image, and
no template is parsed or compiled at runtime.

The dependency registration also drives the development loop. Editing a template
changes the package's precompile key, so the next `using MyApp` recompiles it.
Adding a template changes the recorded directory contents, so a new file is
discovered and bound on the next load. Removing a template invalidates the
package as well. There is no cache, no file watcher, and no hashing in Ginger,
and the standard Julia dev loop (a reload, or `Revise.jl`) re-expands the macros.

Because the whole set is compiled in one expansion, a template that is only used
internally (a partial, a macro library) still becomes a key in the `NamedTuple`.
Use the keys you need and ignore the rest.

### Single file

For one file, use `@template`:

```julia
@template "views/index.html" as INDEX
render(INDEX; user = "frank")
```

`@template` reads the file at expansion time and registers it with
`include_dependency` in the same way. The default const name is the uppercased
file stem.

### Inline

For a template that lives in the source, use the `ginger"…"` string macro. It
compiles during expansion and returns a `Template` value:

```julia
const GREETING = ginger"Hello {{ name }}!"
render(GREETING; name = "frank")     # -> "Hello frank!"
GREETING(name = "frank")             # the same
```

Any reference inside the string resolves relative to the file that contains the
macro call. Because the source is part of the host package's AST, an inline
template is precompiled like a file-based one and needs no `include_dependency`
entry.

## Limitations

Cross-package `{% extends %}` is not supported. All template references resolve
inside one `@templates` expansion.

### Context inference caveat

Ginger treats a name that is already defined in the host module as a host global,
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

`Config` is an immutable value. There is no TOML file and no mutable environment.
The `config` expression is evaluated in the host module at macro-expansion time.

## Tests

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

`test/precompile_probe` is a real package that uses `@templates`. The test suite
precompiles it in a scratch environment, then checks in separate processes that a
second load does not recompile and that editing or adding a template does. That
check is why the suite takes a minute longer than the unit tests.

Ginger formats source and tests with
[Runic](https://github.com/fredrikekre/Runic.jl).

## Benchmarks, differential tests, and docs

The root `Project.toml` declares a Pkg workspace containing the `test` and
`docs` projects. One `Manifest.toml` at the repository root covers the package,
the test environment, and the documentation environment:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

`test/Project.toml` adds `Test` and `Pkg` on top of the package. The
documentation site (Documenter) is built with:

```sh
julia --project=docs docs/make.jl
```

Benchmarks and the OteraEngine differential comparison are deliberately kept
outside the workspace, so that `Pkg.test()` never depends on a third-party
template engine:

```sh
# Benchmarks (BenchmarkTools) vs OteraEngine and hand-written interpolation
julia --project=benchmark -e 'using Pkg; Pkg.instantiate()'
julia --project=benchmark benchmark/benchmarks.jl

# Differential comparison against OteraEngine (dev-only, separate env)
julia --project=test/differential -e 'using Pkg; Pkg.instantiate()'
julia --project=test/differential test/differential/runtests.jl
```

Both standalone environments use a `[sources]` entry that points Ginger at the
checkout, so no manual `Pkg.develop` is necessary.
