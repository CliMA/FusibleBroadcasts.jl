# Reference: https://docs.julialang.org/en/v1/devdocs/ast/#Surface-syntax-AST

any_sub_expr(f, expr) =
    f(expr) || (expr isa Expr && any(arg -> any_sub_expr(f, arg), expr.args))

is_assignment_operator(expr) =
    (expr isa Symbol && Meta.isoperator(expr)) &&
    (string(expr)[1] != '.' && string(expr)[end] == '=')

assignment_operator_function(assignment_op) =
    assignment_op == :(=) ? nothing : Symbol(string(assignment_op)[1:(end - 1)])

is_value_reassigning_expr(expr) =
    expr isa Expr && is_assignment_operator(expr.head) || (
        Meta.isexpr(expr, :call) &&
        length(expr.args) == 4 &&
        expr.args[1] in (:setproperty!, :(Base.setproperty!))
    )

reassigned_value_expr(value_modifying_expr) =
    is_assignment_operator(value_modifying_expr.head) ?
    value_modifying_expr.args[1] :
    :($(value_modifying_expr.args[2]).$(value_modifying_expr.args[3]))

is_dotted_operator(expr) =
    (expr isa Symbol && Meta.isoperator(expr)) &&
    (string(expr)[1] == '.' && !(expr in (:., :.., :...)))

undotted_operator(dotted_op) = Symbol(string(dotted_op)[2:end])

is_in_place_broadcast_expr(expr) =
    expr isa Expr &&
    (is_dotted_operator(expr.head) && string(expr.head)[end] == '=')

is_allocating_broadcast_expr(expr) =
    (Meta.isexpr(expr, :call) && is_dotted_operator(expr.args[1])) ||
    (Meta.isexpr(expr, :.) && Meta.isexpr(expr.args[2], :tuple)) ||
    Meta.isexpr(expr, (:.&&, :.||)) ||
    (
        Meta.isexpr(expr, :comparison) &&
        any(is_dotted_operator, expr.args[2:2:end])
    )

is_broadcast_expr(expr) =
    is_in_place_broadcast_expr(expr) || is_allocating_broadcast_expr(expr)

is_getproperty_dot_expr(expr) =
    Meta.isexpr(expr, :.) && !Meta.isexpr(expr.args[2], :tuple)

is_getproperty_call_expr(expr) =
    Meta.isexpr(expr, :call) &&
    length(expr.args) == 3 &&
    expr.args[1] in (:getproperty, :(Base.getproperty))

is_getproperty_expr(expr) =
    is_getproperty_dot_expr(expr) || is_getproperty_call_expr(expr)

split_getproperty_expr(getproperty_expr) =
    is_getproperty_dot_expr(getproperty_expr) ?
    (getproperty_expr.args[1], getproperty_expr.args[2]) :
    (getproperty_expr.args[2], getproperty_expr.args[3])

unsplit_getproperty_expr(inner_expr, property_expr) =
    Expr(:., inner_expr, property_expr)

drop_trailing_property_exprs(expr) =
    is_getproperty_expr(expr) ?
    drop_trailing_property_exprs(split_getproperty_expr(expr)[1]) : expr

split_nested_getproperty_expr(expr) =
    if is_getproperty_expr(expr)
        inner_expr, last_property_expr = split_getproperty_expr(expr)
        innermost_expr, inner_property_exprs =
            split_nested_getproperty_expr(inner_expr)
        property_exprs = [inner_property_exprs..., last_property_expr]
        innermost_expr, property_exprs
    else
        expr, []
    end

unsplit_nested_getproperty_expr(innermost_expr, property_exprs) =
    if isempty(property_exprs)
        innermost_expr
    else
        inner_expr = unsplit_nested_getproperty_expr(
            innermost_expr,
            property_exprs[1:(end - 1)],
        )
        unsplit_getproperty_expr(inner_expr, property_exprs[end])
    end

is_method_call_expr(expr) =
    Meta.isexpr(expr, :call) ||
    (Meta.isexpr(expr, :where) && is_method_call_expr(expr.args[1]))

split_method_call_expr(method_call_expr) =
    if Meta.isexpr(method_call_expr, :where)
        function_expr, method_arg_exprs, return_type_expr, inner_typevar_exprs =
            split_method_call_expr(method_call_expr.args[1])
        typevar_exprs =
            [inner_typevar_exprs..., method_call_expr.args[2:end]...]
        function_expr, method_arg_exprs, return_type_expr, typevar_exprs
    elseif Meta.isexpr(method_call_expr, :(::))
        function_expr, method_arg_exprs, return_type_expr, typevar_exprs =
            split_method_call_expr(method_call_expr.args[1])
        @assert isnothing(return_type_expr) && isempty(typevar_exprs)
        function_expr, method_arg_exprs, method_call_expr.args[2], typevar_exprs
    else
        method_call_expr.args[1], method_call_expr.args[2:end], nothing, []
    end

unsplit_method_call_expr(
    function_expr,
    method_arg_exprs,
    return_type_expr,
    typevar_exprs,
) =
    if isnothing(return_type_expr)
        isempty(typevar_exprs) ? :($function_expr($(method_arg_exprs...))) :
        :($function_expr($(method_arg_exprs...)) where {$(typevar_exprs...)})
    else
        isempty(typevar_exprs) ?
        :($function_expr($(method_arg_exprs...))::$return_type_expr) :
        :(
            $function_expr(
                $(method_arg_exprs...),
            )::$return_type_expr where {$(typevar_exprs...)}
        )
    end

is_method_definition_expr(expr) =
    Meta.isexpr(expr, (:(=), :function)) && is_method_call_expr(expr.args[1])

is_new_scope_expr(expr) =
    Meta.isexpr(expr, (:->, :for, :while, :let, :try)) ||
    is_method_definition_expr(expr)
