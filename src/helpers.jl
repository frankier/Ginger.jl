"""
    Ginger.DefaultHelpers

A standard set of template helpers and filters. Import the module into the host
module to make its names resolvable from templates:

```julia
using Ginger
using Ginger.DefaultHelpers
```

The scope pass treats every name imported into the host module as a global, so
templates call these helpers with no registry and no explicit declaration.

Filters follow the engine convention: a one-argument function is used directly
(`{{ name |> upper }}`), and a filter that takes extra arguments returns a
callable (`{{ title |> excerpt(80) }}`).

`escape`, `safe`, `HTMLString`, and `default` are re-exported from `Ginger`.
Generated code references `escape` fully qualified, so autoescaping works even
without this import.
"""
module DefaultHelpers

using ..Ginger: HTMLString, escape, safe, default

export HTMLString, escape, safe, default
export upper, lower, title, capitalize, trim
export excerpt, truncate_at, replace_with, join_with, default_to, starts_with

# --- text ------------------------------------------------------------------

"""
    upper(x)

Convert `x` to uppercase text. Use directly as a filter: `{{ name |> upper }}`.
The result is a plain `String`, so autoescaping still applies.
"""
upper(x) = uppercase(string(x))

"""
    lower(x)

Convert `x` to lowercase text. Use directly as a filter: `{{ name |> lower }}`.
"""
lower(x) = lowercase(string(x))

"""
    title(x)

Title-case `x`. Use directly as a filter: `{{ heading |> title }}`.
"""
title(x) = titlecase(string(x))

"""
    capitalize(x)

Uppercase the first character of `x`. Use directly as a filter:
`{{ name |> capitalize }}`.
"""
capitalize(x) = uppercasefirst(string(x))

"""
    trim(x)

Remove leading and trailing whitespace from `x`. Use directly as a filter:
`{{ value |> trim }}`.
"""
trim(x) = strip(string(x))

# --- parameterized filters -------------------------------------------------

"""
    excerpt(n)

Return a filter that truncates to at most `n` characters and appends `…` when
the text is longer. `n` counts characters, not bytes.

```jinja
{{ post.body |> excerpt(80) }}
```
"""
function excerpt(n::Integer)
    n < 0 && throw(ArgumentError("excerpt length must be non-negative, got $n"))
    return s -> begin
        str = string(s)
        length(str) <= n ? str : first(str, n) * "…"
    end
end

"""
    truncate_at(n)

Return `Base.Fix2(first, n)`, a filter that keeps the first `n` elements of an
iterable or the first `n` characters of a string.

```jinja
{{ title |> truncate_at(20) }}
```
"""
truncate_at(n::Integer) = Base.Fix2(first, n)

"""
    replace_with(from, to = "")

Return a filter that replaces each occurrence of `from` with `to`. `from` and
`to` are passed to `Base.replace`, so they can be strings, characters, or
regexes.

```jinja
{{ handle |> replace_with("@example.com", "") }}
```
"""
replace_with(from, to = "") = s -> replace(string(s), from => to)

"""
    join_with(sep = "")

Return a filter that joins the elements of an iterable with `sep`.

```jinja
{{ tags |> join_with(", ") }}
```
"""
join_with(sep = "") = xs -> join(xs, sep)

"""
    starts_with(prefix)

Return `Base.Fix2(startswith, prefix)`, a filter that tests whether the piped
value starts with `prefix`.

```jinja
{{ path |> starts_with("/admin") }}
```
"""
starts_with(prefix) = Base.Fix2(startswith, prefix)

"""
    default_to(fallback)

Return a filter that substitutes `fallback` when the piped value is an
`Undefined` context variable (with `undefined = :lenient` or `:default`).

```jinja
{{ nickname |> default_to("Anonymous") }}
```
"""
default_to(fallback) = x -> default(x, fallback)

end # module DefaultHelpers
