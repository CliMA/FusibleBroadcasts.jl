# BroadcastFusion.jl

An experimental framework for fusing broadcast expressions across arbitrary language constructs (functions, loops, conditionals, and so on). This package is being developed with the goal of minimizing kernel launch cost in `ClimaAtmos.jl`, whose source code contains hundreds of broadcast expressions that could potentially be fused into a much smaller number of kernel launches.

This package exports two macros:
- `@lazy_dot`: An analogue to `@.` that executes calls to `Base.broadcasted` but drops the final call to `Base.materialize`. This macro be used to split long broadcast expressions into meaningful sub-expressions without sacrificing performance.
- `@fusible`: An annotation that can be added to method definitions, allowing them to participate in the process of broadcast fusion. As long as the method body satisfies several syntactic constraints, this macro can generate an alternative method definition in which all calls to `Base.materialize!` are replaced with calls to `fused_materialize!`, which stores the output of `@lazy_dot` so that it can later be evaluated in an optimally fused way.
