"""
    FusedBroadcastStep(names, values)

A set of `values`, some of which may be `FusibleBroadcasted` objects, that can
be simultaneously materialized into a destination at the given `FieldName`s.
"""
struct FusedBroadcastStep{
    T <: NTuple{<:Any, Tuple{MatrixFields.FieldName, Base.AbstractBroadcasted}},
} <: Base.AbstractBroadcasted
    names_and_broadcasts::T
end
function FusedBroadcastStep(names, values)
    length(names) == length(values) ||
        error("number of names and values must be the same")
    broadcasts = map(values) do value
        if value isa Base.AbstractBroadcasted
            value
        elseif value isa FusibleBroadcasted
            Base.broadcastable(value)
        else
            Base.broadcasted(identity, value)
        end
    end
    return FusedBroadcastStep(Tuple(map(tuple, names, broadcasts)))
end
Base.materialize!(dest, step::FusedBroadcastStep) =
    for (name, broadcast) in step.names_and_broadcasts
        MatrixFields.has_field(dest, name) ||
            error("Cannot materialize broadcast for $name into destination")
        Base.materialize!(MatrixFields.get_field(dest, name), broadcast)
    end # TODO: Fuse this loop when possible, e.g., for ClimaCore Fields

"""
    FusedBroadcast(accumulator, optimizer)

A materializable form of the lazy broadcast expressions in the given
`FusibleBroadcastAccumulator`, divided into `FusedBroadcastStep`s based on the
given `FusibleBroadcastOptimizer`.
"""
struct FusedBroadcast{S <: NTuple{<:Any, FusedBroadcastStep}} <:
       Base.AbstractBroadcasted
    steps::S
end
Base.materialize!(dest, fused_broadcast::FusedBroadcast) =
    for step in fused_broadcast.steps
        Base.materialize!(dest, step)
    end

"""
    FusibleBroadcastOptimizer

Controls how a `FusibleBroadcastAccumulator` gets divided into
`FusedBroadcastStep`s within a `FusedBroadcast`. This can be based on memory
usage, register pressure, code generation time, or some combination of factors.
"""
abstract type FusibleBroadcastOptimizer end

"""
    MaximizeFusion()

The default `FusibleBroadcastOptimizer`. Evaluates all accumulated broadcasts in
a single step.
"""
struct MaximizeFusion <: FusibleBroadcastOptimizer end

FusedBroadcast(accumulator) = FusedBroadcast(accumulator, MaximizeFusion())

function FusedBroadcast(accumulator, ::MaximizeFusion)
    simplify_accumulated_broadcasts!(accumulator)
    step = FusedBroadcastStep(accumulator.names, accumulator.values)
    return FusedBroadcast((step,))
end
