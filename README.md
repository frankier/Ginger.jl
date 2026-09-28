# Ginger.jl

A Jinja-style template engine for Julia that compiles templates to Julia code
during macro expansion. Rendering is ordinary, type-specialized Julia: no runtime
parsing, no runtime compilation, and no modules generated at runtime.

This repository currently implements **milestone M4** from `PLAN.md`: a
single-file pipeline with the full Julia control-flow surface, inferred context,
HTML escaping, the `DefaultHelpers` filter library, template composition through
`{% macro %}`, `{% include %}`, `{% import %}`, and `{% from %}`, and static
template inheritance through `{% extends %}`, `{% block %}`, and `super()` /
`super(n)`. See [Status](#status) for what is and is not in place.

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
  template line, and generated `LineNumberNode`s carry the virtual template path
  so runtime backtraces point at `templates/index.html:42`.
- **Macro**: `@template "path" [as NAME] [config = Config(...)]`, with
  `include_dependency` so template edits invalidate the host package.

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

## Status

M4 covers single-file rendering, inferred context, escaping, the standard helper
library, template composition through macros, includes, and imports, and static
template inheritance. Not yet implemented (see `PLAN.md` §18):

- the provenance registry and structured `template_backtrace` (M5), including
  caret diagnostics that render the offending template line;
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
