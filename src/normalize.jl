"""
    normalize(parsed, syn, mod, virtual_path, cfg) -> (stmts, vars)

Turn the parsed synthetic `Expr` into normalized body statements:

1. expand `__ginger_print__` markers (with autoescaping),
2. rewrite synthetic line numbers to template line numbers,
3. infer the context variables read by the body.

Returns the statement list to splice into the generated body function and the
sorted context variable names.
"""
function normalize(parsed::Expr, syn::Synthesis, mod::Module, virtual_path::AbstractString, cfg::Config)
    expanded = MacroTools.postwalk(x -> _expand_marker(x, cfg), parsed)
    rewritten = _rewrite_lines(expanded, line_map(syn.map), String(virtual_path))
    stmts = rewritten.head === :toplevel ? rewritten.args : Any[rewritten]
    vars = context_vars(rewritten, mod)
    return (stmts = stmts, vars = vars)
end

function _expand_marker(x, cfg::Config)
    if x isa Expr && x.head === :call && length(x.args) == 2 && x.args[1] === :__ginger_print__
        return _print_call(x.args[2], cfg)
    end
    return x
end

function _print_call(value, cfg::Config)
    if cfg.autoescape
        escaped = Expr(:call, GlobalRef(Ginger, :escape), value)
        return Expr(:call, GlobalRef(Base, :print), :out, escaped)
    end
    return Expr(:call, GlobalRef(Base, :print), :out, value)
end

function _rewrite_lines(x, linemap::Vector{Int}, file::String)
    if x isa LineNumberNode
        line = x.line
        template_line = 1 <= line <= length(linemap) ? linemap[line] : line
        return LineNumberNode(template_line, Symbol(file))
    elseif x isa Expr
        return Expr(x.head, (_rewrite_lines(a, linemap, file) for a in x.args)...)
    end
    return x
end
