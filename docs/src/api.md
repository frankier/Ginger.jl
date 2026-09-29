# API reference

Ginger's public API is frozen at 1.0. Anything named `__ginger_*` is internal and
may change without notice, as are the fields and constructors of the types listed
here unless a docstring says otherwise.

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
