# Composition and inheritance

All template references—`extends`, `include`, `import`, `from`—resolve inside the
enclosing `@template` / `@templates` unit and are compiled into the same
expansion. A template referenced from several places is compiled once, and a
reference cycle is a compile-time error.

## Macros

A macro is a reusable fragment compiled to a generated function that builds an
`IOBuffer` and returns an [`HTMLString`](@ref), so a macro result is not escaped
twice:

```jinja
{% macro badge(text, kind = "info") %}<span class="{{ kind }}">{{ text }}</span>{% endmacro %}
{{ badge("Hi") }}
```

A macro body sees its arguments, the template's other macros, and host-module
helpers. It does **not** see the caller's context; a free variable that is not one
of those is a compile-time error. Macro definitions must appear at the top level,
and duplicate macro names are rejected.

## Includes

`{% include %}` renders another template in place. The render context passes
through, and `with` adds or overrides bindings:

```jinja
{% include "partials/head.html" %}
{% include "partials/head.html" with heading = "Posts" %}
```

Only the render context crosses an include boundary. A loop variable or other
local is not visible inside the included template unless it is passed with
`with`. The included template gets a fresh block namespace, so its own blocks
resolve to its own defaults.

## Imports

`{% import %}` binds another template's macro namespace, and `{% from %}` binds
individual macros:

```jinja
{% import "forms.html" as forms %}
{{ forms.field("email") }}

{% from "forms.html" import field, label as lbl %}
{{ lbl("Email") }} {{ field("email") }}
```

## Inheritance

`{% extends %}` composes a child template with a base. The child overrides named
`{% block %}` regions; output outside a block is a compile-time error:

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

Nested blocks and multi-level inheritance work, and a child's macros and imports
are visible inside its blocks.

### How it compiles

Composition is entirely static. Each template compiles to a body function and one
function per block. A child body passes its blocks to its parent with `merge`:

```julia
@noinline function __ginger_body_index__(out, ctx, blocks)
    return __ginger_body_base__(out, ctx, merge(__ginger_blocks_index__, blocks))
end
```

Incoming blocks from a more-derived template win, which is why the child's own
blocks are the first argument to `merge`. A block site dispatches through the
resulting concrete `NamedTuple`, which constant-folds. `super()` is a direct call
on a compile-time-known function, so there is no runtime block registry and no
`super` object.

## Restrictions

These are checked at macro-expansion time:

- `{% extends %}` must appear once, at the top level.
- `{% block %}` may not appear under control flow. Nested blocks directly inside
  a block are allowed.
- `{% macro %}` must appear at the top level.
- Block and macro names must be unique within a template.
- An extending template may not emit non-whitespace output outside a block.
- `super()` may only appear inside a block.

## Cross-package `extends`

All template references resolve within one `@templates` unit. Cross-package
`extends` is not supported in 1.0. If several packages need to share a base
template, keep the base in one unit and re-export the compiled `Template`, or
copy the base into the consuming package's unit. This is a documented
limitation.
