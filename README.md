# FusibleBroadcasts.jl

An experimental framework for fusing broadcast expressions across arbitrary language constructs (functions, loops, conditionals, and so on). This package is being developed with the goal of minimizing kernel launch cost in `ClimaAtmos.jl`, whose source code contains hundreds of broadcast expressions that could potentially be fused into a much smaller number of kernel launches.

|||
|---------------------:|:----------------------------------------------|
| **Documentation**    | [![dev][docs-dev-img]][docs-dev-url]          |
| **Docs Build**       | [![docs build][docs-bld-img]][docs-bld-url]   |
| **GHA CI**           | [![gha ci][gha-ci-img]][gha-ci-url]           |
| **Code Coverage**    | [![codecov][codecov-img]][codecov-url]        |

[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://CliMA.github.io/FusibleBroadcasts.jl/dev/

[docs-bld-img]: https://github.com/CliMA/FusibleBroadcasts.jl/actions/workflows/Documentation.yml/badge.svg
[docs-bld-url]: https://github.com/CliMA/FusibleBroadcasts.jl/actions/workflows/Documentation.yml

[gha-ci-img]: https://github.com/CliMA/FusibleBroadcasts.jl/actions/workflows/ci.yml/badge.svg
[gha-ci-url]: https://github.com/CliMA/FusibleBroadcasts.jl/actions/workflows/ci.yml

[codecov-img]: https://codecov.io/gh/CliMA/FusibleBroadcasts.jl/branch/main/graph/badge.svg
[codecov-url]: https://codecov.io/gh/CliMA/FusibleBroadcasts.jl
