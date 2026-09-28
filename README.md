# Ginger.jl

A Jinja-style template engine for Julia that compiles templates to Julia code
during macro expansion. Rendering is ordinary, type-specialized Julia: no runtime
parsing, no runtime compilation, and no modules generated at runtime.

This repository currently implements **milestone M6** from `PLAN.md`: a
single-file pipeline with the full Julia control-flow surface, inferred context,
HTML escaping, the `DefaultHelpers` filter library, template composition through
`{% macro %}`, `{% include %}`, `{% import %}`, and `{% from %}`, static
template inheritance through `{% extends %}`, `{% block %}`, and `super()` /
`super(n)`, provenance diagnostics (caret `TemplateSyntaxError`s, a compile-time
provenance registry, `TemplateError`, and `template_backtrace`), and
`@templates` directory discovery with precompilation-aware dependency tracking.
See [Status](#status) for what is and is not in place.

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

## What works today

- **Lexer**: `{{ }}`, `{% %}`, and `{# #}` (nestable comments), configurable
  delimiters, whitespace control (`{{-`, `-}}`, `+` variants, `trim_blocks`,
  `lstrip_blocks`, and `autospace`), and quote/bracket-aware tag scanning so a
  `}}` inside a string, char, backtick, or comment does not close the tag.
- **Synthesis**: text becomes `print(out, "…")`, expressions become
  `__ginger_print__(…)`, and an offset map records synthetic-source to
  template-source positions per line. `{% for %}…{% else %}…{% endfor %}` is
  lowered to a `let`-scoped `ran_any` flag plus a trailing `if`, because Julia
  has no `for`/`else`.
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
- **Helpers and filters**: any function in the host module is callable from a
template, and `Ginger.DefaultHelpers` provides `upper`, `lower`, `title`,
`capitalize`, `trim`, `excerpt`, `truncate_at`, `replace_with`, `join_with`,
`starts_with`, and `default_to`. Filters use ordinary Julia pipe semantics.
- **Control flow**: `{% %}` statements contain arbitrary Julia, so `if` /
  `elseif` / `else`, `for`, `while`, `let`, `begin`, `try` / `catch` / `finally`,
  `function`, `do` blocks, and `quote` all work when closed with `{% end %}`.
  The `end*` aliases `endif`, `endfor`, `endwhile`, and `endlet` translate to
  `end`. `{% for x in it %}…{% else %}…{% endfor %}` runs the `else` body only
  when the iterator produced nothing.
- **Composition**: `{% macro name(args) %}…{% endmacro %}` defines a reusable
  fragment as a generated function returning `HTMLString`; `{% include
  "partial.html" %}` renders another template in place, with `with k = v`
  adding bindings to the current context; `{% import "forms.html" as forms %}`
  and `{% from "forms.html" import field, label as lbl %}` expose another
  template's macros as a `NamedTuple` namespace. References are relative to the
  referencing template, compiled into the same expansion, and resolved at
  macro-expansion time; a missing reference or a reference cycle is a
  `TemplateSyntaxError`.
- **Inheritance**: `{% extends "base.html" %}` composes a base template with the
  child's `{% block name %}…{% endblock %}` overrides. Composition is static: a
  block is a generated function, dispatch is a `NamedTuple` lookup that
  constant-folds, and `super()` / `super(n)` resolve at compile time to the
  nearest ancestor definitions. Nested blocks and multi-level inheritance work,
  and a child's macros and imports are visible inside its blocks.
- **Raw**: `{% raw %}…{% endraw %}` emits its body verbatim; delimiters inside
  it are never interpreted. Explicit `-` markers on the two tags trim the body
  edges, and the `trim_blocks`/`lstrip_blocks` config never touches raw text.
- **Diagnostics**: unclosed template blocks (`{% for %}`, `{% if %}`, …) and an
  unterminated `{% raw %}` are reported as `TemplateSyntaxError` at the opening
  tag. Julia syntax errors in a tag are translated through the offset map to the
  template line and rendered as a caret diagnostic against the template source.
  Generated `LineNumberNode`s carry the virtual template path, so runtime
  backtraces point at `templates/index.html:42`, and render errors are wrapped in
  a `TemplateError` whose provenance chain is available through
  `template_backtrace`. See [Errors](#errors).
- **Macro**: `@template "path" [as NAME] [config = Config(...)]` compiles one
  file, and `@templates "dir" [as NAME] [config = ...] [helpers = (Mod, …)]`
  compiles every template under a directory. Both read files at expansion time
  and use `include_dependency` so template edits invalidate the host package. See
  [Templates and precompilation](#templates-and-precompilation).

## Helpers and filters

Any function defined or imported in the host module is callable from a template.
The scope pass recognizes it as a host global, so no registry and no declaration
are needed:

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

`Ginger.DefaultHelpers` provides these helpers:

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
and `{{ x |> escape }}` never double-escape. `safe` bypasses autoescaping;
ordinary filters return plain `String`s and are escaped as usual.

## Composition

Macros are reusable fragments. They compile to generated functions that build an
`IOBuffer` and return an `HTMLString`, so a macro result is not escaped twice:

```jinja
{% macro badge(text, kind = "info") %}<span class="{{ kind }}">{{ text }}</span>{% endmacro %}
{{ badge("Hi") }}          {# <span class="info">Hi</span> #}
```

A macro body sees its arguments, the template's other macros, and host-module
helpers. It does **not** see the caller's context; a free variable that is not
one of those is a compile-time error. Macro definitions must appear at the top
level, and duplicate macro names are rejected.

`{% include %}` renders another template in place. The render context is passed
through, and `with` adds or overrides bindings:

```jinja
{% include "partials/head.html" %}
{% include "partials/head.html" with heading = "Posts" %}
```

Only the render context crosses an include boundary. A loop variable or other
local is not visible inside the included template unless it is passed with
`with`.

`{% import %}` binds another template's macro namespace, and `{% from %}` binds
individual macros (with `as` for a local name):

```jinja
{% import "forms.html" as forms %}
{{ forms.field("email") }}

{% from "forms.html" import field, label as lbl %}
{{ lbl("Email") }} {{ field("email") }}
```

Every reference is resolved relative to the referencing template and compiled
into the same expansion, so a shared template is compiled once per `@template`
expansion even when several templates in that expansion reference it.

## Inheritance

`{% extends %}` composes templates. The child overrides named `{% block %}`
regions of its base; non-whitespace output outside a block is a compile-time
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
one function per block; a child body passes its blocks to its parent with
`merge`, and a block site dispatches through the resulting concrete `NamedTuple`,
which constant-folds. `super()` is a direct call on a compile-time-known
function, so there is no runtime block registry and no `super` object.

Restrictions are checked at macro-expansion time: `{% extends %}` must appear
once at the top level, `{% block %}` may not appear under control flow, block
and macro names must be unique within a template, and an extending template may
not emit text outside a block (whitespace between tags is ignored).

## Errors

Ginger reports two kinds of problems: compile-time template errors and
render-time provenance.

A template that cannot be lexed, parsed, or normalized raises
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
one position per emitted chunk: the diagnostic points at the template line where
the offending chunk starts, with the caret column clamped to that line.

At render time, an exception raised inside a generated body, block, or macro is
wrapped in `TemplateError`. The wrapper carries the provenance chain, recovered
from the native backtrace through the compile-time registry that `@template`
emits:

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
resolve inside the set, and a template referenced from several places is
compiled once. `{% extends %}` parents are compiled before their children, so
the generated definitions are always in dependency order.

`helpers = (MyHelpers, MyFilters)` emits `using MyHelpers, MyFilters` into the
host module before the templates are compiled, so the exported functions and
macros of those modules are available in every template. The entries must name
modules, not values:

```julia
@templates "views" helpers = (MyFilters,)
```

A file is discovered whatever its extension, and hidden entries (a leading `.`)
are skipped. Two files whose stems map to the same key, or a file that collides
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
package as well. There is no cache, no file watcher, and no hashing in Ginger;
the standard Julia dev loop (a reload, or `Revise.jl`) re-expands the macros.

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

## Status

M6 covers single-file rendering, inferred context, escaping, the standard helper
library, template composition through macros, includes, and imports, static
template inheritance, provenance diagnostics (caret `TemplateSyntaxError`s, the
compile-time registry, `TemplateError`, and `template_backtrace`), and
`@templates` directory discovery with precompilation-aware dependency tracking.
Everything described in this README is implemented; the remaining work is the
M7 polish in `PLAN.md` §18 (escape elision, benchmarks, a differential comparison
against OteraEngine, and the 1.0 API freeze).

Known limitation: cross-package `{% extends %}` is not supported. All template
references resolve inside one `@templates` expansion.

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

`test/precompile_probe` is a real package that uses `@templates`. The test suite
precompiles it in a scratch environment, then checks in separate processes that a
second load does not recompile and that editing or adding a template does. That
check is why the suite takes a minute longer than the unit tests.

Source and tests are formatted with [Runic](https://github.com/fredrikekre/Runic.jl).
