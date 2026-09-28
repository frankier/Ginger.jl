# Ginger.jl — Implementation Plan

A Jinja-style template engine for Julia that compiles templates to Julia code
**during macro expansion**, so that rendering is plain, type-specialized Julia
with no runtime parsing, no runtime compilation, and no generated modules at
runtime.

The syntax is inspired by
[OteraEngine.jl](https://mommawatasu.github.io/OteraEngine.jl/dev/tutorial/) and
Jinja2. The execution model is different and the engine is **not** a drop-in
replacement for either.

> **Design history.** v1 built a template AST with a recursive-descent parser.
> v2 replaced it with shallow synthesis into Julia source parsed by `Base.JuliaSyntax`.
> v3 (this document) makes compilation happen at macro-expansion time, removes
> the runtime loader and `Core.eval`, and makes block composition static.

---

## 1. Design decisions

These are settled and drive everything below.

1. **Macro-only compilation.** Templates compile during macro expansion into the
   host module. There is no runtime `Engine`, no `Core.eval`, no generated
   `Module`, no cache, and no world-age handling.
2. **Inferred context.** Free-variable analysis determines which names come from
   the render context. There is no explicit `{% context %}` declaration.
3. **Static block composition.** Because one `@templates` expansion sees the whole
   inheritance graph, `super()` resolves to statically known functions at compile
   time. There is no runtime block registry or `super` object.
4. **Relative virtual paths.** Generated code stores package-relative virtual paths
   in `LineNumberNode`s; the runtime resolves them against a configured source
   root for display.
5. **Escaping is ours.** We keep our own `HTMLString` / `escape` / `safe`.
   HypertextLiteral is not adopted.
6. **Provenance from native backtraces.** No task-local frame stack; errors are
   attributed by walking `catch_backtrace()` and looking up generated function
   names in a compile-time registry.
7. **Streaming lexer → emitter.** The lexer emits synthetic chunks and builds the
   offset map in one pass; there is no `Segment` intermediate representation.
8. **No TOML config.** Configuration is a plain immutable `Config` value.
9. **Immutable config + NamedTuple templates.** No mutable registry objects.
10. **MacroTools.jl** is used for `postwalk` in normalization. `rmlines` is not
    used, because the parser's line numbers are the position source.

## 2. Goals and non-goals

### Goals

1. **Compile, don't interpret.** Parsing and code generation happen once, at
   macro-expansion time, and the result is cached in the host package's
   precompile image.
2. **Julia all the way down.** `{% %}` contains arbitrary Julia statements
   (including partial blocks such as `{% while cond %}`). `{{ }}` contains an
   arbitrary Julia expression.
3. **One grammar.** Nested-tag matching, precedence, and error recovery are
   Julia's job via `Base.JuliaSyntax`.
4. **Composition, not interpretation.** `include`/`extends`/`block`/`macro`/
   `import` compile to ordinary function definitions and calls.
5. **HTML stack traces.** Backtraces point at `templates/index.html:42`, and
   render errors report the include/extends provenance chain.
6. **Injectable helpers** usable as filters and as ordinary callables, with
   `escape` and `safe` always available.
7. **Fast.** Type-stable generated code, coalesced writes, static block dispatch,
   no per-render symbol lookup.

### Non-goals

- Jinja2 compatibility; OteraEngine.jl compatibility.
- Sandboxing. Templates are trusted Julia code.
- Runtime template loading. Templates are known at macro-expansion time.
- Cross-package `extends` in v1 (see §8.5).
- Explicit `{% context %}` declarations (rejected in favour of inference).

## 3. Architecture overview

```
                    .html / .ginger source
                            │
                 ┌──────────▼──────────┐
                 │ lexer.jl            │  streaming: text / {{ }} / {% %} / {# #}
                 │                     │  whitespace control, raw, quote-aware
                 └──────────┬──────────┘
                            │ (streamed)
                 ┌──────────▼──────────┐
                 │ synthesize.jl       │  chunks ─▶ synthetic Julia source
                 │                     │  + OffsetMap, as it streams
                 └──────────┬──────────┘
                            │ source + OffsetMap
                 ┌──────────▼──────────┐
                 │ parse.jl            │  Base.JuliaSyntax.parseall(Expr, src;
                 │                     │  filename=virtual); ParseError
                 │                     │  diagnostics ─▶ template Pos
                 └──────────┬──────────┘
                            │ Expr + synthetic→template line map
                 ┌──────────▼──────────┐
                 │ normalize.jl        │  MacroTools.postwalk: expand markers,
                 │                     │  autoescape, restrictions, line rewrite
                 └──────────┬──────────┘
                            │ Expr per template
                 ┌──────────▼──────────┐
                 │ blocks.jl + macros  │  compose Exprs, resolve inheritance,
                 │                     │  emit function defs + Template values
                 └──────────┬──────────┘
                            │ host-module Expr (spliced by @templates)
                 ┌──────────▼──────────┐
                 │ runtime.jl          │  HTMLString, escape, safe, block dispatch
                 └──────────┬──────────┘
                            │
                        render(...) ─▶ String / IO
```

**Invariants.**

- Identifiers beginning with `__ginger_` are reserved.
- All `__ginger_*` markers are removed before the Expr is returned from the macro.
- Markers are plain calls with `do`-block or lambda bodies, not macros; there is
  no macro hygiene to reason about.
- No file path stored in generated code is absolute except `include_dependency`
  arguments.

## 4. Syntax

### 4.1 Delimiters

| Form | Meaning |
|------|---------|
| `{{ expr }}` | Julia expression, HTML-escaped by default |
| `{% stmt %}` | Julia statements / structural tags |
| `{# … #}` | comment (nestable) |
| `{% raw %} … {% endraw %}` | literal text |

Whitespace control: `{{-`/`-}}`, `{%-`/`-%}`, `{#-`/`-#}` strip adjacent
whitespace; `+` variants force preservation; `trim_blocks` and `lstrip_blocks`
config options; `autospace` sets both.

### 4.2 `{% %}` structural tags

A tag is split into a leading keyword and a remainder.

**Julia keywords** are emitted verbatim, so Julia's parser matches them: `if`,
`elseif`, `else`, `for`, `while`, `let`, `begin`, `try`, `catch`, `finally`,
`function`, `do`, `quote`, `end`.

`endif`, `endfor`, `endwhile`, `endlet`, `endblock`, `endmacro`
are accepted aliases and all translate to `end`. Structural matching is Julia's;
alias-name mismatch is not verified (Julia reports the resulting structure error
at the right offset, which the offset map translates).

**Template-only keywords** translate to reserved markers: `block`/`endblock`,
`extends`, `include`, `import`, `from … import …`, `macro`/`endmacro`,
`raw`/`endraw`.

**Everything else** is emitted verbatim as Julia statements, parsed with
`Base.JuliaSyntax`. This gives `{% x = compute(a, b) %}`,
`{% function f(x); …; end %}` (top level), and `{% while cond %}` for free.

`{% for x in it %}…{% else %}…{% endfor %}` is supported. Julia has no
`for`/`else`, so synthesis emits a `ran_any` flag and runs the `else` body only
when the iterator produced nothing.

### 4.3 `{{ }}` expressions and filters

Arbitrary Julia expressions. Filters use Julia's pipe with **ordinary Julia
semantics**; the engine does no rewriting:

| source | Julia meaning |
|--------|---------------|
| `a \|> f` | `f(a)` |
| `a \|> f(1, 2)` | `f(1, 2)(a)` |
| `a \|> f(1) \|> g` | `g(f(1)(a))` |

The rule: **a parameterized filter must return a callable.**

```julia
upper(s)     = uppercase(s)
excerpt(n)   = s -> length(s) <= n ? s : first(s, n) * "…"
truncate_at(n) = Base.Fix2(first, n)
```

Autoescape: every `{{ }}` is emitted as `escape(expr)`. `escape` is idempotent on
safe values, so `{{ x |> safe }}` and `{{ safe(x) }}` pass through unchanged.

### 4.4 Context

Templates do not declare their context. `scope.jl` (§7) infers it at
macro-expansion time from the free variables of the generated body:

- Locally bound names (loop binders, `let` bindings, function and `do`
  parameters, assignments, this template's blocks and macros) are not context.
- Names resolvable in the host module (checked with `isdefined`) are not context;
  this is how callable helpers work without a registry.
- Everything else is a context variable, bound from the render context.

Rendering is `TEMPLATES.index(; user = …, posts = …)`. A missing context
variable is reported according to the `undefined` config mode
(`:strict`, `:lenient`, `:default`; §7).

### 4.5 Divergences from OteraEngine / Jinja

| Topic | Ginger | Otera | Jinja2 |
|-------|--------|-------|--------|
| When compiled | macro expansion | `Template(...)` call | runtime |
| Context | inferred from free variables | inferred from undefined symbols | dict / inferred |
| Implementation | synthetic Julia source + Julia parser | template AST | own compiler |
| Filters | `\|>`, user-curried args | `\|>`, spliced args | `\|`, spliced args |
| Scope | Julia scoping | Julia-ish | Jinja scoping |
| `extends` | static, same unit | literal path | expression |
| Blocks | static function composition | text substitution | runtime |
| `super.super()` | `super(2)` | supported | supported |
| Macros | generated functions → `HTMLString` | generated functions | Jinja macros |
| Config | immutable `Config` | TOML | `Environment` |

A bare `|` is **not** reinterpreted; it remains Julia's `bitor`.

## 5. Lexer (streaming)

```julia
struct Pos
    file::String         # virtual, package-relative
    line::Int
    col::Int
    offset::Int          # byte offset in the template source
end
```

The lexer exposes an iterator of tagged tokens (`TEXT`, `EXPR`, `STMT`, `RAW`),
each with `Pos` and whitespace-control flags, and consumes them directly in
`synthesize.jl`. There is no materialized segment vector.

Responsibilities:

- Configurable delimiter pairs.
- Nested `{# #}` comments.
- `{% raw %}` handled entirely here: the content becomes a single `TEXT` token
  and is never interpreted.
- Whitespace control applied to the preceding text token and the current token's
  strip/keep flags.
- A thin stack for template-only openers (`block`, `macro`) so an
  unmatched `{% endblock %}` is a clear error. Julia constructs are untracked.
- **Quote- and bracket-aware tag scanning**: while scanning a tag, do not stop at
  a `}}`/`%}` inside a Julia string, char, backtick, or comment. Track `"`,
  `"""`, `'`, `` ` ``, `$(`, string-macro prefixes, escapes, and bracket
  nesting. This is the main edge-case surface and gets a dedicated test matrix.

## 6. Synthesis, parsing, and the offset map

### 6.1 Synthetic source

`synthesize.jl` consumes lexer tokens and appends to a buffer while recording an
`OffsetMap`.

| Token | Emitted |
|-------|---------|
| `TEXT`/`RAW` | `print(out, <repr(text)>)` |
| `{{ e }}` | `__ginger_print__(<e>)` |
| `{% if c %}` … `{% end %}` | `if <c>` … `end` |
| `{% x = 1 %}` | `x = 1` |
| `{% block content %}` … `{% endblock %}` | `__ginger_block__(:content) do` … `end` |
| `{% macro f(a, b=1) %}` … `{% endmacro %}` | `__ginger_macro__(:f, (a, b=1) -> begin` … `end)` |
| `{% extends "base.html" %}` | `__ginger_extends__("base.html")` |
| `{% include "x.html" with a=1 %}` | `__ginger_include__("x.html"; a = 1)` |
| `{% import "m.html" as m %}` | `__ginger_import__(:m, "m.html")` |
| `{% from "m.html" import a, b as c %}` | `__ginger_fromimport__("m.html", (a = :a, c = :b))` |
| `{# … #}` | nothing |

Text goes through `repr`, so quotes, backslashes, `$`, and newlines are escaped
into a single-line literal that cannot escape its context. Markers are ordinary
calls with `do`/lambda bodies, so `Base.JuliaSyntax` parses the buffer without any
macro being defined.

### 6.2 Offset map

```julia
struct MapEntry
    out_start::Int       # byte offset in the synthetic source
    out_end::Int
    pos::Pos
end

struct OffsetMap
    entries::Vector{MapEntry}
end
```

One entry per emitted line-chunk, with per-source-line sub-entries for verbatim
multi-line fragments. `lookup(map, out_offset)::Pos` binary-searches.

Consumers: `parse.jl` maps `Base.JuliaSyntax.ParseError` diagnostics through the
map to template positions; `normalize.jl` derives a synthetic-line →
template-line array from it.

### 6.3 Parsing

`Base.JuliaSyntax.parseall(Expr, source; filename = virtual_path)` returns the
synthetic buffer as an `Expr` whose `LineNumberNode`s already carry the virtual
filename. The parser **throws** `Base.JuliaSyntax.ParseError` on syntax errors;
its `diagnostics` each expose `first_byte`, `last_byte`, `level`, and `message`,
which the offset map turns into caret diagnostics (§12.1). There is no CST walk:
normalization operates directly on the `Expr`, and the parser's line numbers are
rewritten through the synthetic → template line array.

### 6.4 Virtual paths

The `filename` passed to `Base.JuliaSyntax.parseall` and used in `LineNumberNode`s is the
template path **relative to the package source root**, e.g. `templates/index.html`
— never absolute. Absolute build-time paths would break precompile-image
relocatability (Julia 1.11+). `errors.jl` resolves virtual paths to absolute for
display and editor jumps using `Config.source_root`, plus `Base.pkgdir` when the
root is inside a package.

`include_dependency` still receives absolute build-time paths; that is correct,
since those are invalidation triggers, not runtime values.

## 7. Normalization

A single `MacroTools.postwalk` over the parsed `Expr` (line numbers are preserved
by the parser and rewritten, so `rmlines` is not used):

1. **Marker expansion.**
   - `__ginger_print__(e)` → `print(out, escape(e))`.
   - `__ginger_block__(:name) do … end` → the call site becomes
     `__ginger_render_block__(blocks, :name, __ginger_block_<tid>_<name>__, out, ctx)`,
     and the body becomes a generated module-level function (recursively
     normalized).
   - `__ginger_macro__(:name, lambda)` → a generated module-level function
     returning `HTMLString`; the definition site emits nothing.
   - `__ginger_extends__("p")` → recorded in the template's metadata; removed.
   - `__ginger_include__`, `__ginger_import__`, `__ginger_fromimport__` → calls
     into the composed template graph (§8).
   - `super()` / `super(n)` inside a block body → statically resolved function
     calls (§8.2).
2. **Restriction checks.**
   - Blocks and macros may not appear under control flow. A context enum
     `TopLevel | InBlock | InControlFlow` is tracked during the walk. `if`,
     `for`, `while`, `let`, `try`, `catch`, `finally`, comprehensions, anonymous
     functions, and `do` bodies set `InControlFlow`; block and macro bodies set
     `InBlock`. A block/macro marker in `InControlFlow` is a
     `TemplateSyntaxError`. Nested blocks directly inside a block are allowed.
   - No loose text in an extending template: with `{% extends %}`, any top-level
     `print` outside a block or macro is an error.
   - `extends` at most once, top level only.
   - Duplicate block or macro names in one template are errors.
3. **Context prologue (inferred).** Free variables of the normalized body are
   computed by `scope.jl`, excluding locally bound names and host-module globals
   (`isdefined`). Each remaining name is bound from `ctx`:
   `user = Ginger.fetchvar(ctx, :user, "templates/index.html", 3)`, alongside
   the reserved bindings `out`, `ctx`, `blocks`. `fetchvar` honours the
   `undefined` config mode: `:strict` throws `MissingContextVariable`,
   `:lenient` binds an `Undefined` singleton (renders as `""`, throws on
   property/index access), `:default` adds a `default(x, val)` helper.
4. **Line numbers.** The parser's `LineNumberNode`s are rewritten through the
   synthetic → template line array, so statements report real template lines
   while keeping the virtual path.
5. **`@__FILE__` / `@__LINE__` / `@__DIR__`** need no rewriting: the parser was
   given the virtual path, so `@__FILE__` expands to it and `@__LINE__` to the
   rewritten template line. `@__DIR__` therefore yields the virtual directory.

## 8. Composition

### 8.1 Generated shape

Each template `t` (identified by `tid`, a stable hash of its path) produces:

```julia
@noinline function __ginger_block_<tid>_<name>__(out, ctx, blocks)
    … # normalized block body
end

const __ginger_blocks_<tid>__ = (name = __ginger_block_<tid>_<name>__, …)

@noinline function __ginger_body_<tid>__(out, ctx, blocks)
    … # normalized body; block sites call __ginger_render_block__
end

@noinline function __ginger_enter_<tid>__(out; kwargs...)
    return __ginger_body_<tid>__(out, NamedTuple(kwargs), NamedTuple())
end
```

Block dispatch is a tiny, inlinable runtime helper:

```julia
@inline function __ginger_render_block__(blocks, name::Symbol, default, out, ctx)
    return hasproperty(blocks, name) ? getproperty(blocks, name)(out, ctx, blocks) :
                                      default(out, ctx, blocks)
end
```

Because `blocks` always has a concrete `NamedTuple` type at the call site, the
`hasproperty` branch constant-folds and the call devirtualizes.

### 8.2 `extends` + `block` + `super` (static)

- The base template's body is generated **once** and takes `blocks` as an
  argument.
- An extending template's body delegates:

  ```julia
  @noinline function __ginger_body_index__(out, ctx, blocks)
      return __ginger_body_base__(out, ctx,
          merge(blocks, __ginger_blocks_index__))
  end
  ```

  Incoming `blocks` (from a more-derived template) win over the template's own.
- A leaf that extends `index` passes its own `blocks` through `index`, so the
  chain is built by `merge` of compile-time-constant `NamedTuple`s, which Julia
  folds.
- `super()` inside a block is resolved **at compile time** to the next ancestor's
  block function (or its default); `super(2)` to two levels up. There is no
  `BlockSuper` object, no `dispatch_chain`, and no `enter_blocks`.
- `render_block` falls back to the defining template's default when no ancestor
  installed an override.

This keeps one copy of each body (no per-child duplication) while making all
dispatch static and type-stable.

### 8.3 `include`

`{% include "partials/head.html" %}` compiles the referenced template into the
same expansion and emits a direct call to its body with a fresh `blocks`
(`NamedTuple()`), so the included template's own blocks resolve to its own
defaults. The current `ctx` is passed through (`with a=1` merges extra bindings);
the included template's own scope pass decides which names it reads from it.

### 8.4 Macros

```julia
@noinline function input(name, value = "", type = "text")
    out = IOBuffer()
    ctx = NamedTuple()
    …               # normalized body, escaping as usual
    return HTMLString(String(take!(out)))
end
```

Macro bodies see their arguments and host-module/helper names, not the caller's
context; their scope pass runs against an empty context, so any free variable
that is not a host-module global is a compile-time error. `HTMLString` return means no double-escaping. Duplicate names are
rejected; type-dispatched helpers are written in Julia and injected by scope.

### 8.5 `import` / `from`

`{% import "forms.html" as forms %}` binds `forms` to the composed template's
macro/block namespace (a `NamedTuple` of functions), so
`{{ forms.input("x") }}` is a plain qualified call.
`{% from "x.html" import a, b as c %}` emits `a = …a; c = …b`.

All template references (`include`, `extends`, `import`, `from`) resolve within
the enclosing `@templates` unit. Cross-package `extends` is out of scope for v1:
a package that wants to extend another's base exports its template set, and the
consumer passes it explicitly (`@templates "views" extends = OtherPkg.BASE`).
This is documented as a limitation.

## 9. Helpers and filters

There is no mutable registry. Helpers come from two sources:

1. **Names in the host module.** Generated code is spliced into the host module,
   so any function defined or imported there is callable from a template without
   declaration; the scope pass recognizes these as globals via `isdefined`. This
   is the primary mechanism and needs no API.
2. **Helper modules passed to the macro.** `@templates "templates" helpers =
   (MyHelpers, MyFilters)` emits `using MyHelpers, MyFilters` into the host
   module, pulling in both functions and macros.

```julia
module MyApp
using Ginger
using Ginger.DefaultHelpers          # escape, safe, upper, lower, join, …
include("filters.jl")                # slugify, excerpt, …

@templates "templates" as TPL
end

Ginger.render(TPL.index; user = "frank", posts = posts)
```

- `escape` and `safe` are provided by `Ginger.DefaultHelpers` (and referenced
  fully qualified inside generated code), so they exist even if the user does not
  import the module.
- Filter convention: a filter takes one value; a parameterized filter returns a
  callable (§4.3).

## 10. Compilation and precompilation

### 10.1 The macros

- `@template "index.html"` compiles one file and defines a `Template` const.
- `@templates "templates"` discovers all templates under a directory, resolves
  the dependency graph, compiles parents before children, and defines a single
  NamedTuple const of `Template`s (default name `TEMPLATES`; `as NAME` overrides).

Both read files at expansion time, call `Base.include_dependency` for every file
touched (including directory mtimes so new files invalidate), and splice the
generated Exprs into the host module.

### 10.2 What this buys

- No `Module`, `Core.eval`, cache, lock, dev-mode hashing, or world-age handling.
- Precompilation is automatic: macro expansion is part of parsing the host
  package, and the generated code lands in the precompile image.
- `Config` is an immutable value passed as macro arguments.

### 10.3 What this costs

- No runtime template discovery or dynamic paths.
- Name isolation comes from mangled identifiers rather than modules.
- Adding a template file requires recompiling the host package (handled by
  `include_dependency` on the directory).
- Cross-package `extends` is limited (§8.5).

### 10.4 Dev workflow

Editing a template marks the host package stale via `include_dependency`, so
`Revise.jl` (or a reload) re-expands the macros. Ginger does not implement its
own file-watching or hashing; this is deliberately delegated to the standard
Julia dev loop.

## 11. Generated code shape (worked)

`templates/base.html`:

```jinja
<!DOCTYPE html>
<html><body>{% block content %}{% endblock %}</body></html>
```

`templates/index.html`:

```jinja
{% extends "base.html" %}
{% block content %}<h1>Hello {{ user }}</h1>{% endblock %}
```

Spliced into the host module (schematically):

```julia
# ---- base.html ----
@noinline function __ginger_block_base_content__(out, ctx, blocks)
    return nothing
end

@noinline function __ginger_body_base__(out, ctx, blocks)
    print(out, "<!DOCTYPE html>\n<html><body>")
    __ginger_render_block__(blocks, :content, __ginger_block_base_content__, out, ctx)
    print(out, "</body></html>")
    return nothing
end

# ---- index.html ----
@noinline function __ginger_block_index_content__(out, ctx, blocks)
    user = Ginger.fetchvar(ctx, :user, "templates/index.html", 3)
    #= templates/index.html:3 =#
    print(out, "<h1>Hello ")
    print(out, escape(user))
    print(out, "</h1>")
    return nothing
end

const __ginger_blocks_index__ = (content = __ginger_block_index_content__,)

@noinline function __ginger_body_index__(out, ctx, blocks)
    return __ginger_body_base__(out, ctx, merge(blocks, __ginger_blocks_index__))
end

@noinline function __ginger_enter_index__(out; kwargs...)
    return __ginger_body_index__(out, NamedTuple(kwargs), NamedTuple())
end

# ---- the set ----
const TEMPLATES = (
    base  = Template("templates/base.html",  __ginger_enter_base__),
    index = Template("templates/index.html", __ginger_enter_index__),
)

# ---- provenance registry ----
const __GINGER_SOURCES__ = Dict(
    Symbol("__ginger_body_base__")   => ("templates/base.html",  :body),
    Symbol("__ginger_body_index__")  => ("templates/index.html", :body),
    Symbol("__ginger_block_index_content__") =>
        ("templates/index.html", :content),
)
```

Rendering is `render(TEMPLATES.index; user = "frank")`, which builds an
`IOBuffer`, calls the entry function, and returns `String`.

## 12. Error reporting and stack traces

### 12.1 Compile-time diagnostics

`Base.JuliaSyntax.ParseError` diagnostics carry a byte range and message in the
synthetic buffer; they are mapped through the offset map and rendered as caret
diagnostics against the template source:

```
TemplateSyntaxError: expected `end` to close `if`
  --> templates/base.html:7:3
   |
 7 | {% endif %}
   |   ^ unexpected tag `endif`
```

Ginger's own errors (restrictions in §7.2, unresolved references, duplicate
names, reserved prefix misuse) carry a `Pos` directly.

### 12.2 Runtime positions

Every statement carries a `LineNumberNode` with the virtual path and the real
template line, so an
uncaught exception backtraces to `templates/index.html:3`. Verified: a function
`eval`'d with `LineNumberNode(7, Symbol("child.html"))` reports
`@ child.html:7`. With macro expansion the mechanism is the same and needs no
`eval` at all.

### 12.3 Provenance without a frame stack

`__ginger_body_*` and `__ginger_block_*` functions are marked `@noinline` and
registered in `__GINGER_SOURCES__`. `render` catches, walks the native backtrace
via `Base.StackTraces`, and builds the chain:

```
TemplateError: MissingContextVariable: context variable `user` was not passed
  in block "content" at templates/index.html:3:9
  extends templates/base.html:12:5
  rendered from app.jl:20
```

`Ginger.template_backtrace()` returns the structured list and resolves virtual
paths to absolute using `Config.source_root`. There is no per-render push/pop and
no task-local storage.

## 13. Open questions

## 13. Resolved decisions

1. **`undefined` mode.** Default `:strict`; `:lenient` and `:default` available.
2. **Cross-package `extends`.** Allowed via
   `@templates "views" extends = OtherPkg.BASE`.
3. **Julia floor.** Julia ≥ 1.13, using the in-Base `Base.JuliaSyntax` and no
   external parser package. Newer Base features are fair game.
4. **`{% for %}…{% else %}`.** Supported.
5. **`{% filter %}`.** Dropped; it is subsumed by `{{ x |> f }}`.
6. **Naming.** `Ginger`, `Ginger.Runtime`, `Ginger.DefaultHelpers`, and the
   reserved `__ginger_` prefix.

## 14. Package layout

```
Project.toml
src/
  Ginger.jl          # module, includes, exports
  config.jl          # immutable Config: delimiters, whitespace, autoescape,
                     # source root, undefined mode
  lexer.jl           # streaming tokenizer, quote-aware scanning, raw
  synthesize.jl      # tokens -> synthetic source + OffsetMap
  parse.jl           # Base.JuliaSyntax wrappers, ParseError translation
  normalize.jl       # marker expansion (MacroTools.postwalk), restrictions,
                     # line-number rewriting
  scope.jl           # free-variable analysis, context prologue
  blocks.jl          # static block composition, render_block helper, registry
  runtime.jl         # HTMLString, escape, safe, print, Template
  loader.jl          # file discovery, reference resolution, dependency graph
  macros.jl          # @template, @templates
  api.jl             # render, render!, template_backtrace
  errors.jl          # TemplateSyntaxError, TemplateError, caret diagnostics
  helpers.jl         # DefaultHelpers: escape, safe, upper, lower, join, …
test/
  runtests.jl
  test_lexer.jl          # delimiters, whitespace matrix, quote/bracket scanning
  test_synthesize.jl     # chunk emission, repr-escaping safety, offset map
  test_normalize.jl      # marker expansion, restrictions, text-outside-block
  test_render.jl
  test_scope.jl          # free-variable analysis, locals vs globals vs context
  test_filters.jl        # curried filters, Base.Fix1, autoescape, safe
  test_inheritance.jl    # extends/block/super, multi-level, nested blocks
  test_macros.jl
  test_errors.jl         # compile-time carets + runtime provenance chain
  test_precompile.jl
  templates/             # golden templates + expected output
  precompile_probe/      # a package using @templates
docs/
  make.jl
  src/index.md
  src/syntax.md
  src/context.md
  src/filters.md
  src/inheritance.md
  src/errors.md
  src/precompilation.md
  src/migration-from-otera.md
```

Dependencies: `MacroTools`. Parsing uses `Base.JuliaSyntax`, shipped in Julia
1.13, so there is no external parser dependency; `Compat` entry `julia = "1.13"`.
No TOML, no HypertextLiteral, and no third-party scope-analysis package (scope
analysis is hand-rolled).

## 15. Public API sketch

```julia
using Ginger

module MyApp
using Ginger
using Ginger.DefaultHelpers
include("filters.jl")

@templates "templates" as TPL
end

Ginger.render(TPL.index; user = "frank", posts = posts)   # -> String
Ginger.render!(stdout, TPL.index; user = "frank")

TPL.index                                   # a Template
TPL.index(; user = "frank")                 # shorthand for render

# Single file:
@template "emails/welcome.html" as WELCOME
Ginger.render(WELCOME; user = "frank")

# Inline (compile-time string literal):
t = ginger"Hello {{ name }}!"
t(name = "frank")
```

## 16. Performance notes

- Text runs are coalesced into single `print(out, "…")` calls.
- Context is a `NamedTuple` built once per render; generated body functions
  specialize on its concrete type, and the inferred prologue bindings
  (`user = fetchvar(ctx, :user, …)`) compile to typed field loads.
- Block dispatch is `hasproperty`/`getproperty` on a concrete `NamedTuple` and
  constant-folds.
- `escape` is idempotent and cheap; syntactic elision for statically-safe
  expressions (`safe(…)`, `HTMLString(…)`, local macro calls) is an M7
  optimization that never affects correctness.
- Curried filters allocate a closure per render; hot paths should use named
  1-arg filters.
- Benchmarks (M7) compare against OteraEngine and hand-written interpolation,
  tracking allocations per render for text-heavy, loop-heavy, and
  inheritance-heavy templates.

## 17. Testing strategy

- **Lexer**: delimiter forms, whitespace matrix, quote/bracket scanning
  (`"}}"`, `raw"…"` with delimiters inside, comments, `$(`).
- **Synthesis**: `repr`-escaping safety, marker emission, offset-map round-trip
  for single-line, multi-line, and text-adjacent fragments.
- **Normalization**: marker expansion, line-number rewriting, `for`/`else`
  lowering, rejection of blocks under control flow, rejection of loose text under
  `extends`, duplicate block/macro detection.
- **Scope**: free variables are classified into locals, host-module globals, and
  context; loop binders and `let`/function parameters are not context; missing
  context follows the `undefined` mode.
- **Rendering**: golden templates with expected output and context fixtures.
- **Filters**: curried helpers, `Base.Fix1`, chained `|>`,
  `escape`/`safe` idempotence, autoescape on/off.
- **Inheritance**: single/multi-level extends, `super()`, `super(2)`,
  block-in-block, include-inside-block, static dispatch correctness.
- **Errors**: compile-time carets point at the exact template line/column;
  `TemplateError` chains list templates in order; a raw Julia backtrace contains
  the virtual `.html` path.
- **Precompilation**: `test/precompile_probe` is a real package using
  `@templates`. CI compiles it, then in a second process asserts templates render,
  no recompilation is triggered, and editing a template (or adding one) marks the
  package stale.
- **Differential (dev-only)**: run the overlapping subset through OteraEngine and
  Ginger and compare, to keep the "reasonable overlap" claim honest.

## 18. Milestones

| M | Deliverable | Contents |
|---|-------------|----------|
| M0 | Single-file end-to-end | `Config`, streaming lexer, synthesis + offset map, `Base.JuliaSyntax` parse, minimal normalize (text + `{{ }}`), `@template`, `render` |
| M1 | Full Julia + diagnostics | all Julia control flow, `for`/`else`, `raw`, comments, error translation, restrictions, virtual paths, line rewriting |
| M2 | Scope + helpers + escaping | `scope.jl` inference, context prologue, `HTMLString`/`escape`/`safe`, `DefaultHelpers`, curried-filter docs and tests |
| M3 | Macros + include + import | `{% macro %}`, `{% include %}`, `{% import %}` / `{% from %}` |
| M4 | Inheritance | `{% extends %}`, `{% block %}`, static composition, `super()`/`super(n)`, nested blocks |
| M5 | Errors | provenance registry, `TemplateError`, `template_backtrace`, caret diagnostics |
| M6 | `@templates` + precompilation | directory discovery, dependency ordering, `include_dependency`, precompile probe, Revise dev flow, docs |
| M7 | Polish | escape elision, benchmarks, differential vs Otera, migration guide, 1.0 API freeze |

Each milestone ends with docs updated and the full test suite green.

## 19. Worked example (end-to-end)

`templates/base.html`:

```jinja
<!DOCTYPE html>
<html>
  <head><title>{% block title %}Ginger{% endblock %}</title></head>
  <body>{% block content %}{% endblock %}</body>
</html>
```

`templates/index.html`:

```jinja
{% extends "base.html" %}
{% import "forms.html" as forms %}
{% block title %}{{ title |> upper }}{% endblock %}
{% block content %}
  {% for post in posts %}
    <article>{{ post.body |> excerpt(80) |> safe }}</article>
  {% endfor %}
  {{ forms.search(placeholder = "Search…") }}
{% endblock %}
```

with the host-module helper

```julia
excerpt(n) = s -> first(s, n)      # curried filter
```

Rendering:

```julia
Ginger.render(TEMPLATES.index; title = "Posts", posts = [Post("…"), Post("…")])
```

The macro expansion compiles both templates in dependency order, hoists the two
`index` block functions, builds `__ginger_blocks_index__`, wires `index`'s body
to `base` with a `merge`, resolves `super()` statically (there is none here), and
binds `title`/`posts` as inferred context variables in the prologue. At render time there is no
parsing, no `eval`, no dictionary lookup, and no string templating — only typed
Julia function calls.