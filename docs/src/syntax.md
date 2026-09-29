# Syntax

## Delimiters

| Form | Meaning |
|------|---------|
| `{{ expr }}` | Julia expression, HTML-escaped by default |
| `{% stmt %}` | Julia statements and structural tags |
| `{# … #}` | Comment. Nestable, emits nothing |
| `{% raw %} … {% endraw %}` | Literal text. Ginger never interprets delimiters inside |

Ginger configures all three delimiter pairs through [`Config`](@ref).

## Whitespace control

A `-` on the inside edge of a tag strips adjacent whitespace. A `+` forces it to
be preserved:

```jinja
{{- value -}}      {# strip both sides #}
{%- if x +%}…{% endif %}
{#- comment -#}
```

Two config flags handle the common cases:

- `trim_blocks` removes the first newline after a block tag.
- `lstrip_blocks` removes whitespace from the start of a line up to a block tag.
- `autospace = true` enables both. `autospace = false` disables both.

Ginger applies `trim_blocks` after expression tags as well as block tags. Jinja
applies it to block tags only. If exact parity with Jinja matters, keep the
trailing newline with `+` or turn `trim_blocks` off.

`lstrip_blocks` never eats significant indentation after text, and the
`trim_blocks`/`lstrip_blocks` flags never touch `{% raw %}` content.

## Comments

```jinja
{# a comment; {# comments nest #} #}
```

## Statements and control flow

`{% %}` contains arbitrary Julia statements. Ginger emits the leading keyword
verbatim, so Julia's parser matches the structure:

```jinja
{% if user.admin %}
  <a href="/admin">Admin</a>
{% elseif user.member %}
  Member
{% else %}
  Guest
{% endif %}
```

`if` / `elseif` / `else`, `for`, `while`, `let`, `begin`, `try` / `catch` /
`finally`, `function`, `do` blocks, and `quote` all work. Close them with
`{% end %}` or the alias `endif`, `endfor`, `endwhile`, `endlet`, `endblock`,
`endmacro`. Ginger does not verify alias mismatch. Julia reports the resulting
structure error at the template offset.

Assignments and other statements work too:

```jinja
{% x = compute(a, b) %}
{% function local_helper(v) %}
  return v * 2
{% end %}
```

### `for` … `else`

Julia has no `for`/`else`, so Ginger lowers it. The `else` body runs only when
the iterator produces nothing:

```jinja
{% for post in posts %}
  <article>{{ post.title }}</article>
{% else %}
  <p>No posts yet.</p>
{% endfor %}
```

## Expressions

`{{ }}` contains an arbitrary Julia expression:

```jinja
{{ user.name }}
{{ posts[1].title }}
{{ length(posts) == 0 ? "none" : "some" }}
```

Ginger HTML-escapes every expression by default. See
[Filters and helpers](filters.md) for the escaping rules and the `safe` bypass.

## Raw

```jinja
{% raw %}
  {{ this is literal }}
  {% if this is literal too %}
{% endraw %}
```

Explicit `-` markers on the two raw tags trim the body edges. `trim_blocks` and
`lstrip_blocks` never modify raw text.
