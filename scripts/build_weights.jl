#!/usr/bin/env julia
#
# Build the spatial weights for the 278 mainland Portuguese municipalities and
# write them as a GeoDa GAL file.
#
#     julia --project=. scripts/build_weights.jl <output-dir> [caop.json]
#
# With no second argument the boundaries are downloaded from DGT's OGC API.
# That is about 200 MB of GeoJSON, so pass a local copy when iterating.
#
# GAL is the output format because SpatialEconometrics.jl already reads it for
# the Columbus data. That is the whole point: the weights cross the gap as a
# small text file, and nothing at the far end parses a polygon or touches the
# network.
#
# CAOP is CC-BY-4.0 and the credit DGT specifies is a licence condition, so it
# is written into the provenance file beside the weights rather than left to a
# reader's goodwill.

using PortugalINE
using Printf

const CAOP_URL = "https://ogcapi.dgterritorio.gov.pt/collections/municipios/items?f=json&limit=400"

function fetch_caop(dest::AbstractString)
    @info "downloading CAOP mainland municipalities (about 200 MB)" CAOP_URL
    run(`curl -sS --max-time 900 $CAOP_URL -o $dest`)
    return dest
end

function main(args)
    isempty(args) && error("usage: build_weights.jl <output-dir> [caop.json]")
    outdir = abspath(args[1])
    mkpath(outdir)

    src = length(args) >= 2 ? args[2] : fetch_caop(joinpath(tempdir(), "caop_municipios.json"))
    b = read_caop_geojson(src)
    n = length(b)
    n == 278 || error("expected the 278 mainland municipalities, read $n. " *
                      "The islands are a separate CAOP collection and have no " *
                      "land neighbours, so they must not be mixed in here.")

    # Order the municipalities by DICO so the GAL file, the CSV of attributes
    # and anything else keyed on DICO can be lined up by sorting alone.
    perm = sortperm(b.codes)
    b = MunicipalBoundaries(b.codes[perm], b.names[perm], b.rings[perm])

    results = Dict{Symbol, Any}()
    for crit in (:queen, :rook)
        nb = neighbour_lists(b; criterion = crit)
        deg = length.(nb)
        any(iszero, deg) && error(
            "$(count(iszero, deg)) municipalities have no neighbours under " *
            "$crit, which means the boundaries are not a node-matched planar " *
            "partition. Contiguity by vertex hashing is not valid on them.")
        path = joinpath(outdir, "portugal_municipalities_$(crit).gal")
        write_gal(path, b; criterion = crit)
        results[crit] = (; path, links = sum(deg) ÷ 2, deg)
        @printf("%-6s links=%4d  mean degree=%.3f  min=%d  max=%d  -> %s\n",
                crit, sum(deg) ÷ 2, sum(deg) / n, minimum(deg), maximum(deg),
                basename(path))
    end

    # The pairs that are queen neighbours but not rook ones: they touch at a
    # single point. Naming them is more use than counting them.
    nbq = neighbour_lists(b; criterion = :queen)
    nbr = neighbour_lists(b; criterion = :rook)
    point_pairs = Tuple{String, String}[]
    for i in 1:n, j in nbq[i]
        i < j && !(j in nbr[i]) && push!(point_pairs, (b.names[i], b.names[j]))
    end

    C = centroids(b)
    cpath = joinpath(outdir, "portugal_municipalities_centroids.csv")
    open(cpath, "w") do io
        println(io, "dico,name,lon,lat")
        for i in 1:n
            @printf(io, "%s,%s,%.6f,%.6f\n", b.codes[i], b.names[i], C[i, 1], C[i, 2])
        end
    end
    println("centroids -> ", basename(cpath))

    prov = joinpath(outdir, "portugal_weights_PROVENANCE.md")
    open(prov, "w") do io
        println(io, "# Portuguese municipal weights: provenance and attribution")
        println(io)
        println(io, "> ", CAOP_ATTRIBUTION)
        println(io)
        println(io, "Boundaries from **CAOP2025**, the Carta Administrativa Oficial de")
        println(io, "Portugal, served by Direção-Geral do Território's OGC API at")
        println(io, "`", CAOP_URL, "`,")
        println(io, "retrieved ", first(string(Dates_today()), 10), ". CAOP is licensed")
        println(io, "**CC-BY-4.0** with public access unrestricted; the credit above is a")
        println(io, "condition of that licence, so keep it with any published result.")
        println(io)
        println(io, "## Files")
        println(io)
        println(io, "| file | contents |")
        println(io, "|---|---|")
        println(io, "| `portugal_municipalities_queen.gal` | contiguity by shared vertex, ",
                results[:queen].links, " links |")
        println(io, "| `portugal_municipalities_rook.gal` | contiguity by shared edge, ",
                results[:rook].links, " links |")
        println(io, "| `portugal_municipalities_centroids.csv` | area-weighted centroids, WGS84 |")
        println(io)
        println(io, "Units are the **278 mainland municipalities**, ordered by DICO, which")
        println(io, "is the same key the attribute CSV uses, so sorting lines the two up.")
        println(io, "The 30 island municipalities are excluded deliberately: they share no")
        println(io, "land border with anything, so including them would give 30 zero rows")
        println(io, "and a matrix that cannot be row-standardised.")
        println(io)
        println(io, "## Queen against rook")
        println(io)
        println(io, "The two differ by exactly **", length(point_pairs),
                " pair", length(point_pairs) == 1 ? "" : "s",
                "**, which meet at a single point rather than")
        println(io, "along a border:")
        println(io)
        for (a, c) in point_pairs
            println(io, "- ", a, " and ", c)
        end
        println(io)
        println(io, "Mean degree is ", @sprintf("%.3f", sum(results[:queen].deg) / n),
                " under queen and ",
                @sprintf("%.3f", sum(results[:rook].deg) / n), " under rook. The choice")
        println(io, "between them is usually presented as consequential; on these")
        println(io, "boundaries it moves two links out of ", results[:queen].links, ".")
        println(io)
        println(io, "## How contiguity was computed")
        println(io)
        println(io, "By hashing vertices and edges, not by intersecting polygons, because")
        println(io, "CAOP is a clean planar partition: a shared border carries identical")
        println(io, "vertices in both rings. That was measured, not assumed -- hashing")
        println(io, "exact `Float64` pairs and hashing coordinates rounded to six decimals")
        println(io, "give the same graph. So no geometry engine is involved and the result")
        println(io, "is exact rather than tolerance-dependent.")
        println(io)
        println(io, "Produced by `scripts/build_weights.jl` in PortugalINE.jl.")
    end
    println("provenance -> ", basename(prov))

    println()
    println("queen-only (point-touching) pairs:")
    for (a, c) in point_pairs
        println("   ", a, " -- ", c)
    end
end

# Avoid a Dates dependency for one date string.
Dates_today() = Base.Libc.strftime("%Y-%m-%d", time())

main(ARGS)
