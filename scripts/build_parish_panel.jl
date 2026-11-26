#!/usr/bin/env julia
#
# Build a balanced panel of the 2,882 mainland Portuguese parishes over
# 2018-2023, with one contiguity structure and one provenance file.
#
#     python scripts/caop_gpkg_to_geojson.py Continente_CAOP2024.gpkg cont_freguesias caop2024_freguesias.json
#     julia --project=. scripts/build_parish_panel.jl <output-dir> caop2024_freguesias.json
#
# The GeoPackage is https://geo2.dgterritorio.gov.pt/caop/CAOP_Continente_2024-gpkg.zip
# (DGT, CC-BY-4.0). CAOP2024 and not the current CAOP: INE's parish figures are
# on the 2013 parish map, which CAOP2024.1 and later no longer carry.
#
# Written files:
#
#   portugal_parishes_panel.csv             2,882 x 6 rows, long: dicofre, name, period, columns
#   portugal_parishes_panel_queen.gal       one per unit: the map does not change
#   portugal_parishes_panel_centroids.csv   area-weighted, EPSG:3763 metres
#   portugal_parishes_panel_PROVENANCE.md   citations, columns, what the join dropped
#
# Why these indicators and these years. A survey of every parish-level
# indicator on 2026-11-26 (19 of them, read from the Portuguese catalogue)
# found two that cover all 2,882 mainland parishes in more than one year on the
# 2013 map: gross declared income per taxpayer (0012748, 2018-2024) and live
# births (0008234, 2014-2023). Their overlap is 2018-2023. The area (0011866)
# is there to make densities, and is annual on the same map up to 2024. The
# rest are Census 2021 only, suppressed for most parishes (median net income
# 0012757: 680-735 of 2,882), published only for the parishes of large
# municipalities (rents, sales), or on the 2025 map (0014584, 0014773).
#
# This is the data a spatial panel needs and a cross-section cannot give: a
# cross-section cannot tell a spatial lag from spatially correlated errors.

using PortugalINE
using Printf

const PERIODS = string.(2018:2023)
const NMAIN = 2882

# Column name, INE indicator, dimension filter, unit.
const COLUMNS = [
    (:income,   "0012748", Dict{Int, String}(), "EUR per taxpayer (gross declared income, mean)"),
    (:births,   "0008234", Dict(3 => "T"),      "live births, both sexes (count)"),
    (:area_km2, "0011866", Dict{Int, String}(), "km2"),
]

function main(args)
    length(args) == 2 || error("usage: build_parish_panel.jl <output-dir> <caop2024_freguesias.json>")
    outdir = abspath(args[1]); mkpath(outdir)

    # Coverage first, from the Portuguese records: INE's translations of
    # geo_lastlevel are inconsistent and the Portuguese is the stable form.
    @info "checking parish coverage"
    titles = Dict{String, String}()
    for (_, code, _, _) in COLUMNS
        e = catalogue_entry(code; language = "PT")
        e.geo_lastlevel == "Freguesia" || error(
            "indicator $code is published to $(e.geo_lastlevel), not to parish level")
        titles[code] = e.title
        ps = periods(indicator_metadata(code; language = "PT"))
        missing_p = setdiff(PERIODS, ps)
        isempty(missing_p) || error("indicator $code has no period(s) $(join(missing_p, ", "))")
    end

    # One request per indicator for all six years: an unfiltered request would
    # give only the latest, so the periods go as one comma-separated Dim1.
    @info "fetching indicators"
    data = [nm => indicator_data(code; period = PERIODS, dimensions = dims, timeout = 600)
            for (nm, code, dims, _) in COLUMNS]

    b = read_caop_geojson(args[2]; level = :parish, edition = "CAOP2024")
    length(b) == NMAIN || error(
        "expected the $NMAIN mainland parishes of CAOP2024, read $(length(b)). CAOP2024.1 " *
        "and CAOP2025 carry the 2025 parish map (3,049), which INE does not publish on.")

    p = join_panel(b, data...; periods = PERIODS)
    show(stdout, MIME("text/plain"), p); println()

    # The panel is balanced over the whole mainland or it is not written.
    d = dropped(p)
    length(p) == NMAIN || error("the panel has $(length(p)) parishes, not $NMAIN")
    isempty(d.geometry) || error("$(length(d.geometry)) parishes lack a row in some indicator or year")
    isempty(d.data) || error("$(length(d.data)) mainland parishes have values and no CAOP2024 " *
                             "boundary: " * join(first(d.data, 8), ", "))
    for (k, M) in pairs(p.columns)
        nm = count(ismissing, M)
        nm == 0 || @warn "$k has $nm missing cells"
    end
    deg = vec(sum(p.adjacency; dims = 2))
    any(iszero, deg) && error("$(count(iszero, deg)) parishes have no neighbours")

    files = write_panel(outdir, p; name = "portugal_parishes_panel",
                        coordinate_names = ("x_m", "y_m"))

    # What write_panel cannot know: what the columns mean and why these.
    open(last(files), "a") do io
        println(io)
        println(io, "## The columns")
        println(io)
        println(io, "| column | INE indicator | unit |")
        println(io, "|---|---|---|")
        for (nm, code, _, unit) in COLUMNS
            println(io, "| `", nm, "` | ", code, " | ", unit, " |")
        end
        println(io)
        println(io, "Titles, as INE states them in Portuguese:")
        println(io)
        for (_, code, _, _) in COLUMNS
            println(io, "- **", code, "** - ", titles[code])
        end
        println(io)
        println(io, "## Things to know before modelling")
        println(io)
        println(io, "**Why 2018-2023, and why these.** On 2026-11-26 only two parish-level")
        println(io, "indicators covered all 2,882 mainland parishes in more than one year on")
        println(io, "the 2013 map: income (2018-2024) and births (2014-2023). The years are")
        println(io, "their overlap. INE publishes no annual population by parish; the")
        println(io, "Census 2021 is the only parish count, so births are a count, not a rate.")
        println(io)
        println(io, "**The parish map is the one of the 2013 reform.** Law 25-A/2025 restored")
        println(io, "302 mainland parishes; the current CAOP carries 3,049. INE's area")
        println(io, "indicator lists both maps, and its restored parishes, empty before 2025,")
        println(io, "are counted above as units of another map. Do not join these files to a")
        println(io, "current CAOP layer.")
        println(io)
        println(io, "**Births abroad are not a parish.** INE's births carry `000000000`,")
        println(io, "\"Estrangeiro\", which PortugalINE.jl leaves out.")
        println(io)
        println(io, "Produced by `scripts/build_parish_panel.jl` in")
        println(io, "[PortugalINE.jl](https://github.com/randsley/PortugalINE.jl). It fails")
        println(io, "rather than writes if an indicator is not at parish level, lacks a year,")
        println(io, "or leaves the panel short of $NMAIN parishes, or if a parish has no")
        println(io, "neighbours.")
    end
    foreach(f -> println("wrote ", basename(f)), files)
end

main(ARGS)
