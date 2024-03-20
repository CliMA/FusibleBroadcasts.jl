using Test
using FusibleBroadcasts

@testset "@fusible error checking" begin
    @test_throws "method definition" @macroexpand @fusible 1
    @test_throws "method definition" @macroexpand @fusible a
    @test_throws "method definition" @macroexpand @fusible true ? a : 1
    @test_throws "method definition" @macroexpand @fusible f(1)
    @test_throws "method definition" @macroexpand @fusible f(a)
    @test_throws "method definition" @macroexpand @fusible function f(a, b) end

    @test_throws "one argument annotated" @macroexpand @fusible f(a) = 1
    @test_throws "one argument annotated" @macroexpand @fusible f(a, b) = 1

    @test_throws "single argument" @macroexpand @fusible f(@fuse(a, b)) = 1
    @test_throws "single argument" @macroexpand @fusible f(@fuse(a, b), c) = 1

    @test_throws "symbol" @macroexpand @fusible f(@fuse(1::Int), a) = 1
    @test_throws "symbol" @macroexpand @fusible f(@fuse(a + 1), b) = 1

    @test_throws "unique" @macroexpand @fusible f(@fuse(a), @fuse(a)) = 1
    @test_throws "unique" @macroexpand @fusible f(@fuse(a), @fuse(a::Array)) = 1

    @test_throws "annotated arguments" @macroexpand @fusible f(@fuse(a)) =
        (b = similar(a); b .= 1)
    @test_throws "annotated arguments" @macroexpand @fusible f(@fuse(a), b) =
        (d = b.c.d; d .= 1)

    @test_throws "in-place" @macroexpand @fusible f(@fuse(a)) = 2 .* a
    @test_throws "in-place" @macroexpand @fusible f(@fuse(a), b) =
        a .= (2 .* b) + 1

    @test_throws "reassigned" @macroexpand @fusible f(@fuse(a)) = (a = 1)
    @test_throws "reassigned" @macroexpand @fusible f(@fuse(a)) = (a.b = 1)

    @test_throws "missing dots" @macroexpand @fusible f(@fuse(a)) =
        a .= 1 .< 2 < 3
    @test_throws "missing dots" @macroexpand @fusible f(@fuse(a)) =
        a .= 1 < 2 < 3 .> 0 .> -1
end

@testset "FusedBroadcast construction and materialization" begin
    @fusible function test_function!(
        @fuse(a),
        b;
        require_eager = false,
        require_unwrap = false,
    )
        n_vectors = require_unwrap ? length(a.vectors) : length(b.vectors)
        for vector_index in 1:n_vectors
            @. a.vectors.:($$vector_index) = b.vectors.:1 + 1
            getproperty(a.vectors, vector_index) .*= b.vectors.:($vector_index)
        end
        a.matrix .= 0
        var1 = var2 = require_unwrap ? size(a.matrix, 1) : size(b.matrix, 1)
        while var1 > 1
            inner_test_function!(var1, var2, a, b)
            require_eager && unfusible_inner_test_function!(var1, var2, a, b)
            var1 -= 1
        end
    end
    @fusible function inner_test_function!(var1, var2, @fuse(a), b)
        @. a.matrix += $sin(var1) + $getproperty(b.vectors, var2) + b.matrix
    end
    function unfusible_inner_test_function!(var1, var2, a, b)
        new_matrix = @. $getproperty(b.vectors, var2) + b.matrix # not in-place
        @. a.matrix += $sin(var1) + new_matrix
    end

    b = (; vectors = (rand(1), rand(2), rand(3), rand(4)), matrix = rand(4, 4))
    a_fused = deepcopy(b)
    a_unfused = deepcopy(b)

    @testset "FusedBroadcastAccumulator with UnknownDestination" begin
        a_accumulator = FusibleBroadcasts.FusibleBroadcastAccumulator()
        test_function!(a_accumulator, b)
        a_broadcast = FusibleBroadcasts.FusedBroadcast(a_accumulator)
        Base.materialize!(a_fused, a_broadcast)

        test_function!(a_unfused, b)
        @test a_unfused.vectors == a_fused.vectors
        @test a_unfused.matrix ≈ a_fused.matrix
    end

    @testset "FusedBroadcastAccumulator with unwrapping" begin
        a_accumulator = FusibleBroadcasts.FusibleBroadcastAccumulator(a_fused)
        test_function!(a_accumulator, b; require_unwrap = true)
        a_broadcast = FusibleBroadcasts.FusedBroadcast(a_accumulator)
        Base.materialize!(a_fused, a_broadcast)

        test_function!(a_unfused, b; require_unwrap = true)
        @test a_unfused.vectors == a_fused.vectors
        @test a_unfused.matrix ≈ a_fused.matrix
    end

    @testset "FusedBroadcastAccumulator and UnfusibleBroadcastEvaluator" begin
        a_accumulator = FusibleBroadcasts.FusibleBroadcastAccumulator(a_fused)
        test_function!(a_accumulator, b; require_eager = true)
        a_broadcast = FusibleBroadcasts.FusedBroadcast(a_accumulator)
        Base.materialize!(a_fused, a_broadcast)

        a_evaluator = FusibleBroadcasts.UnfusibleBroadcastEvaluator(a_fused)
        test_function!(a_evaluator, b; require_eager = true)

        test_function!(a_unfused, b; require_eager = true)
        @test a_unfused.vectors == a_fused.vectors
        @test a_unfused.matrix ≈ a_fused.matrix
    end

    @testset "Unwrap error" begin
        a_accumulator = FusibleBroadcasts.FusibleBroadcastAccumulator()
        @test_throws "UnknownDestination" test_function!(
            a_accumulator,
            b;
            require_unwrap = true,
        )
    end

    @testset "Unwrap warnings" begin
        a_accumulator =
            FusibleBroadcasts.FusibleBroadcastAccumulator(a_fused, true)
        @test_logs(
            (:warn, r"a\.vectors"),
            (:warn, r"a\.matrix"),
            test_function!(a_accumulator, b; require_unwrap = true),
        )

        a_accumulator =
            FusibleBroadcasts.FusibleBroadcastAccumulator(a_fused, true)
        @test_logs(
            (:warn, r"unfusible_inner_test_function!"),
            (:warn, r"unfusible_inner_test_function!"),
            (:warn, r"unfusible_inner_test_function!"),
            test_function!(a_accumulator, b; require_eager = true),
        )

        both_kwargs = (; require_eager = true, require_unwrap = true)
        a_accumulator =
            FusibleBroadcasts.FusibleBroadcastAccumulator(a_fused, true)
        @test_logs(
            (:warn, r"a\.vectors"),
            (:warn, r"a\.matrix"),
            (:warn, r"unfusible_inner_test_function!"),
            (:warn, r"unfusible_inner_test_function!"),
            (:warn, r"unfusible_inner_test_function!"),
            test_function!(a_accumulator, b; both_kwargs...),
        )
    end
end
