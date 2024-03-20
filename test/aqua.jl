using Aqua
using FusibleBroadcasts

# This is separate from all the other tests because Aqua.test_all checks for
# ambiguities in Base and Core in addition to the ones in FusibleBroadcasts,
# resulting in a lot of false positives. Setting recursive to true ensures that
# sub-modules of FusibleBroadcasts are also checked for ambiguities.
@testset "Method ambiguity" begin
    Aqua.test_ambiguities(FusibleBroadcasts; recursive = true)
end

# Run the other Aqua tests, which are already wrapped in @testset blocks. Do not
# check for compat entries of dependencies that are only used for testing.
Aqua.test_all(
    FusibleBroadcasts;
    ambiguities = false,
    deps_compat = (; check_extras = false),
)
