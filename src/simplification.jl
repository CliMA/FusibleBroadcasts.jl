# The methods in this section can be extended to scalar and function/operator
# types defined in other packages.

is_scalar_value(_) = false
is_scalar_value(::Number) = true

is_self_inverse(_) = false
is_self_inverse(::typeof(-)) = true
is_self_inverse(::Union{typeof(adjoint), typeof(transpose)}) = true

is_linear(_) = false
is_linear(::Union{typeof(adjoint), typeof(transpose)}) = true
is_linear(::Operators.SpectralElementOperator) = true
is_linear(f::MatrixFields.OneArgFDOperator) = !MatrixFields.has_affine_bc(f)
# TODO: Add support for linear functions with more than one argument. This will
# involve being able to specify which argument(s) a function is linear in.

################################################################################

is_bc_with_f(value, f) = value isa FusibleBroadcasted && value.f == f

is_negated_bc(value) = is_bc_with_f(value, -) && length(value.args) == 1

linear_functions_in_linear_combination(value) =
    if !(value isa FusibleBroadcasted)
        ()
    elseif is_linear(value.f)
        (value.f,)
    elseif value.f in (+, -)
        Iterators.flatmap(linear_functions_in_linear_combination, value.args)
    elseif value.f == (*) && count(!is_scalar_value, value.args) == 1
        non_scalar_arg = filter(!is_scalar_value, value.args)[1]
        linear_functions_in_linear_combination(non_scalar_arg)
    elseif value.f == (/) && is_scalar_value(value.args[2])
        linear_functions_in_linear_combination(value.args[1])
    else
        ()
    end

linear_function_coefficients_and_args(value, linear_f) =
    if !(value isa FusibleBroadcasted)
        ()
    elseif value.f == linear_f
        ((1, value.args[1]),)
    elseif value.f == (+)
        Iterators.flatmap(value.args) do arg
            linear_function_coefficients_and_args(arg, linear_f)
        end
    elseif is_negated_bc(value)
        pairs = linear_function_coefficients_and_args(value.args[1], linear_f)
        map(((coef, arg),) -> (-coef, arg), pairs)
    elseif value.f == (-)
        pairs1 = linear_function_coefficients_and_args(value.args[1], linear_f)
        pairs2 = linear_function_coefficients_and_args(value.args[2], linear_f)
        (pairs1..., map(((coef, arg),) -> (-coef, arg), pairs2)...)
    elseif value.f == (*) && count(!is_scalar_value, value.args) == 1
        non_scalar_arg = filter(!is_scalar_value, value.args)[1]
        pairs = linear_function_coefficients_and_args(non_scalar_arg, linear_f)
        scalar_args_product = prod(filter(is_scalar_value, value.args))
        map(((coef, arg),) -> (scalar_args_product * coef, arg), pairs)
    elseif value.f == (/) && is_scalar_value(value.args[2])
        pairs = linear_function_coefficients_and_args(value.args[1], linear_f)
        map(((coef, arg),) -> (coef / value.args[2], arg), pairs)
    else
        ()
    end

drop_linear_functions_from_combination(value, linear_fs) =
    if !(value isa FusibleBroadcasted)
        value
    elseif value.f in linear_fs
        DroppedBroadcast()
    elseif value.f == (+)
        args = map(value.args) do arg
            drop_linear_functions_from_combination(arg, linear_fs)
        end
        all(was_dropped, args) ? DroppedBroadcast() :
        FusibleBroadcasted(value.f, filter(!was_dropped, args))
    elseif is_negated_bc(value)
        arg = drop_linear_functions_from_combination(value.args[1], linear_fs)
        was_dropped(arg) ? DroppedBroadcast() :
        FusibleBroadcasted(value.f, (arg,))
    elseif value.f == (-)
        arg1 = drop_linear_functions_from_combination(value.args[1], linear_fs)
        arg2 = drop_linear_functions_from_combination(value.args[2], linear_fs)
        if was_dropped(arg1) && was_dropped(arg2)
            DroppedBroadcast()
        elseif was_dropped(arg2)
            arg1
        elseif was_dropped(arg1)
            FusibleBroadcasted(value.f, (arg2,))
        else
            FusibleBroadcasted(value.f, (arg1, arg2))
        end
    elseif value.f == (*) && count(!is_scalar_value, value.args) == 1
        non_scalar_arg = filter(!is_scalar_value, value.args)[1]
        arg = drop_linear_functions_from_combination(non_scalar_arg, linear_fs)
        scalar_args_product = prod(filter(is_scalar_value, value.args))
        was_dropped(arg) ? DroppedBroadcast() :
        FusibleBroadcasted(value.f, (scalar_args_product, arg))
    elseif value.f == (/) && is_scalar_value(value.args[2])
        arg = drop_linear_functions_from_combination(value.args[1], linear_fs)
        was_dropped(arg) ? DroppedBroadcast() :
        FusibleBroadcasted(value.f, (arg, value.args[2]))
    else
        value
    end

# Note: In this function, FusibleBroadcasted is used instead of fused_bc when no
# additional fusion can be performed.
# TODO: Simplify what's going on here.
function fused_bc(f, args)
    # +(a) -> a and *(a) -> a
    f in (+, *) && length(args) == 1 && return args[1]

    # a + (-b) -> a - b
    if f == (+) && any(is_negated_bc, args)
        unnegated_bcs = map(bc -> bc.args[1], filter(is_negated_bc, args))
        other_args = filter(!is_negated_bc, args)
        return if isempty(other_args)
            FusibleBroadcasted(-, fused_bc(f, unnegated_bcs))
        elseif length(other_args) == 1 && length(unnegated_bcs) == 1
            fused_bc(-, (other_args[1], unnegated_bcs[1]))
        elseif length(other_args) == 1 && length(unnegated_bcs) > 1
            fused_bc(-, (other_args[1], fused_bc(f, unnegated_bcs)))
        elseif length(other_args) > 1 && length(unnegated_bcs) == 1
            fused_bc(-, (fused_bc(f, other_args), unnegated_bcs[1]))
        else
            fused_bc(-, (fused_bc(f, other_args), fused_bc(f, unnegated_bcs)))
        end
    end

    is_nested_f = any(arg -> is_bc_with_f(arg, f), args)

    # -(-a) -> a, adjoint(adjoint(a)) -> a, etc.
    (is_nested_f && is_self_inverse(f)) &&
        (length(args) == 1 && length(args[1].args) == 1) &&
        return args[1].args[1]

    if is_nested_f && f in (+, *)
        # (a + b...) + c... -> a + b... + c... and
        # (a * b...) * c... -> a * b... * c...
        args = Tuple(Iterators.flatmap(args) do arg
            is_bc_with_f(arg, f) ? arg.args : (arg,)
        end)
    end

    if is_nested_f && f in (-, /) && length(args) == 2
        # a - (-b) -> a + b,
        # a - (b - c) -> (a + c) - b,
        # a / (b / c) -> (a * c) / b,
        # (-a) - b -> -(a + b),
        # (a - b) - c -> a - (b + c),
        # (a / b) / c -> a / (b * c),
        # (-a) - (-b) -> b - a,
        # (-a) - (b - c) -> c - (a + b),
        # (a - b) - (-c) -> (a + c) - b,
        # (a - b) - (c - d) -> (a + d) - (b + c), and
        # (a / b) / (c / d) -> (a * d) / (b * c)
        inv_f = f == (-) ? (+) : * # Add parentheses to avoid ParseError
        args = if !is_bc_with_f(args[1], f)
            if is_negated_bc(args[2])
                f = inv_f
                (args[1], args[2].args[1])
            else
                inv_f_args = (args[1], args[2].args[2])
                (fused_bc(inv_f, inv_f_args), args[2].args[1])
            end
        elseif !is_bc_with_f(args[2], f)
            if is_negated_bc(args[1])
                inv_f_args = (args[1].args[1], args[2])
                (fused_bc(inv_f, inv_f_args),)
            else
                inv_f_args = (args[1].args[2], args[2])
                (args[1].args[1], fused_bc(inv_f, inv_f_args))
            end
        else
            if is_negated_bc(args[1]) && is_negated_bc(args[2])
                (args[2].args[1], args[1].args[1])
            elseif is_negated_bc(args[1])
                inv_f_args = (args[1].args[1], args[2].args[1])
                (args[2].args[2], fused_bc(inv_f, inv_f_args))
            elseif is_negated_bc(args[2])
                inv_f_args = (args[1].args[1], args[2].args[1])
                (fused_bc(inv_f, inv_f_args), args[1].args[2])
            else
                inv_f_args1 = (args[1].args[1], args[2].args[2])
                inv_f_args2 = (args[1].args[2], args[2].args[1])
                (fused_bc(inv_f, inv_f_args1), fused_bc(inv_f, inv_f_args2))
            end
        end
    end

    if f in (*, /) && any(is_negated_bc, args)
        # (-a) * b... -> -(a * b...),
        # (-a) / b -> -(a / b), and
        # a / (-b) -> -(a / b)
        new_args = map(arg -> is_negated_bc(arg) ? arg.args[1] : arg, args)
        if count(is_negated_bc, args) % 2 == 0
            return FusibleBroadcasted(f, new_args)
        else
            return FusibleBroadcasted(-, (FusibleBroadcasted(f, new_args),))
        end
    elseif f in (+, -)
        # L(a) + N * L(b) - N * L(c) = L(a + N * b - N * c)
        bc = FusibleBroadcasted(f, args)
        linear_fs = linear_functions_in_linear_combination(bc)
        fusible_linear_fs = filter(unique(linear_fs)) do linear_f
            count(==(linear_f), linear_fs) > 1
        end
        isempty(fusible_linear_fs) && return bc
        fused_linear_combination_terms = map(fusible_linear_fs) do linear_f
            coefficients_and_args =
                linear_function_coefficients_and_args(bc, linear_f)
            summands = map(coefficients_and_args) do (coefficient, arg)
                @assert coefficient != 0
                if coefficient == 1
                    arg
                elseif coefficient == -1
                    fused_bc(-, (arg,))
                else
                    fused_bc(*, (coefficient, arg))
                end
            end
            if length(summands) == 1
                FusibleBroadcasted(linear_f, (summands[1],))
            else
                FusibleBroadcasted(linear_f, (fused_bc(+, Tuple(summands)),))
            end
        end
        fused_linear_combination =
            fused_bc(+, Tuple(fused_linear_combination_terms))
        unfused_linear_combination =
            drop_linear_functions_from_combination(bc, fusible_linear_fs)
        if was_dropped(unfused_linear_combination)
            return fused_linear_combination
        else
            new_args = (fused_linear_combination, unfused_linear_combination)
            return FusibleBroadcasted(+, new_args)
        end
    else
        return FusibleBroadcasted(f, args)
    end
end

"""
    simplified_fusible_broadcasted(value)

When `value` is a `FusibleBroadcasted`, this fuses all nested functions and all
linear combinations of linear functions within `value`.
"""
simplified_fusible_broadcasted(value) =
    value isa FusibleBroadcasted ?
    fused_bc(value.f, map(simplified_fusible_broadcasted, value.args)) : value
