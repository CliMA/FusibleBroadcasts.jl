using SafeTestsets

#! format: off
@safetestset "@lazy_dot" begin @time include("lazy_dot.jl") end
@safetestset "simplification" begin @time include("simplification.jl") end
@safetestset "@fusible" begin @time include("fusible.jl") end
@safetestset "Aqua" begin @time include("aqua.jl") end
#! format: on
