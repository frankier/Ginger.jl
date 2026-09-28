const _COMPOUND_ASSIGN_OPS = Set{Symbol}(
    [
        :+=, :-=, :*=, :/=, ://=, :\=, :^=, :%=, :&=, :|=, :$=, :<<=, :>>=, :>>>=, :⊻=,
    ]
)

const _RESERVED_BINDINGS = Set{Symbol}([:out, :ctx])

"""
    context_vars(body, mod) -> Vector{Symbol}

Infer the template's context by free-variable analysis. A name is a context
variable when it is neither bound locally in `body` nor resolvable in the host
module `mod` (checked with `isdefined`). The result is sorted for deterministic
generated code.
"""
function context_vars(body, mod::Module)
    assigned = Set{Symbol}()
    _assigned!(assigned, body)
    bound = union(assigned, _RESERVED_BINDINGS)
    free = Set{Symbol}()
    _free!(free, body, bound)
    filter!(name -> !isdefined(mod, name), free)
    return sort!(collect(free))
end

# --- names assigned in the current scope -----------------------------------

function _assigned!(out::Set{Symbol}, e)
    e isa Expr || return nothing
    head = e.head
    if head === :(=) || head in _COMPOUND_ASSIGN_OPS
        _assigned_lhs!(out, e.args[1])
    elseif head === :function
        _function_name!(out, e.args[1])
    elseif head === :(->) || head === :quote || head === :let
        return nothing
    elseif head === :for
        for a in e.args[2:end]
            _assigned!(out, a)
        end
    elseif head === :comprehension || head === :generator || head === :filter
        return nothing
    elseif head === :macrocall
        return nothing
    else
        for a in e.args
            _assigned!(out, a)
        end
    end
    return nothing
end

function _assigned_lhs!(out::Set{Symbol}, lhs)
    if lhs isa Symbol
        push!(out, lhs)
    elseif lhs isa Expr
        if lhs.head === :call
            name = lhs.args[1]
            name isa Symbol && push!(out, name)
        elseif lhs.head === :tuple
            for a in lhs.args
                _assigned_lhs!(out, a)
            end
        elseif lhs.head === :...
            _assigned_lhs!(out, lhs.args[1])
        elseif lhs.head === :(::)
            _assigned_lhs!(out, lhs.args[1])
        end
    end
    return nothing
end

function _function_name!(out::Set{Symbol}, sig)
    if sig isa Symbol
        push!(out, sig)
    elseif sig isa Expr
        if sig.head === :call
            name = sig.args[1]
            name isa Symbol && push!(out, name)
        elseif sig.head === :where || sig.head === :(::)
            _function_name!(out, sig.args[1])
        end
    end
    return nothing
end

# --- names used free in the current scope ----------------------------------

function _free!(out::Set{Symbol}, e, bound::Set{Symbol})
    if e isa Symbol
        e in bound || push!(out, e)
        return nothing
    end
    e isa Expr || return nothing
    head = e.head
    if head === :quote
        return nothing
    elseif head === :(=)
        lhs = e.args[1]
        if lhs isa Expr && lhs.head === :call
            inner = union(bound, _params(lhs.args[2:end]), _immediate_assigned(e.args[2]))
            for a in lhs.args[2:end]
                _free_param!(out, a, inner)
            end
            _free!(out, e.args[2], inner)
        else
            _free_lhs!(out, lhs, bound)
            _free!(out, e.args[2], bound)
        end
    elseif head in _COMPOUND_ASSIGN_OPS
        _free_lhs!(out, e.args[1], bound)
        _free!(out, e.args[2], bound)
    elseif head === :(->)
        body = e.args[2]
        inner = union(bound, _params((e.args[1],)), _immediate_assigned(body))
        _free_param!(out, e.args[1], inner)
        _free!(out, body, inner)
    elseif head === :function
        body = length(e.args) >= 2 ? e.args[2] : nothing
        inner = union(bound, _signature_params(e.args[1]), body === nothing ? Set{Symbol}() : _immediate_assigned(body))
        _free!(out, e.args[1], inner)
        body === nothing || _free!(out, body, inner)
    elseif head === :let
        _free_let!(out, e, bound)
    elseif head === :for
        _free_for!(out, e, bound)
    elseif head === :comprehension
        for a in e.args
            _free!(out, a, bound)
        end
    elseif head === :generator || head === :filter
        binders = Set{Symbol}()
        _generator_binders!(binders, e)
        inner = union(bound, binders)
        for a in e.args
            _free!(out, a, inner)
        end
    elseif head === :macrocall
        for a in e.args[3:end]
            _free!(out, a, bound)
        end
    else
        for a in e.args
            _free!(out, a, bound)
        end
    end
    return nothing
end

function _free_lhs!(out::Set{Symbol}, lhs, bound::Set{Symbol})
    if lhs isa Expr
        if lhs.head === :tuple
            for a in lhs.args
                _free_lhs!(out, a, bound)
            end
        elseif lhs.head === :...
            _free_lhs!(out, lhs.args[1], bound)
        elseif lhs.head === :(::)
            _free!(out, lhs.args[2], bound)
            _free_lhs!(out, lhs.args[1], bound)
        elseif lhs.head === :ref
            for a in lhs.args
                _free!(out, a, bound)
            end
        elseif lhs.head === :.
            _free!(out, lhs.args[1], bound)
        end
    end
    return nothing
end

function _free_let!(out::Set{Symbol}, e, bound::Set{Symbol})
    inner = copy(bound)
    for (lhs, value) in _binding_pairs(e.args[1])
        _free!(out, value, inner)
        _assigned_lhs!(inner, lhs)
    end
    body = e.args[2]
    union!(inner, _immediate_assigned(body))
    _free!(out, body, inner)
    return nothing
end

function _free_for!(out::Set{Symbol}, e, bound::Set{Symbol})
    inner = copy(bound)
    for (lhs, iter) in _binding_pairs(e.args[1])
        _free!(out, iter, inner)
        _assigned_lhs!(inner, lhs)
    end
    body = e.args[2:end]
    for a in body
        union!(inner, _immediate_assigned(a))
    end
    for a in body
        _free!(out, a, inner)
    end
    return nothing
end

# Bindings in a `let` header or a `for` iteration spec.
function _binding_pairs(spec)
    pairs = Tuple{Any, Any}[]
    if spec isa Expr
        if spec.head === :(=)
            push!(pairs, (spec.args[1], spec.args[2]))
        elseif spec.head === :block
            for a in spec.args
                if a isa Expr && a.head === :(=)
                    push!(pairs, (a.args[1], a.args[2]))
                end
            end
        end
    end
    return pairs
end

function _generator_binders!(out::Set{Symbol}, e)
    if e isa Expr
        if e.head === :generator || e.head === :filter || e.head === :comprehension
            for a in e.args
                _generator_binders!(out, a)
            end
        elseif e.head === :(=)
            _assigned_lhs!(out, e.args[1])
        end
    end
    return nothing
end

function _immediate_assigned(body)
    out = Set{Symbol}()
    _assigned!(out, body)
    return out
end

# --- parameters -------------------------------------------------------------

function _params(params)
    out = Set{Symbol}()
    for p in params
        _param_names!(out, p)
    end
    return out
end

function _signature_params(sig)
    out = Set{Symbol}()
    if sig isa Symbol
        push!(out, sig)
    elseif sig isa Expr
        if sig.head === :call
            for a in sig.args[2:end]
                _param_names!(out, a)
            end
        elseif sig.head === :where || sig.head === :(::)
            union!(out, _signature_params(sig.args[1]))
        elseif sig.head === :tuple
            for a in sig.args
                _param_names!(out, a)
            end
        end
    end
    return out
end

function _param_names!(out::Set{Symbol}, p)
    if p isa Symbol
        push!(out, p)
    elseif p isa Expr
        if p.head === :tuple
            for a in p.args
                _param_names!(out, a)
            end
        elseif p.head === :kw || p.head === :(=) || p.head === :(::) || p.head === :...
            _param_names!(out, p.args[1])
        elseif p.head === :parameters || p.head === :macrocall
            for a in p.args
                a isa LineNumberNode || _param_names!(out, a)
            end
        end
    end
    return nothing
end

function _free_param!(out::Set{Symbol}, p, bound::Set{Symbol})
    p isa Expr || return nothing
    if p.head === :kw
        _free!(out, p.args[2], bound)
    elseif p.head === :(::)
        _free!(out, p.args[2], bound)
        _free_param!(out, p.args[1], bound)
    elseif p.head === :tuple
        for a in p.args
            _free_param!(out, a, bound)
        end
    elseif p.head === :...
        _free_param!(out, p.args[1], bound)
    end
    return nothing
end
