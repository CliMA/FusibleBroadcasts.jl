using Documenter
using FusibleBroadcasts

makedocs(;
    sitename = "FusibleBroadcasts.jl",
    modules = [FusibleBroadcasts],
    pages = ["Home" => "index.md", "API" => "api.md"],
    format = Documenter.HTML(prettyurls = get(ENV, "CI", nothing) == "true"),
)

deploydocs(
    repo = "github.com/CliMA/FusibleBroadcasts.jl.git",
    devbranch = "main",
    push_preview = true,
    forcepush = true,
)
