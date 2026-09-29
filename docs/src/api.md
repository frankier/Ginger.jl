# API reference

This page lists the public API. Anything named `__ginger_*` is internal and may
change without notice. The same applies to the fields and constructors of the
types listed here unless a docstring says otherwise.

## Macros

```@docs
@template
@templates
@ginger_str
```

## Rendering

```@docs
render
render!
Template
```

## Configuration

```@docs
Config
```

## Escaping

```@docs
HTMLString
escape
safe
default
```

## Errors

```@docs
TemplateSyntaxError
TemplateError
TemplateFrame
MissingContextVariable
template_backtrace
```

## Helpers

```@autodocs
Modules = [Ginger.DefaultHelpers]
```
