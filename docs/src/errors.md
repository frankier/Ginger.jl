# Errors

Ginger reports two kinds of problems: compile-time template errors and
render-time provenance.

## Compile-time diagnostics

A template that Ginger cannot lex, parse, or normalize raises
[`TemplateSyntaxError`](@ref). When the offending template text is available, the
error renders the line with a caret:

```text
TemplateSyntaxError: unexpected `)`
  --> templates/syntax_err.html:3:10
    |
  3 | {{ 1 + }}
    |          ^
```

The line and caret come from the synthetic-to-template offset map, which records
one position per emitted chunk. The diagnostic points at the template line where
the offending chunk starts, with the caret column clamped to that line.

Ginger's own checks—restrictions, duplicate names, unresolved references, and
reserved-prefix misuse—carry a `Pos` directly and render the same way.

## Runtime positions

Every statement carries a `LineNumberNode` with the virtual template path and the
real template line, so an uncaught exception backtraces to
`templates/index.html:3`. The parser receives the virtual path as its filename,
so `@__FILE__` expands to the virtual path, `@__LINE__` to the template line, and
`@__DIR__` to the virtual directory. No source rewriting is necessary.

Virtual paths are package-relative, never absolute build-time paths, so precompile
images stay relocatable. [`Config.source_root`](@ref Config) resolves them to
absolute paths for display and editor jumps.

## Provenance without a frame stack

Ginger marks `__ginger_body_*`, `__ginger_block_*`, and `__ginger_macro_*`
functions as `@noinline` and registers them in a compile-time provenance
registry. `render` catches an exception, walks the native backtrace with
`Base.StackTraces`, and builds the chain:

```text
TemplateError: MissingContextVariable: context variable `user` was not passed
  in block "content" at templates/index.html:3
  at templates/base.html:12
  rendered from app.jl:20
```

An exception with no template frame propagates unchanged, so a helper called
outside a template keeps its own exception type.

## `template_backtrace`

[`template_backtrace(err)`](@ref template_backtrace) returns the chain as a
`Vector{TemplateFrame}`, innermost first. Each frame carries:

- `kind`: `:body`, `:block`, `:macro`, or `:render`,
- `name`: the block or macro name when one applies,
- `path`: the package-relative virtual path,
- `abs_path`: the path resolved against `Config.source_root`,
- `line` and `col`.

The no-argument form returns the chain of the [`TemplateError`](@ref) currently
being handled, or an empty vector when there is none.
