"""
    Config(; kwargs...)

Immutable compilation configuration for a template unit. There is no TOML file
and no mutable environment object: a `Config` is an ordinary value passed as a
macro argument.

# Keywords

- `expression_start`/`expression_end` (default `"{{"`/`"}}"`): expression delimiters.
- `statement_start`/`statement_end` (default `"{%"`/`"%}"`): statement delimiters.
- `comment_start`/`comment_end` (default `"{#"`/`"#}"`): comment delimiters.
- `trim_blocks` (default `false`): remove the first newline after a block tag.
- `lstrip_blocks` (default `false`): remove whitespace from the start of a line
  to a block tag.
- `autospace` (default `nothing`): when `true`, enables `trim_blocks` and
  `lstrip_blocks`. When `false`, disables both. Overrides the individual flags.
- `autoescape` (default `true`): HTML-escape every `{{ }}` expression.
- `source_root` (default `pwd()`): base directory used to resolve the virtual
  template paths stored in generated code.
- `undefined` (default `:strict`): missing-context-variable policy. One of
  `:strict` (throw), `:lenient` (bind `Undefined`), `:default` (bind `Undefined`
  and make the `default(value, fallback)` helper useful).
"""
struct Config
    expression_start::String
    expression_end::String
    statement_start::String
    statement_end::String
    comment_start::String
    comment_end::String
    trim_blocks::Bool
    lstrip_blocks::Bool
    autoescape::Bool
    source_root::String
    undefined::Symbol

    function Config(;
            expression_start::AbstractString = "{{",
            expression_end::AbstractString = "}}",
            statement_start::AbstractString = "{%",
            statement_end::AbstractString = "%}",
            comment_start::AbstractString = "{#",
            comment_end::AbstractString = "#}",
            trim_blocks::Bool = false,
            lstrip_blocks::Bool = false,
            autospace::Union{Nothing, Bool} = nothing,
            autoescape::Bool = true,
            source_root::AbstractString = pwd(),
            undefined::Symbol = :strict,
        )
        if autospace === true
            trim_blocks = true
            lstrip_blocks = true
        elseif autospace === false
            trim_blocks = false
            lstrip_blocks = false
        end
        if undefined ∉ (:strict, :lenient, :default)
            throw(
                ArgumentError(
                    "`undefined` must be :strict, :lenient or :default, got :$undefined",
                )
            )
        end
        return new(
            String(expression_start),
            String(expression_end),
            String(statement_start),
            String(statement_end),
            String(comment_start),
            String(comment_end),
            trim_blocks,
            lstrip_blocks,
            autoescape,
            String(source_root),
            undefined,
        )
    end
end
