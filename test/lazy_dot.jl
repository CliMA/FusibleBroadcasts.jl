using Test
using JET
using FusibleBroadcasts

macro test_lazy_dot(args_expr, broadcast_expr)
    @assert Meta.isexpr(args_expr, :tuple)
    escaped_args = map(esc, args_expr.args)
    quote
        lazy_dot_call($(args_expr.args...)) = @lazy_dot $broadcast_expr
        lazy_dot_call_return_nothing($(args_expr.args...)) =
            (lazy_dot_call($(args_expr.args...)); nothing)
        lazy_dot_call_return_nothing($(escaped_args...)) # run once to compile

        @test Base.materialize(lazy_dot_call($(escaped_args...))) ==
              $(esc(:(@. $broadcast_expr)))

        @test_opt lazy_dot_call($(escaped_args...))
        @test_opt Base.materialize(lazy_dot_call($(escaped_args...)))

        @test (@allocated lazy_dot_call_return_nothing($(escaped_args...))) == 0
    end
end

@testset "@lazy_dot error checking" begin
    @test_throws "broadcastable" @macroexpand @lazy_dot 1
    @test_throws "broadcastable" @macroexpand @lazy_dot a
    @test_throws "broadcastable" @macroexpand @lazy_dot $sin(1)
    @test_throws "broadcastable" @macroexpand @lazy_dot foo(a) = 1
    @test_throws "broadcastable" @macroexpand @lazy_dot true ? 1 : 2
    @test_throws "broadcastable" @macroexpand @lazy_dot for i in 1:2
        nothing
    end

    @test_throws "assignment" @macroexpand @lazy_dot a = 1 + 2
    @test_throws "assignment" @macroexpand @lazy_dot (a = 1) + 2

    @test_throws "not \$-prefixed" @macroexpand @lazy_dot 0 + $sin(1 + 2)
end

@testset "FusibleBroadcasted construction and materialization" begin
    a = rand(10)
    b = rand(10, 10)

    @test_lazy_dot () 1 + 2
    @test_lazy_dot () sin(1)
    @test_lazy_dot () $sin(1) + $sin(2)
    @test_lazy_dot (a,) a + 1
    @test_lazy_dot (a,) sin(2a + 1) + 1
    @test_lazy_dot (a,) a^a^a^a^a^a^a^a^a^a^a^a^a^a^a^a^a^a^a^a^a^a^a^a
    @test_lazy_dot (a, b) a * b
    @test_lazy_dot (a, b) sin(2a + 1) * 2b + $sin(1)
    @test_lazy_dot (a, b) sin(2sin(2sin(2a + 1) * 2b + 1) * 2b + 1) * 2b
    @test_lazy_dot (a, b) sin(a) > b && sin(b) > a && 1 > 0
    @test_lazy_dot (a, b) sin(a) > b || sin(b) > a || 0 > 1
    @test_lazy_dot (a, b) 0 < sin(a) < sin(b) < 1 > 0
end
