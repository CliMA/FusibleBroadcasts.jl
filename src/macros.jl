"""
    @lazy_dot <expression>

Roughly equivalent to `@.`, but without the call to `Base.materialize` that gets
inserted during the code lowering process.

Returns a `FusibleBroadcasted` object that lazily represents the computations in
the given expression. This object can be inserted directly into other broadcast
expressions, providing a mechanism for splitting up complex broadcasts into
smaller broadcasts without triggering allocations. Passing this object to
`Base.materialize` should be equivalent to replacing `@lazy_dot` with `@.`.
"""
macro lazy_dot(expr)
    dotted_expr = Base.Broadcast.__dot__(expr) # same as expanding :(@. $expr)
    is_broadcast_expr(dotted_expr) ||
        error("@lazy_dot must be followed by a broadcastable operation")
    !any_sub_expr(is_in_place_broadcast_expr, dotted_expr) ||
        error("@lazy_dot must not be followed by any assignment operations")
    return escaped_fusible_broadcast_expr(dotted_expr)
end

"""
    @fusible <method definition>

Generates two new method definitions, evaluating them along with the original.
One definition replaces all arguments that have `@fuse` annotations with
`FusibleBroadcastAccumulator`s, while the other definition replaces them with
`UnfusibleBroadcastEvaluator`s. If an annotated argument in the original
definition is restricted to some type `T`, the new methods are restricted to
`FusibleBroadcastAccumulator{T}` and `UnfusibleBroadcastEvaluator{T}`.

This macro can be thought of as an analogue of `@simd` that operates at the
level of broadcast expressions. Using this macro amounts to telling the compiler
that the body of the method definition satisfies the following constraints:
  - all broadcasts are in-place
  - all broadcast destinations are either an arguments annotated with `@fuse` or
    components of annotated arguments, and they are not aliased by other names
  - all broadcasts can be freely rearranged, regardless of any changes to
    floating point round-off error this may cause
  - all non-broadcast operations on arguments annotated with `@fuse` will always
    yield the same results when evaluated on inputs with some particular types
The first two constraints are checked automatically, but users should ensure
that they satisfy the other constraints when marking a method as `@fusible`.
"""
macro fusible(expr)
    is_method_definition_expr(expr) ||
        error("@fusible must be followed by a method definition")
    method_call_expr, body_expr = expr.args
    function_expr, method_arg_exprs, return_type_expr, typevar_exprs =
        split_method_call_expr(method_call_expr)

    wrapped_arg_indices = Int[]
    wrapped_arg_symbols = Symbol[]
    wrapped_arg_types = []
    for index in 1:length(method_arg_exprs)
        method_arg_expr = method_arg_exprs[index]
        if (
            Meta.isexpr(method_arg_expr, :macrocall) &&
            method_arg_expr.args[1] == Symbol("@fuse")
        )
            push!(wrapped_arg_indices, index)
            length(method_arg_expr.args) == 3 &&
                method_arg_expr.args[2] isa LineNumberNode ||
                error("@fuse must be followed by a single argument")
            wrapped_arg_expr = method_arg_expr.args[3]
            if wrapped_arg_expr isa Symbol
                push!(wrapped_arg_symbols, wrapped_arg_expr)
                push!(wrapped_arg_types, nothing)
            elseif (
                Meta.isexpr(wrapped_arg_expr, :(::)) &&
                length(wrapped_arg_expr.args) == 2 &&
                wrapped_arg_expr.args[1] isa Symbol
            )
                push!(wrapped_arg_symbols, wrapped_arg_expr.args[1])
                push!(wrapped_arg_types, wrapped_arg_expr.args[2])
            else
                error("@fuse must be followed by either a symbol or a symbol \
                       with a type restriction")
            end

            # Drop the @fuse annotation from the method argument expression
            method_arg_exprs[index] = wrapped_arg_expr
        end
    end
    !isempty(wrapped_arg_symbols) ||
        error("@fusible must be followed by a method definition with at least \
               one argument annotated using @fuse; e.g., @fuse(arg) or \
               @fuse(arg::T)")
    length(unique(wrapped_arg_symbols)) == length(wrapped_arg_symbols) ||
        error("arguments annotated using @fuse must have unique names")
    wrapped_arg_iterator =
        zip(wrapped_arg_indices, wrapped_arg_symbols, wrapped_arg_types)

    body_expr = macroexpand(Base.active_module(), body_expr) # Expand all @.'s

    # Evaluate user-provided expressions in the module where @fusible was called
    escaped_function_expr = esc(function_expr)
    escaped_method_arg_exprs = map(esc, method_arg_exprs)
    escaped_return_type_expr =
        isnothing(return_type_expr) ? nothing : esc(return_type_expr)
    escaped_typevar_exprs = map(esc, typevar_exprs)
    new_escaped_method_call_expr() = unsplit_method_call_expr(
        escaped_function_expr,
        escaped_method_arg_exprs,
        escaped_return_type_expr,
        escaped_typevar_exprs,
    )
    escaped_method_call_expr = new_escaped_method_call_expr()
    escaped_body_expr = esc(body_expr)

    # Generate a new method that can handle FusibleBroadcastAccumulators
    for (index, symbol, type) in wrapped_arg_iterator
        escaped_method_arg_exprs[index] =
            isnothing(type) ? :($(esc(symbol))::FusibleBroadcastAccumulator) :
            :($(esc(symbol))::FusibleBroadcastAccumulator{<:$(esc(type))})
    end
    escaped_lazy_method_call_expr = new_escaped_method_call_expr()
    escaped_lazy_body_expr =
        escaped_expr_with_lazy_broadcasts(body_expr, wrapped_arg_symbols)

    # Generate a new method that can handle UnfusibleBroadcastEvaluators
    for (index, symbol, type) in wrapped_arg_iterator
        escaped_method_arg_exprs[index] =
            isnothing(type) ? :($(esc(symbol))::UnfusibleBroadcastEvaluator) :
            :($(esc(symbol))::UnfusibleBroadcastEvaluator{<:$(esc(type))})
    end
    escaped_eager_method_call_expr = new_escaped_method_call_expr()
    escaped_eager_body_expr =
        escaped_expr_without_fusible_broadcasts(body_expr, wrapped_arg_symbols)

    # Generate a new method for needs_unwrap_before_call
    for (index, _, type) in wrapped_arg_iterator
        escaped_method_arg_exprs[index] =
            isnothing(type) ? :(::LazyOrEagerWrapper) :
            :(::LazyOrEagerWrapper{<:$(esc(type))})
    end
    escaped_function_type_expr = :(::$(esc(:typeof))($escaped_function_expr))
    escaped_needs_unwrap_before_call_arg_exprs =
        Meta.isexpr(method_arg_exprs[1], :parameters) ?
        [
            escaped_method_arg_exprs[1],
            escaped_function_type_expr,
            escaped_method_arg_exprs[2:end]...,
        ] : [escaped_function_type_expr, escaped_method_arg_exprs...]
    escaped_needs_unwrap_before_call_expr = unsplit_method_call_expr(
        GlobalRef(FusibleBroadcasts, :needs_unwrap_before_call),
        escaped_needs_unwrap_before_call_arg_exprs,
        nothing,
        escaped_typevar_exprs,
    )

    return quote
        $escaped_method_call_expr = $escaped_body_expr
        $escaped_lazy_method_call_expr = $escaped_lazy_body_expr
        $escaped_eager_method_call_expr = $escaped_eager_body_expr
        $escaped_needs_unwrap_before_call_expr = false
    end
end

might_need_unwrap_with_warning(expr, wrapped_arg_aliases) =
    expr in wrapped_arg_aliases ||
    expr isa Expr && any(in(wrapped_arg_aliases), expr.args)

# Move @warn into a separate function so that the abundance of code it generates
# doesn't clutter the output of @macroexpand.
call_warn_macro(warning_string) = @warn warning_string

function escaped_unwrapped_expr_with_warning(
    expr,
    wrapped_arg_aliases,
    line_node_or_nothing,
)
    line_string =
        isnothing(line_node_or_nothing) ? "" :
        " from $(line_node_or_nothing.file):$(line_node_or_nothing.line)"
    if expr in wrapped_arg_aliases
        needs_warning_expr = :(warn_on_unwrap($(esc(expr))))
        warning_string = "Unwrapping $expr$line_string"
        unwrapped_expr = :(unwrap($(esc(expr))))
    else
        wrapped_args_to_unwrap = filter(in(wrapped_arg_aliases), expr.args)
        either_expr = (expr1, expr2) -> :($expr1 || $expr2)
        needs_warning_expr =
            mapreduce(either_expr, wrapped_args_to_unwrap) do arg
                :(warn_on_unwrap($(esc(arg))))
            end
        wrapped_args_string = join(wrapped_args_to_unwrap, ", ", " and ")
        warning_string = "Unwrapping $wrapped_args_string to evaluate \
                          `$expr`$line_string"
        unwrapped_expr_args = map(expr.args) do arg
            arg in wrapped_arg_aliases ? :(unwrap($(esc(arg)))) : esc(arg)
        end
        unwrapped_expr = Expr(expr.head, unwrapped_expr_args...)
    end
    warning_expr = :($needs_warning_expr && call_warn_macro($warning_string))
    unwrapped_expr_with_warning = Expr(:block, warning_expr, unwrapped_expr)
    return Meta.isexpr(expr, :call) ?
           :(
        needs_unwrap_before_call($(map(esc, expr.args)...)) ?
        $unwrapped_expr_with_warning : $(esc(expr))
    ) : unwrapped_expr_with_warning
end

escaped_fusible_broadcast_expr(expr, lazy_broadcast_function_args = nothing) =
    if is_allocating_broadcast_expr(expr) && !Meta.isexpr(expr, :comparison)
        f_expr, unfused_arg_exprs = if Meta.isexpr(expr, :call)
            esc(undotted_operator(expr.args[1])), expr.args[2:end]
        elseif Meta.isexpr(expr, :.)
            f_expr = escaped_fusible_broadcast_expr(
                expr.args[1],
                lazy_broadcast_function_args,
            )
            f_expr, expr.args[2].args
        elseif Meta.isexpr(expr, :.&&)
            GlobalRef(Base, :andand), expr.args
        elseif Meta.isexpr(expr, :.||)
            GlobalRef(Base, :oror), expr.args
        end
        arg_exprs = map(unfused_arg_exprs) do arg
            escaped_fusible_broadcast_expr(arg, lazy_broadcast_function_args)
        end
        :(FusibleBroadcasted($f_expr, ($(arg_exprs...),)))
    elseif is_allocating_broadcast_expr(expr)
        f_indices = 2:2:length(expr.args)
        undotted_f_exprs = filter(!is_dotted_operator, expr.args[f_indices])
        undotted_f_strings = map(expr -> "\"$expr\"", undotted_f_exprs)
        isempty(undotted_f_strings) || error(
            "operators in a non-binary comparison must all be dotted in \
             order to be fused; the following expression is missing dots \
             on $(join(undotted_f_strings, ", ", " and ")): $expr",
        )
        and_expr = GlobalRef(Base, :andand)
        both_bcs_expr =
            (expr1, expr2) -> :(FusibleBroadcasted($and_expr, ($expr1, $expr2)))
        mapreduce(both_bcs_expr, f_indices) do index
            f_expr = esc(undotted_operator(expr.args[index]))
            arg1_expr = escaped_fusible_broadcast_expr(
                expr.args[index - 1],
                lazy_broadcast_function_args,
            )
            arg2_expr = escaped_fusible_broadcast_expr(
                expr.args[index + 1],
                lazy_broadcast_function_args,
            )
            :(FusibleBroadcasted($f_expr, ($arg1_expr, $arg2_expr)))
        end
    elseif !isnothing(lazy_broadcast_function_args)
        escaped_expr_with_lazy_broadcasts(expr, lazy_broadcast_function_args...)
    elseif any_sub_expr(is_allocating_broadcast_expr, expr)
        error("@lazy_dot must not be followed by any \$-prefixed operations \
               whose arguments depend on operations that are not \$-prefixed")
    else
        esc(expr)
    end

escaped_expr_with_lazy_broadcasts(expr, wrapped_arg_symbols) =
    escaped_expr_with_lazy_broadcasts(
        expr,
        Dict(map(symbol -> symbol => (symbol, []), wrapped_arg_symbols)),
        Ref{LineNumberNode}(),
    )
escaped_expr_with_lazy_broadcasts(expr, wrapped_arg_alias_map, line_node_ref) =
    if (
        is_in_place_broadcast_expr(expr) &&
        drop_trailing_property_exprs(expr.args[1]) in
        keys(wrapped_arg_alias_map)
    )
        alias_symbol, new_property_exprs =
            split_nested_getproperty_expr(expr.args[1])
        dest_symbol, inner_property_exprs = wrapped_arg_alias_map[alias_symbol]
        outer_property_exprs = map(new_property_exprs) do new_property_expr
            escaped_expr_with_lazy_broadcasts(
                new_property_expr,
                wrapped_arg_alias_map,
                line_node_ref,
            )
        end
        property_exprs = [inner_property_exprs..., outer_property_exprs...]
        name_expr = :(MatrixFields.FieldName($(property_exprs...)))
        bc_expr = escaped_fusible_broadcast_expr(
            expr.args[2],
            (wrapped_arg_alias_map, line_node_ref),
        )
        f_expr = assignment_operator_function(undotted_operator(expr.head))
        arg_exprs =
            isnothing(f_expr) ? (esc(dest_symbol), name_expr, bc_expr) :
            (esc(dest_symbol), name_expr, bc_expr, esc(f_expr))
        :(fused_materialize!($(arg_exprs...)))
    elseif (
        (Meta.isexpr(expr, :(=)) && expr.args[1] isa Symbol) &&
        drop_trailing_property_exprs(expr.args[2]) in
        keys(wrapped_arg_alias_map)
    )
        alias_symbol, new_property_exprs =
            split_nested_getproperty_expr(expr.args[2])
        dest_symbol, inner_property_exprs = wrapped_arg_alias_map[alias_symbol]
        outer_property_exprs = map(new_property_exprs) do new_property_expr
            escaped_expr_with_lazy_broadcasts(
                new_property_expr,
                wrapped_arg_alias_map,
                line_node_ref,
            )
        end
        property_exprs = [inner_property_exprs..., outer_property_exprs...]
        wrapped_arg_alias_map[expr.args[1]] = (dest_symbol, property_exprs)
        # TODO: Throw a warning when unwrapping here, but only return this
        # expression when the alias is used somewhere other than the left-hand
        # side of a broadcast expression.
        unwrapped_dest_expr = :(unwrap($(esc(dest_symbol))))
        alias_value_expr =
            unsplit_nested_getproperty_expr(unwrapped_dest_expr, property_exprs)
        :($(esc(expr.args[1])) = $alias_value_expr)
    elseif is_in_place_broadcast_expr(expr)
        dest_expr = drop_trailing_property_exprs(expr.args[1])
        available_aliases = map(repr, Tuple(keys(wrapped_arg_alias_map)))
        error(
            "broadcasts in an @fusible method definition can only be \
             materialized into arguments annotated with @fuse, or into \
             components of annotated arguments; the following expression does \
             not match any of the annotated arguments or their components \
             ($(join(available_aliases, ", ", " and "))): $dest_expr",
        )
    elseif is_allocating_broadcast_expr(expr)
        error("all broadcasts in an @fusible method definition must be \
               in-place; the following broadcast expression allocates memory: \
               $expr")
    elseif (
        is_value_reassigning_expr(expr) &&
        drop_trailing_property_exprs(reassigned_value_expr(expr)) in
        keys(wrapped_arg_alias_map)
    )
        error("arguments annotated with @fuse (and components of annotated \
               arguments) cannot be reassigned, but the following expression \
               changes the value of $(reassigned_value_expr(expr)): $expr")
    elseif might_need_unwrap_with_warning(expr, keys(wrapped_arg_alias_map))
        escaped_unwrapped_expr_with_warning(
            expr,
            keys(wrapped_arg_alias_map),
            isdefined(line_node_ref, 1) ? line_node_ref[] : nothing,
        )
    elseif expr isa LineNumberNode
        line_node_ref[] = expr
        expr
    elseif (
        any_sub_expr(is_broadcast_expr, expr) ||
        any_sub_expr(in(keys(wrapped_arg_alias_map)), expr) ||
        any_sub_expr(arg -> arg isa LineNumberNode, expr)
    )
        if is_new_scope_expr(expr)
            # TODO: Check that new scope does not change pre-existing aliases
            # without immediately assigning them values; e.g., that there are no
            # for-loop iteration variables with the same names as wrapped args
            wrapped_arg_alias_map = copy(wrapped_arg_alias_map)
        end
        new_args = map(expr.args) do arg
            escaped_expr_with_lazy_broadcasts(
                arg,
                wrapped_arg_alias_map,
                line_node_ref,
            )
        end
        # Drop LineNumberNodes from auto-generated expressions
        Expr(expr.head, filter(arg -> !(arg isa LineNumberNode), new_args)...)
    else
        esc(expr)
    end

# This is called after escaped_expr_with_lazy_broadcasts, so it does not need to
# check for errors.
escaped_expr_without_fusible_broadcasts(expr, wrapped_arg_symbols) =
    escaped_expr_without_fusible_broadcasts(
        expr,
        Dict(map(symbol -> symbol => (symbol, []), wrapped_arg_symbols)),
        Ref{LineNumberNode}(),
    )
escaped_expr_without_fusible_broadcasts(
    expr,
    wrapped_arg_alias_map,
    line_node_ref,
) =
    if is_in_place_broadcast_expr(expr)
        :(DroppedBroadcast())
    elseif (
        (Meta.isexpr(expr, :(=)) && expr.args[1] isa Symbol) &&
        drop_trailing_property_exprs(expr.args[2]) in
        keys(wrapped_arg_alias_map)
    )
        alias_symbol, new_property_exprs =
            split_nested_getproperty_expr(expr.args[2])
        dest_symbol, inner_property_exprs = wrapped_arg_alias_map[alias_symbol]
        outer_property_exprs = map(new_property_exprs) do new_property_expr
            escaped_expr_without_fusible_broadcasts(
                new_property_expr,
                wrapped_arg_alias_map,
                line_node_ref,
            )
        end
        property_exprs = [inner_property_exprs..., outer_property_exprs...]
        wrapped_arg_alias_map[expr.args[1]] = (dest_symbol, property_exprs)
        unwrapped_dest_expr = :(unwrap($(esc(dest_symbol))))
        alias_value_expr =
            unsplit_nested_getproperty_expr(unwrapped_dest_expr, property_exprs)
        :($(esc(expr.args[1])) = $alias_value_expr)
    elseif might_need_unwrap_with_warning(expr, keys(wrapped_arg_alias_map))
        escaped_unwrapped_expr_with_warning(
            expr,
            keys(wrapped_arg_alias_map),
            isdefined(line_node_ref, 1) ? line_node_ref[] : nothing,
        )
    elseif expr isa LineNumberNode
        line_node_ref[] = expr
        expr
    elseif (
        any_sub_expr(is_broadcast_expr, expr) ||
        any_sub_expr(in(keys(wrapped_arg_alias_map)), expr) ||
        any_sub_expr(arg -> arg isa LineNumberNode, expr)
    )
        if is_new_scope_expr(expr)
            wrapped_arg_alias_map = copy(wrapped_arg_alias_map)
        end
        new_args = map(expr.args) do arg
            escaped_expr_without_fusible_broadcasts(
                arg,
                wrapped_arg_alias_map,
                line_node_ref,
            )
        end
        # Drop LineNumberNodes from auto-generated expressions
        Expr(expr.head, filter(arg -> !(arg isa LineNumberNode), new_args)...)
    else
        esc(expr)
    end
