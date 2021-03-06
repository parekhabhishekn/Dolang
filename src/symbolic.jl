# ----- #
# types #
# ----- #

immutable NormalizeError <: Exception
    ex::Expr
    msg::String
end

immutable UnknownFunctionError <: Exception
    func_name::Symbol
    msg::String
end

# --------- #
# normalize #
# --------- #

"""
```julia
normalize(var::Union{String,Symbol}, n::Integer)
```

Normalize the string or symbol in the following way:

- if `n == 0` return `_var_`
- if `n > 0` return `_var__n_`
- if `n < 0` return `_var_mn_`

"""
function normalize(var::Union{String,Symbol}, n::Integer)
    n == 0 && return normalize(var)
    Symbol(string("_", var, "_", n > 0 ? "_" : "m", abs(n)), "_")
end

"""
```julia
normalize(x::Tuple{Symbol,Integer})
```

Same as `normalize(x[1], x[2])`
"""
normalize{T<:Integer}(x::Tuple{Symbol,T}) = normalize(x[1], x[2])

"""
```julia
normalize(x::Symbol)
```

Normalize the symbol by returning `_x_`
"""
normalize(x::Symbol) = Symbol(string("_", x, "_"))

"""
```julia
normalize(x::Number)
```

Just return `x`
"""
normalize(x::Number) = x

"""
```julia
normalize(ex::Expr; targets::Union{Vector{Expr},Vector{Symbol}}=Symbol[])
```

Recursively normalize `ex` according to the following rules (structure of list
below is `input form of ex: returned expression`):

- `lhs = rhs` and `targets` is not empty: `normalize(lhs) = normalize(rhs)`,
  where `lhs` must be one of the symbols in `targets`
- `quote ex end`:  `normalize(ex)`
- `var(n::Integer)`: `normalize(var, n)`
- `a ⚡ b` and `⚡` one of `+`, `*`, `-`, `/`, `^`, `+`, `*`:
  `normalize(a) ⚡ normalize(b)`
- `f(args...)`: `f(map(normalize, args)...)`
"""
function normalize(ex::Expr; targets::Union{Vector{Expr},Vector{Symbol}}=Symbol[])
    if ex.head == :(=)
        return eq_expr(ex, targets)
    end

    if ex.head == :block
        if length(ex.args) == 2 && isa(ex.args[1], LineNumberNode)
            return normalize(ex.args[2])
        end

        # often we have an Expr simliar to the above, except that we have filtered
        # out the line nodes. We end up with a block with one arg.
        # This is that case.
        if length(ex.args) == 1
            return normalize(ex.args[1])
        end
    end

    if ex.head == :call
        # translate x(n) --> x__n_ and x(-n) -> x_mn_
        if length(ex.args) == 2 && isa(ex.args[2], Integer)
            return normalize(ex.args[1], ex.args[2])
        end

        # TODO: SymEngine will also choke with things like
        # :(100_E_LYGAP_ - _outputgap_). Here Julia knows `100_E_LYGAP_` is
        # `100 * _E_LYGAP_`, but symengine treats that whole thing as a
        # single symbol. My current solution is to just swap the order of the
        # `*`
        if ex.args[1] == :(*) && length(ex.args) == 3 && isa(ex.args[2], Number)
            return Expr(:call, :(*), normalize(ex.args[3]), ex.args[2])
        end

        if ex.args[1] in (:+, :*)
            return call_plus_times_expr(ex)
        end

        # otherwise it is just some random function call
        return Expr(:call, ex.args[1], map(normalize, ex.args[2:end])...)
    end

    throw(NormalizeError(ex, "Not sure what I just saw"))
end

"""
```julia
normalize(s::AbstractString; kwargs...)
```

Call `normalize(parse(s)::Expr; kwargs...)`
"""
normalize(s::String; kwargs...) = normalize(parse(s); kwargs...)

"""
```julia
normalize(exs::Vector{Expr}; kwargs...)
```

Construct a `begin`/`end` block formed by calling `normalize(_; kwargs...)` for
all `_` in `exs`
"""
normalize(exs::Vector{Expr}; kwargs...) =
    Expr(:block, map(_ -> normalize(_; kwargs...), exs)...)

# ---------- #
# time_shift #
# ---------- #

# NOTE: I do implementation with positional arguments only to make it easier
#       to call recursively. I define the public interface (kwarg version)
#       below

# TODO: make `time_shift(x, shift; args, shfit, defs) = time_shift(subs(x, defs), args, shift)`

"""
```julia
time_shift(s::Symbol, shift::Integer,
           variables::Set{Symbol}=Set{Symbol}(),
           functions::Set{Symbol}=Set{Symbol}(),
           defs::Associative=Dict())
```

If `s` is in `variables`, then return the expression `s(shift)`

If `s` is in `defs`, then return the shifted version of the definition

Otherwise return `s`
"""
function time_shift(s::Symbol, shift::Integer,
                    variables::Set{Symbol},
                    functions::Set{Symbol},
                    defs::Associative)

    # if `s` is a function arg then return shifted version of s
    if s in variables
        return :($s($(shift)))
    end

    # if it is a def, recursively substitute it
    if haskey(defs, s)
        return time_shift(defs[s], shift, variables, functions, defs)
    end

    # any other symbols just gets parsed
    return s
end

"""
```julia
time_shift(x::Number, other...)
```

Return `x` for all values of `other`
"""
time_shift(x::Number, other...) = x

"""
```julia
time_shift(ex::Expr, shift::Integer,
           variables::Set{Symbol}=Set{Symbol}(),
           functions::Set{Symbol}=Set{Symbol}(),
           defs::Associative=Dict())
```

Recursively apply a `time_shift` to `ex` according to the following rules based
on the form of `ex` (list below has the form "contents of ex: return expr"):

- `var(n::Integer)`: `time_shift(var, args, shift + n, defs)`
- `f(other...)`: if `f` is in `functions` or is a known dolang funciton (see
  `Dolang.DOLANG_FUNCTIONS`) return
  `f(map(_ -> time_shift(_, args, shift, defs), other))`, otherwise error
- Any other `Expr`: `Expr(ex.head, map(_ -> time_shift(_, args, shift, defs), ex.args))`
"""
function time_shift(ex::Expr, shift::Integer,
                    variables::Set{Symbol},
                    functions::Set{Symbol},
                    defs::Associative)

    # need to pattern match here to make sure we don't normalize function names
    if is_time_shift(ex)
        var = ex.args[1]
        i = ex.args[2]

        # if we found a definition, move to resolving it
        if haskey(defs, var)
            time_shift(defs[var], shift+i, variables, functions, defs)
        end

        # variables = Symbol[variables; var]
        return time_shift(var, shift+i, variables, functions, defs)
    end

    # if it is some kind of function call, shift arguments
    if ex.head == :call
        func = ex.args[1]
        if func in DOLANG_FUNCTIONS || func in functions
            out = Expr(:call, func)
            for arg in ex.args[2:end]
                push!(out.args, time_shift(arg, shift, variables, functions, defs))
            end
            return out
        else
            throw(UnknownFunctionError(func, "Unknown function $func"))
        end
    end

    # otherwise just shift all args, but retain expr head
    out = Expr(ex.head)
    out.args = [time_shift(_, shift, variables, defs) for _ in ex.args]
    return out
end

"""
```julia
time_shift(ex::Expr, shift::Int=0;
           variables::Union{Set{Symbol},Vector{Symbol}}=Vector{Symbol}(),
           functions::Union{Set{Symbol},Vector{Symbol}}=Vector{Symbol}(),
           defs::Associative=Dict())
```

Version of `time_shift` where `variables`, `functions`, and `defs` are keyword
arguments with default values.
"""
function time_shift(ex::Expr, shift::Integer=0;
                    variables::Union{Set{Symbol},Vector{Symbol}}=Set{Symbol}(),
                    functions::Union{Set{Symbol},Vector{Symbol}}=Set{Symbol}(),
                    defs::Associative=Dict())
    time_shift(ex, shift, Set(variables), Set(functions), defs)
end

# ------------ #
# steady state #
# ------------ #

"""
```julia
steady_state(s, functions::Set{Symbol}, defs::Associative)
```

Return the steady state version of the Symbol `x` (essentially x(0))
"""
function steady_state(s, functions::Set{Symbol}, defs::Associative)

    if haskey(defs, s)
        steady_state(defs[s], functions, defs)
    else
        s
    end
end

"""
```julia
steady_state(ex::Expr, functions::Set{Symbol}, defs::Associative)
```

Return the steady state version of `ex`, where all symbols in `args`
always appear at time 0
"""
function steady_state(ex::Expr, functions::Set{Symbol}, defs::Associative)
    if is_time_shift(ex)
        return ex.args[1]
    end

    # if it is some kind of function call, steady_state arguments
    if ex.head == :call
        func = ex.args[1]
        if func in DOLANG_FUNCTIONS || func in functions
            out = Expr(:call, func)
            for arg in ex.args[2:end]
                push!(out.args, steady_state(arg, functions, defs))
            end
            return out
        else
            throw(UnknownFunctionError(func, "Unknown function $func"))
        end
    end

     # otherwise just steady_state all args, but retain expr head
    out = Expr(ex.head)
    out.args = [steady_state(_, functions, defs) for _ in ex.args]
    return out
end

"""
```julia
steady_state(ex::Expr;
             functions::Vector{Symbol}=Vector{Symbol}(),
             defs::Associative=Dict())
```

Version of `steady_state` where `functions` and `defs` are keyword arguments
with default values
"""
function steady_state(ex::Expr;
                      functions::Union{Set{Symbol},Vector{Symbol}}=Set{Symbol}(),
                      defs::Associative=Dict())
    steady_state(ex, Set(functions), defs)
end

# ------------ #
# list_symbols #
# ------------ #

function list_symbols(ex::Expr;
                      functions::Union{Set{Symbol},Vector{Symbol}}=Set{Symbol}(),
                      variables::Union{Set{Symbol},Vector{Symbol}}=Set{Symbol}())
    out = Dict{Symbol,Any}()
    list_symbols!(out, ex, Set(functions), Set(variables))
end

"""
```julia
list_symbols!(out, s::Symbol, functions::Set{Symbol}, variables::Set{Symbol})
```

If `s` is in `variables`, add `(s, 0)` to `out[:variables]`. Otherwise, add
`s` to `out[:parameters]``
"""
function list_symbols!(out, s::Symbol, functions::Set{Symbol},
                       variables::Set{Symbol})
    if s in variables
        current = get!(out, :variables, Set{Tuple{Symbol,Int}}())
        push!(current, (s, 0))
    else
        current = get!(out, :parameters, Set{Symbol}())
        push!(current, s)
    end

    out
end


"""
```julia
list_symbols!(out, s::Any, functions::Set{Symbol}, variables::Set{Symbol})
```

Do nothing -- if s is not a `Symbol` or `Expr` (handled in separate methods)
do not add anything to symbol list.
"""
function list_symbols!(out, ex::Any, functions::Set{Symbol},
                       variables::Set{Symbol})
    nothing
end

"""
```julia
list_symbols!(out, s::Expr, functions::Set{Symbol}, variables::Set{Symbol})
```

Walk the expression and populate `out` according to the following rules for
each type of subexpression encoutered:

- `s::Symbol`: if `s` is in `variables`, add `(s, 0)` to `out[:variables]`,
otherwise add `s` to `out[:parameters]`
- `x(i::Integer)`: Add `(x, i)` out `out[:parameters]``
- All other function calls: add any arguments to `out` according to above rules
- Anything else: do nothing.
"""
function list_symbols!(out, ex::Expr, functions::Set{Symbol},
                       variables::Set{Symbol})
    # here we just need to walk the expression tree and pull out symbols
    if is_time_shift(ex)
        var = ex.args[1]
        shift = ex.args[2]
        current = get!(out, :variables, Set{Tuple{Symbol,Int}}())
        push!(current, (var, shift))
        return out
    end

    # if it is some kind of function call, steady_state arguments
    if ex.head == :call
        func = ex.args[1]
        if func in DOLANG_FUNCTIONS || func in functions
            for arg in ex.args[2:end]
                list_symbols!(out, arg, functions, variables)
            end
            return out
        else
            throw(UnknownFunctionError(func, "Unknown function $func"))
        end
    end

end

# TODO: potential name change. match_recipe?
# function list_symbols(::Expr, recipe::Associative) => Dict(keys=keys(recipe), values=incidence)
# end

# -------------- #
# list_variables #
# -------------- #

# function list_variables(ex::Expr;
#                       functions::Union{Set{Symbol},Vector{Symbol}}=Set{Symbol}(),
#                       variables::Union{Set{Symbol},Vector{Symbol}}=Set{Symbol}())
#     syms = list_symbols(ex; functions=functions, variables=variables)
#     out = Set{Symbol}()
#     for (k, v) in syms
#         for _ in v
#             isa(_, Symbol) ? push!(out, _) :
#             isa(_, Tuple{Symbol,Int}) ? push!(out, _[1]):
#             error("not sure what happened here")
#         end
#     end
#     out
# end

# ---- #
# subs #
# ---- #

#=
_subs will always return a tuple `(new_item, did_change)`, where `new_item`
is the result of trying to do the sub and `did_change` is a bool specifying
whether or not any substitutions happened. This is used to know when to break
out of a recursion.
=#
function _subs(s::Symbol, d::Associative, a...)
    haskey(d, s) && return (d[s], true)

    # also check for canonical form (s, 0)
    haskey(d, (s, 0)) && return (d[(s, 0)], true)

    (s, false)
end

_subs(x::Number, d::Associative, a...) = (x, false)

function _subs(ex::Expr, d::Associative,
               variables::Set{Symbol},
               funcs::Set{Symbol})
    if is_time_shift(ex)
        var = ex.args[1]
        shift = ex.args[2]
        if haskey(d, (var, shift))
            new_ex = d[(var, shift)]
            return new_ex, true
        end

        # d doesn't have a key in canonical form, so just return here
        return ex, false
    end

    out_args = Array(Any, length(ex.args))
    changed = false

    for (i, arg) in enumerate(ex.args)
        new_arg, arg_changed = _subs(arg, d, variables, funcs)
        out_args[i] = new_arg
        changed = changed || arg_changed
    end

    out = Expr(ex.head)
    out.args = out_args
    out, changed
end

"""
```julia
subs(ex::Union{Expr,Symbol,Number}, from, to::Union{Symbol,Expr,Number})
```

Apply a substituion where all occurances of `from` in `ex` are replaced by `to`.

Note that to replace something like `x(1)` `from` must be the canonical form
for that expression: `(:x, 1)`
"""
function subs(ex::Union{Expr,Symbol,Number}, from,
              to::Union{Symbol,Expr,Number},
              variables::Set{Symbol},
              funcs::Set{Symbol})
    _subs(ex, Dict(from=>to), variables, funcs)[1]
end

"""
```julia
subs(ex::Union{Expr,Symbol,Number}, d::Associative,
     variables::Set{Symbol},
     funcs::Set{Symbol})
```

Apply substituions to `ex` so that all keys in `d` are replaced by their values

Note that the keys of `d` should be the canonical form of variables you wish to
substitute. For example, to replace `x(1)` with `b/c` you need to have the
entry `(:x, 1) => :(b/c)` in `d`.

The one exception to this rule is that a key `:k` is treated the same as `(:k,
0)`.
"""
function subs(ex::Union{Expr,Symbol,Number}, d::Associative,
              variables::Set{Symbol},
              funcs::Set{Symbol})
    _subs(ex, d, variables, funcs)[1]
end

"""
```julia
subs(ex::Union{Expr,Symbol,Number}, d::Associative;
     variables::Set{Symbol},
     functions::Set{Symbol})
```

Verison of `subs` where `variables` and `functions` are keyword arguments with
default values
"""
function subs(ex::Union{Expr,Symbol,Number}, d::Associative;
              variables::Union{Vector{Symbol},Set{Symbol}}=Set{Symbol}(),
              functions::Union{Vector{Symbol},Set{Symbol}}=Set{Symbol}())
    subs(ex, d, Set(variables), Set(functions))
end

"""
```julia
csubs(x::Union{Symbol,Number}, d::Associative)
```

If `x` is a key in `d`, return the assocaited value. Otherwise return `x`
"""
function csubs(x::Union{Symbol,Number}, d::Associative,
               variables::Set{Symbol},
               funcs::Set{Symbol})
    _subs(x, d, variables, funcs)[1]
end

"""
```julia
csubs(ex::Expr, d::Associative,
      variables::Set{Symbol}=Set{Symbol}(),
      funcs::Set{Symbol}=Set{Symbol}())
```

Recursively apply substitutions to `ex` such that all items that are a key
in `d` are replaced by their associated values. Different from `subs(x, d)`
in that definitions in `d` are allowed to depend on one another and will
all be fully resolved here.

## Example

```
ex = :(a + b)
d = Dict(:b => :(c/a), :c => :(2a))
subs(ex, d)  # returns :(a + c / a)
csubs(ex, d)  # returns :(a + (2a) / a)
```
"""
function csubs(ex::Expr, d::Associative,
               variables::Set{Symbol},
               funcs::Set{Symbol})
    max_it = length(d) + 1
    max_it == 1 && return ex

    for i in 1:max_it
        ex, changed = _subs(ex, d, variables, funcs)
        !changed && return ex
    end

    error("Could not resolve expression recursively.")
end

"""
```julia
csubs(ex::Union{Symbol,Expr,Number}, d::Associative;
      variables::Union{Vector{Symbol},Set{Symbol}}=Set{Symbol}(),
      functions::Union{Vector{Symbol},Set{Symbol}}=Set{Symbol}())
```

Verison of `csubs` where `variables` and `functions` are keyword arguments.
"""
function csubs(ex::Union{Symbol,Expr,Number}, d::Associative;
               variables::Union{Vector{Symbol},Set{Symbol}}=Set{Symbol}(),
               functions::Union{Vector{Symbol},Set{Symbol}}=Set{Symbol}())
    csubs(ex, d, Set(variables), Set(functions))
end

# --------- #
# Utilities #
# --------- #

"""
```julia
is_time_shift(ex::Expr)
```

Determine if the expression has the form `var(n::Integer)`.
"""
is_time_shift(ex::Expr) = ex.head == :call &&
                          length(ex.args) == 2 &&
                          isa(ex.args[2], Integer)


function call_plus_times_expr(ex::Expr)
    fun = ex.args[1]
    if length(ex.args) == 3
        return Expr(:call, fun, normalize(ex.args[2]), normalize(ex.args[3]))
    else
        call_plus_times_expr(Expr(:call, ex.args[1],
                                  Expr(:call, fun, ex.args[2], ex.args[3]),
                                  ex.args[4:end]...))
    end
end


function eq_expr(ex::Expr, targets::Union{Vector{Expr},Vector{Symbol}}=Symbol[])
    # translate lhs = rhs to rhs - lhs
    if isempty(targets)
      return Expr(:call, :(-), normalize(ex.args[2]), normalize(ex.args[1]))
    end

    # ensure lhs is in targets
    if !(ex.args[1] in targets)
      msg = string("Expected expression of the form `lhs = rhs` ",
                   "where `lhs` is one of $(targets)")
      throw(NormalizeError(ex, msg))
    end

    Expr(:(=), normalize(ex.args[1]), normalize(ex.args[2]))

end
