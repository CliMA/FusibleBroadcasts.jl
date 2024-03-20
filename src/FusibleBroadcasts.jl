module FusibleBroadcasts

import ClimaCore: MatrixFields, Operators
import ClimaCore.Utilities: UnrolledFunctions

export @lazy_dot, @fusible

"""
    FusibleBroadcasted(f, args)

An analogue of `Base.broadcasted` that avoids computing broadcast styles and
axes, but which gets converted into the result of `Base.broadcasted` when used
in a broadcast expression.
"""
struct FusibleBroadcasted{F, A <: Tuple}
    f::F
    args::A
end

function Base.broadcastable(bc::FusibleBroadcasted)
    broadcastable_args =
        UnrolledFunctions.unrolled_map(Base.broadcastable, bc.args)
    return Base.broadcasted(bc.f, broadcastable_args...)
end
Base.materialize(bc::FusibleBroadcasted) =
    Base.materialize(Base.broadcastable(bc))

nested_bc_string(value) =
    if value isa FusibleBroadcasted
        f_string = value.f == (&) ? "(&)" : string(value.f)
        "$f_string($(join(map(nested_bc_string, value.args), ", ")))"
    else
        string(value)
    end
Base.show(io::IO, bc::FusibleBroadcasted) =
    print(io, "@lazy_dot $(nested_bc_string(bc))")

"""
    DroppedBroadcast()

Used as a replacement for in-place broadcast expressions that get dropped from
method definitions by `@fusible`. Also functions as an intermediate value during
broadcast simplification.
"""
struct DroppedBroadcast end

was_dropped(value) = value isa DroppedBroadcast

include("lazy_or_eager_wrapper.jl")
include("simplification.jl")
include("fused_broadcast.jl")
include("expression_utils.jl")
include("macros.jl")

end
