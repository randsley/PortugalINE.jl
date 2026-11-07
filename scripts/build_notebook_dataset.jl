#!/usr/bin/env julia
#
# Build the Portuguese municipal dataset that SpatialEconometrics.jl's
# notebooks use, and the one provenance file that covers all of it.
#
#     julia --project=. scripts/build_notebook_dataset.jl <output-dir> [caop.json]
#
# With no second argument the boundaries are downloaded from DGT's OGC API,
# which is about 200 MB of GeoJSON, so pass a local copy when iterating.
#
# Written files:
#
#   portugal_municipalities.csv            308 rows, attributes
#   portugal_municipalities_queen.gal      278 mainland, shared vertex
#   portugal_municipalities_rook.gal       278 mainland, shared edge
#   portugal_municipalities_centroids.csv  278 mainland, area-weighted
#   portugal_municipalities_PROVENANCE.md  both citations, contents, caveats
#
# Why 308 attribute rows against 278 weights rows: the islands have figures and
# no land neighbours. Carrying them in the CSV with a `mainland` column makes
# the choice explicit; putting them in the matrix would give 30 zero rows that
# cannot be row-standardised.
#
# This replaced two earlier scripts, both now removed: a pyptine-based Python
# extract written before layer 2 existed, and a separate weights builder that
# wrote a second provenance file for the same dataset. Two scripts producing
# one dataset is how the two halves of it come to disagree.
# `verify_against_reference.jl` checked this route against the Python one,
# value by value, before the switch.

using PortugalINE
using PortugalINE.Codes: DISTRICT_NAMES
using Printf

const CAOP_URL = "https://ogcapi.dgterritorio.gov.pt/collections/municipios/items?f=json&limit=400"
const PERIOD = "2023"

# Column name, INE indicator, and the unit as INE states it.
const COLUMNS = [
    (:purchasing_power,  "0014580", "index, Portugal = 100"),
    (:pp_share_national, "0014581", "% of national total"),
    (:pp_dynamism,       "0014582", "relative factor"),
    (:density,           "0013189", "inhabitants / km2"),
    (:ageing_ratio,      "0012909", "persons 65+ per 100 aged 0-14"),
]

fetch_caop(dest) = (@info "downloading CAOP (about 200 MB)" CAOP_URL;
                    run(`curl -sS --max-time 900 $CAOP_URL -o $dest`); dest)

# INE publishes a whole number without a decimal point, and reformatting 198 as
# 198.0 would change the file without changing the data. Print back what was
# published.
fmt(v) = ismissing(v) ? "" :
         (v == round(v) && abs(v) < 1e15 ? string(Int(round(v))) : string(v))

_today() = Base.Libc.strftime("%Y-%m-%d", time())

function main(args)
    isempty(args) && error("usage: build_notebook_dataset.jl <output-dir> [caop.json]")
    outdir = abspath(args[1]); mkpath(outdir)

    # Coverage first. The catalogue states each indicator's finest geography,
    # so an indicator that stops at NUTS III is caught before the download
    # rather than after. 0013351, the ageing ratio on NUTS 2013, is exactly
    # that trap: it returns 39 rows and no municipality.
    # The main-group catalogue covers 326 indicators and is not all of INE:
    # 0014581 is absent from it. So the group listing is the cheap path and
    # `catalogue_entry` is the fallback, which is the endpoint that serves
    # indicators outside the group.
    @info "checking municipal coverage against the catalogue"
    by = Dict(e.varcd => e for e in catalogue())
    titles = Dict{String, String}()
    for (name, code, _) in COLUMNS
        e = get(by, code, nothing)
        src = "main group"
        if e === nothing
            e = catalogue_entry(code)
            src = "single lookup"
        end
        ismunicipal(e) || error(
            "indicator $code ($name) is published only to $(e.geo_lastlevel), " *
            "so it cannot carry a municipal W")
        @printf("  %-18s %s  %-10s (%s)\n", name, code, e.geo_lastlevel, src)
    end

    # Attributes, over all 308 municipalities. No boundaries involved.
    @info "fetching indicators"
    vals = Dict{Symbol, Dict{String, Union{Float64, Missing}}}()
    dicos = String[]; names = Dict{String, String}()
    for (name, code, _) in COLUMNS
        ind = indicator_metadata(code)
        titles[code] = ind.name
        d = indicator_data(code; period = period_code(ind, PERIOD))
        m = municipal_values(d)
        length(m.dico) == 308 || error(
            "indicator $code returned $(length(m.dico)) municipalities, not 308")
        vals[name] = Dict(m.dico .=> m.value)
        if isempty(dicos)
            dicos = m.dico
            for i in eachindex(m.dico)
                names[m.dico[i]] = m.name[i]
            end
        else
            m.dico == dicos || error("indicator $code has a different municipality set")
            # A name disagreement is survivable -- the join is on DICO -- but it
            # must be chosen, not absorbed. The island suffixes are the known
            # case, and the first indicator's spelling wins.
            diff = [d0 for d0 in dicos if m.name[findfirst(==(d0), m.dico)] != names[d0]]
            isempty(diff) || @warn "name spellings differ; keeping the first indicator's" n = length(diff) sample = first(diff, 4)
        end
        @printf("  %-18s %s  %3d municipalities\n", name, code, length(m.dico))
    end

    # The NUTS code carries the geography vintage, and the district and island
    # split are read off the code rather than from a hand-kept table.
    geo = Dict{String, String}()
    let m = municipal_values(indicator_data(COLUMNS[1][2];
                                            period = period_code(indicator_metadata(COLUMNS[1][2]), PERIOD)))
        for i in eachindex(m.dico)
            geo[m.dico[i]] = m.geocod[i]
        end
    end

    csv = joinpath(outdir, "portugal_municipalities.csv")
    nmain = 0
    open(csv, "w") do io
        println(io, "dico,name,district,district_name,mainland,",
                join((c[1] for c in COLUMNS), ","))
        for d0 in dicos
            g = geo[d0]
            dist = district(g)
            main = ismainland(g)
            main && (nmain += 1)
            print(io, d0, ",", names[d0], ",", dist, ",",
                  DISTRICT_NAMES[dist], ",", main)
            for (name, _, _) in COLUMNS
                print(io, ",", fmt(vals[name][d0]))
            end
            println(io)
        end
    end
    @printf("wrote %s  (%d rows, %d mainland, %d island)\n", basename(csv),
            length(dicos), nmain, length(dicos) - nmain)

    # Weights, over the mainland only.
    src = length(args) >= 2 ? args[2] : fetch_caop(joinpath(tempdir(), "caop_municipios.json"))
    b = read_caop_geojson(src)
    length(b) == 278 || error(
        "expected the 278 mainland municipalities, read $(length(b)). The " *
        "islands are a separate CAOP collection and have no land neighbours, " *
        "so they must not be mixed in here.")
    perm = sortperm(b.codes)
    b = MunicipalBoundaries(b.codes[perm], b.names[perm], b.rings[perm])
    b.codes == [d0 for d0 in dicos if ismainland(geo[d0])] || error(
        "the boundary DICOs are not the attribute file's mainland DICOs; the " *
        "boundary vintage and the indicator geography disagree about what exists")

    links = Dict{Symbol, Int}(); degs = Dict{Symbol, Vector{Int}}()
    for crit in (:queen, :rook)
        nb = neighbour_lists(b; criterion = crit)
        deg = length.(nb)
        any(iszero, deg) && error("$(count(iszero, deg)) municipalities have no " *
                                  "neighbours under $crit, so the boundaries are " *
                                  "not a node-matched planar partition")
        write_gal(joinpath(outdir, "portugal_municipalities_$(crit).gal"), b;
                  criterion = crit)
        links[crit] = sum(deg) ÷ 2; degs[crit] = deg
        @printf("wrote portugal_municipalities_%s.gal  (%d links, mean degree %.3f, min %d, max %d)\n",
                crit, sum(deg) ÷ 2, sum(deg) / length(b), minimum(deg), maximum(deg))
    end

    nbq = neighbour_lists(b; criterion = :queen)
    nbr = neighbour_lists(b; criterion = :rook)
    point_pairs = [(b.names[i], b.names[j]) for i in eachindex(b.codes)
                   for j in nbq[i] if i < j && !(j in nbr[i])]

    C = centroids(b)
    cen = joinpath(outdir, "portugal_municipalities_centroids.csv")
    open(cen, "w") do io
        println(io, "dico,name,lon,lat")
        for i in eachindex(b.codes)
            @printf(io, "%s,%s,%.6f,%.6f\n", b.codes[i], b.names[i], C[i, 1], C[i, 2])
        end
    end
    println("wrote ", basename(cen))

    # ---------------------------------------------------------------------
    # One provenance file for the whole dataset. Both licences require a
    # credit, and a dataset split across two provenance files is a dataset
    # whose two halves drift apart.
    # ---------------------------------------------------------------------
    prov = joinpath(outdir, "portugal_municipalities_PROVENANCE.md")
    open(prov, "w") do io
        println(io, "# Portuguese municipalities: provenance and attribution")
        println(io)
        println(io, "Two sources, each with a credit that is a condition of its licence.")
        println(io, "Keep both with any published result.")
        println(io)
        println(io, "> Source: Statistics Portugal (INE), indicators ",
                join((c[2] for c in COLUMNS), ", "), ", reference period ",
                PERIOD, ", extracted ", _today(), ".")
        println(io, ">")
        println(io, "> ", CAOP_ATTRIBUTION)
        println(io)
        println(io, "INE data is open for reuse, commercial and non-commercial, under EU")
        println(io, "Directive 2019/1024. INE retains copyright: the data is openly licensed,")
        println(io, "not public domain, and reuse is conditional on citing the source.")
        println(io, "Boundaries are **CAOP2025** from Direção-Geral do Território, licensed")
        println(io, "**CC-BY-4.0** with public access unrestricted.")
        println(io)
        println(io, "## Files")
        println(io)
        println(io, "| file | units | contents |")
        println(io, "|---|---|---|")
        println(io, "| `portugal_municipalities.csv` | 308 | attributes, one row per municipality |")
        println(io, "| `portugal_municipalities_queen.gal` | 278 | contiguity by shared vertex, ",
                links[:queen], " links |")
        println(io, "| `portugal_municipalities_rook.gal` | 278 | contiguity by shared edge, ",
                links[:rook], " links |")
        println(io, "| `portugal_municipalities_centroids.csv` | 278 | area-weighted centroids, WGS84 |")
        println(io)
        println(io, "Everything is keyed and ordered by **DICO**, the official")
        println(io, "district-and-municipality code, so the files line up by sorting alone.")
        println(io, "The key is the DICO and not INE's NUTS code, which changes between")
        println(io, "vintages, nor the name, because `Calheta` names two municipalities.")
        println(io)
        println(io, "## Columns")
        println(io)
        println(io, "| column | indicator | unit |")
        println(io, "|---|---|---|")
        println(io, "| `dico` | official district-and-municipality code | 4 digits |")
        println(io, "| `name` | municipality name | |")
        println(io, "| `district`, `district_name` | from the first two DICO digits | 1-18 mainland |")
        println(io, "| `mainland` | whether district <= 18 | |")
        for (name, code, unit) in COLUMNS
            println(io, "| `", name, "` | ", code, " | ", unit, " |")
        end
        println(io)
        println(io, "Full indicator titles, as INE states them:")
        println(io)
        for (_, code, _) in COLUMNS
            println(io, "- **", code, "** - ", titles[code])
        end
        println(io)
        println(io, "## Three things to know before modelling")
        println(io)
        println(io, "**The islands have no land neighbours.** Of the 308 municipalities, ",
                length(dicos) - nmain, " are")
        println(io, "in Madeira and the Azores. That is why the weights files cover the ",
                nmain)
        println(io, "mainland units and the CSV covers all 308: a contiguity matrix over")
        println(io, "every row would have ", length(dicos) - nmain, " zero rows and could not be")
        println(io, "row-standardised. Filter on `mainland`, or use a k-nearest or")
        println(io, "distance-based weighting that gives every unit neighbours. The column is")
        println(io, "here so the choice is explicit rather than discovered in a singular matrix.")
        println(io)
        println(io, "**`purchasing_power`, `pp_share_national` and `pp_dynamism` come from the")
        println(io, "same INE study** and are not independent of one another. Use one as a")
        println(io, "dependent variable; do not put two of them on opposite sides of a")
        println(io, "regression and read the fit as a finding.")
        println(io)
        println(io, "**The GAL files are row-standardised on read, not on disk.** They hold")
        println(io, "binary contiguity. Standardise after any further subsetting, never")
        println(io, "before: dropping a unit changes its neighbours' degrees, so a")
        println(io, "standardised matrix is only valid for the exact set it was computed over.")
        println(io)
        println(io, "## Queen against rook")
        println(io)
        println(io, "The two differ by exactly **", length(point_pairs), " pair",
                length(point_pairs) == 1 ? "" : "s",
                "**, meeting at a single point rather than")
        println(io, "along a border:")
        println(io)
        for (a, c) in point_pairs
            println(io, "- ", a, " and ", c)
        end
        println(io)
        println(io, "Mean degree is ", @sprintf("%.3f", sum(degs[:queen]) / nmain),
                " under queen and ",
                @sprintf("%.3f", sum(degs[:rook]) / nmain), " under rook. The choice is")
        println(io, "usually presented as consequential; on these boundaries it moves ",
                length(point_pairs), " links")
        println(io, "out of ", links[:queen], ".")
        println(io)
        println(io, "Contiguity was computed by hashing vertices and edges, not by")
        println(io, "intersecting polygons, because CAOP is a clean planar partition: a shared")
        println(io, "border carries identical vertices in both rings. That was measured, not")
        println(io, "assumed -- hashing exact `Float64` pairs and hashing coordinates rounded")
        println(io, "to six decimals give the same graph. No geometry engine is involved and")
        println(io, "the result is exact rather than tolerance-dependent.")
        println(io)
        println(io, "## How this was produced")
        println(io)
        println(io, "`scripts/build_notebook_dataset.jl` in")
        println(io, "[PortugalINE.jl](https://github.com/randsley/PortugalINE.jl), in one run.")
        println(io, "It fails rather than writes if an indicator is not published to municipal")
        println(io, "level, if any indicator returns other than 308 municipalities, if the")
        println(io, "indicators disagree about which municipalities exist, if the boundaries")
        println(io, "are not the 278 mainland units, or if any unit ends up with no neighbours.")
        println(io)
        println(io, "Values are written back in the form INE published them, so a whole")
        println(io, "number stays a whole number.")
        println(io)
        println(io, "One trap worth repeating: indicator `0008258` is also \"Ageing ratio\"")
        println(io, "with identical values, but on the **NUTS 2013** geography (344 codes")
        println(io, "against 347). Joining it to the NUTS 2024 indicators would misalign")
        println(io, "silently, so `0012909` is used instead. Check the geography vintage named")
        println(io, "in an indicator's title before joining it to anything.")
    end
    println("wrote ", basename(prov))
end

main(ARGS)
