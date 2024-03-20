using Test
using JET
using FusibleBroadcasts

const simplified = FusibleBroadcasts.simplified_fusible_broadcasted

macro test_all(expr)
    return quote
        local test_func() = $(esc(expr))
        @test test_func()
        # @test_opt test_func() # TODO: Fix some type instabilities.
        # @test (@allocated test_func()) == 0
    end
end

@testset "broadcast expression simplification" begin
    a = rand(1)
    b = rand(1)
    c = rand(1)
    d = rand(1)
    e = rand(1)
    f = rand(1)
    g = rand(1)

    @test_all simplified(@lazy_dot +a) == a
    @test_all simplified(@lazy_dot *(a)) == a

    @test_all simplified(@lazy_dot -(-a)) == a
    @test_all simplified(@lazy_dot adjoint(adjoint(a))) == a

    @test_all simplified(@lazy_dot ((a + b) + c) + d + (e + (f + g))) ==
              (@lazy_dot a + b + c + d + e + f + g)
    @test_all simplified(@lazy_dot ((a * b) * c) * d * (e * (f * g))) ==
              (@lazy_dot a * b * c * d * e * f * g)

    @test_all simplified(@lazy_dot ((a - b) - c) - d - (e - (f - g))) ==
              (@lazy_dot (a + f) - (b + c + d + e + g))
    @test_all simplified(@lazy_dot ((a / b) / c) / d / (e / (f / g))) ==
              (@lazy_dot (a * f) / (b * c * d * e * g))

    @test_all simplified(@lazy_dot ((a - b) - (-c)) - d - (-e - (-f - (-g)))) ==
              (@lazy_dot (a + c + e + g) - (b + d + f))

    @test_all simplified(@lazy_dot a * (-b) * (-c) * (-d) + (-e) * (-f) * g) ==
              (@lazy_dot e * f * g - a * b * c * d)
    @test_all simplified(@lazy_dot (-a) / b + c / (-d) + (-e) / (-f)) ==
              (@lazy_dot e / f - (a / b + c / d))

    @test_all simplified(@lazy_dot adjoint(2 * a) + 3 * adjoint(4 * b)) ==
              (@lazy_dot adjoint(2 * a + 3 * 4 * b))
    @test_all simplified(@lazy_dot adjoint(2 * adjoint(a) - 3 * adjoint(b))) ==
              (@lazy_dot 2 * a + (-3) * b)
end
