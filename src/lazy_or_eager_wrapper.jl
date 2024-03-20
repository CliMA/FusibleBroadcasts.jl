"""
    LazyOrEagerWrapper

Supertype of `UnfusibleBroadcastEvaluator`s and `FusibleBroadcastAccumulator`s,
both of which are constructed as `<Type>([dest], [warn_on_unwrap])`.

The first constructor argument, `dest`, which is set to `UnknownDestination` by
default, represents a destination into which broadcasts can be materialized.
This argument only needs to be specified if the wrapper is going to be passed to
`unwrap`, in which case the default value of `UnknownDestination` will cause an
error to be thrown. For an `UnfusibleBroadcastEvaluator`, `dest` should be the
destination itself, but, for a `FusibleBroadcastAccumulator`, it only has to be
`similar` to the final `FusedBroadcast` destination.

The second constructor argument, `warn_on_unwrap`, which is set to `false` by
default, toggles whether a warning will be logged when the wrapper is passed to
`unwrap` (except for when this occurs in one of several common functions like
`propertynames` and `eltype`, which are easily extended to `LazyOrEagerWrapper`s
with well-defined destinations). This argument only needs to be specified when
`dest` is specified, since an `UnknownDestination` will always cause `unwrap` to
throw an error. A `LazyOrEagerWrapper` gets unwrapped whenever it is passed from
a user-defined method annotated with `@fusible` to one that is not annotated, so
this toggle can be used to check whether all of the broadcasts executed by a
block of code appear within annotated methods and can be handled by a
`FusibleBroadcastAccumulator`, or if some need to be handled separately by an
`UnfusibleBroadcastEvaluator`.
"""
abstract type LazyOrEagerWrapper{D, W} end
# Packages that need to extend the functionality of LazyOrEagerWrappers can
# avoid type piracy by specializing on the destination type D.

"""
    UnknownDestination()

The default destination for a `LazyOrEagerWrapper`. Errors upon being unwrapped.
"""
struct UnknownDestination end

"""
    unwrap(wrapper)

Extracts the destination of a `LazyOrEagerWrapper`; i.e., the array or
array-like object into which broadcasts get materialized. Throws an error when
the destination is an `UnknownDestination`.
"""
unwrap(wrapper) =
    wrapper.dest isa UnknownDestination ?
    error("Cannot unwrap UnknownDestination") : wrapper.dest

"""
    warn_on_unwrap(wrapper)

Checks whether a warning should be logged when a `LazyOrEagerWrapper` is passed
to `unwrap`.
"""
warn_on_unwrap(wrapper::LazyOrEagerWrapper{D, W}) where {D, W} = W

"""
    needs_unwrap_before_call(f, args...)

When one or more arguments in `args` are `LazyOrEagerWrapper`s, this checks
whether `unwrap` needs to be called on them before `f(args...)` is evaluated.
If at least one of the arguments also has `warn_on_unwrap` set to `true`, a
warning will be logged whenever `unwrap` is called.

In order to disable the warning for a particular function `f` (regardless of
whether it has any arguments with `warn_on_unwrap` set to `true`), add a new
method for `f` that accepts `LazyOrEagerWrapper`s and calls `unwrap` on them,
and then extend `needs_unwrap_before_call` to return `false` for that method.
"""
needs_unwrap_before_call(f, args...) = true

Base.propertynames(wrapper::LazyOrEagerWrapper) = propertynames(unwrap(wrapper))
needs_unwrap_before_call(::typeof(propertynames), ::LazyOrEagerWrapper) = false

Base.hasproperty(wrapper::LazyOrEagerWrapper, property) =
    hasproperty(unwrap(wrapper), property)
Base.hasproperty(wrapper::LazyOrEagerWrapper, property::Symbol) =
    hasproperty(unwrap(wrapper), property) # needed to avoid ambiguity with Base
needs_unwrap_before_call(::typeof(hasproperty), ::LazyOrEagerWrapper, _) = false

Base.eltype(wrapper::LazyOrEagerWrapper) = eltype(unwrap(wrapper))
needs_unwrap_before_call(::typeof(eltype), ::LazyOrEagerWrapper) = false

Base.axes(wrapper::LazyOrEagerWrapper, args...) = axes(unwrap(wrapper), args...)
needs_unwrap_before_call(::typeof(axes), ::LazyOrEagerWrapper, _...) = false

Base.length(wrapper::LazyOrEagerWrapper, args...) =
    length(unwrap(wrapper), args...)
needs_unwrap_before_call(::typeof(length), ::LazyOrEagerWrapper, _...) = false

"""
    UnfusibleBroadcastEvaluator([dest], [warn_on_unwrap])

A wrapper for `dest` that can be used to eagerly evaluate broadcast expressions
which appear in functions that are not annotated with `@fusible`.
"""
struct UnfusibleBroadcastEvaluator{D, W} <: LazyOrEagerWrapper{D, W}
    dest::D
end
UnfusibleBroadcastEvaluator(
    dest = UnknownDestination(),
    warn_on_unwrap = false,
) = UnfusibleBroadcastEvaluator{typeof(dest), warn_on_unwrap}(dest)

"""
    FusibleBroadcastAccumulator([dest], [warn_on_unwrap])

A wrapper for `dest` that can be used to lazily store broadcast expressions
which appear in functions that are annotated with `@fusible`.
"""
struct FusibleBroadcastAccumulator{D, W} <: LazyOrEagerWrapper{D, W}
    dest::D
    names::Vector{MatrixFields.FieldName}
    values::Vector{Any}
end
FusibleBroadcastAccumulator(
    dest = UnknownDestination(),
    warn_on_unwrap = false,
) = FusibleBroadcastAccumulator{typeof(dest), warn_on_unwrap}(
    dest,
    MatrixFields.FieldName[],
    [],
)

function get_value_at_name(accumulator, name)
    name_index = findfirst(==(name), accumulator.names)
    isnothing(name_index) && throw(KeyError(name))
    return @inbounds accumulator.values[name_index]
end
function set_value_at_name!(accumulator, name, value)
    name_index = findfirst(==(name), accumulator.names)
    if isnothing(name_index)
        overlapping_names = filter(accumulator.names) do other_name
            MatrixFields.is_overlapping_name(name, other_name)
        end
        isempty(overlapping_names) ||
            error("Cannot add a new entry for $name to broadcast accumulator \
                   because it would overlap with pre-existing entries for the \
                   following names: $(join(overlapping_names, ", "))")
        push!(accumulator.names, name)
        push!(accumulator.values, value)
    else
        @inbounds accumulator.values[name_index] = value
    end
end

"""
    fused_materialize!(accumulator, name, value, [f])

Adds an instruction of the form `dest.name .= value` (or `dest.name .f= value`
if a reduction operator `f` is specified) to a `FusibleBroadcastAccumulator`.
"""
function fused_materialize!(accumulator, name, value)
    name in accumulator.names &&
        @warn "Ignoring pre-existing entry for $name in broadcast accumulator"
    set_value_at_name!(accumulator, name, value)
end
function fused_materialize!(accumulator, name, value, f)
    new_value =
        FusibleBroadcasted(f, (get_value_at_name(accumulator, name), value))
    set_value_at_name!(accumulator, name, new_value)
end

"""
    simplify_accumulated_broadcasts!(accumulator)

Rearranges the broadcast expressions in a `FusibleBroadcastAccumulator` so as to
minimize the number of operations required to materialize them.
"""
simplify_accumulated_broadcasts!(accumulator) =
    @. accumulator.values = simplified_fusible_broadcasted(accumulator.values)
