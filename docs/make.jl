using Documenter
using PortugalINE

# The doctests run offline: none of them touches INE.
DocMeta.setdocmeta!(PortugalINE, :DocTestSetup, :(using PortugalINE); recursive = true)

makedocs(
    sitename = "PortugalINE.jl",
    modules = [PortugalINE],
    # Internal helpers carry docstrings for the next reader of the source;
    # the manual is checked against the exported surface.
    checkdocs = :exports,
    authors = "Nigel Randsley",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://randsley.github.io/PortugalINE.jl",
        edit_link = "master",
        repolink = "https://github.com/randsley/PortugalINE.jl",
    ),
    repo = "https://github.com/randsley/PortugalINE.jl/blob/{commit}{path}#{line}",
    pages = [
        "Home" => "index.md",
        "Geography codes" => "codes.md",
        "Indicators" => "indicators.md",
        "Boundaries and weights" => "boundaries.md",
        "Joining" => "join.md",
        "Panels" => "panels.md",
        "Web maps" => "web.md",
    ],
)

deploydocs(repo = "github.com/randsley/PortugalINE.jl.git", devbranch = "master")
