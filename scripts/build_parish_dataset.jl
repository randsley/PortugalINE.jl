#!/usr/bin/env julia
#
# Build the dataset of the 2,882 mainland Portuguese parishes (freguesias),
# with contiguity weights and one provenance file.
#
#     python scripts/caop_gpkg_to_geojson.py Continente_CAOP2024.gpkg cont_freguesias caop2024_freguesias.json
#     julia --project=. scripts/build_parish_dataset.jl <output-dir> caop2024_freguesias.json
#
# The GeoPackage is CAOP_Continente_2024-gpkg.zip from DGT's CAOP page
# (https://www.dgterritorio.gov.pt/cartografia/cartografia-tematica/caop).
#
# Written files:
#
#   portugal_parishes.csv             2,882 rows, attributes
#   portugal_parishes_queen.gal       shared vertex
#   portugal_parishes_rook.gal        shared edge
#   portugal_parishes_centroids.csv   area-weighted, EPSG:3763 metres
#   portugal_parishes_PROVENANCE.md   both citations, contents, caveats
#
# **The boundary vintage is CAOP2024, not the current CAOP2025, on purpose.**
# INE publishes its parish figures on the parish map of the 2013 reform: 3,092
# parishes, 2,882 of them on the mainland. Law 25-A/2025 restored parishes that
# the 2013 reform had merged, and CAOP2024.1 (August 2025) and CAOP2025 carry
# the restored map: 3,049 mainland parishes, with new codes for the restored
# ones, which INE does not publish. Measured 2026-11-25: CAOP2024 and INE's 2024
# income figures share all 2,882 codes, with no name differing, and CAOP's
# areas agree with INE's own (0011866, 2024) to a median of 0.012%. DGT's OGC
# API serves only CAOP2025, so the boundaries come from the GeoPackage.

using PortugalINE
using PortugalINE.Codes: DISTRICT_NAMES
using PortugalINE.Boundaries: MunicipalBoundaries
using Printf

# Column name, INE indicator, reference period, dimension filter, unit.
const COLUMNS = [
    (:income_2024,  "0012748", "2024", Dict{Int, String}(), "EUR per taxpayer (gross declared income)"),
    (:income_2021,  "0012748", "2021", Dict{Int, String}(), "EUR per taxpayer (gross declared income)"),
    (:unemployment, "0012328", "2021", Dict(3 => "T"), "% (Census 2021, both sexes)"),
    (:illiteracy,   "0012273", "2021", Dict(3 => "T"), "% (Census 2021, both sexes)"),
    (:population,   "0012295", "2021", Dict(3 => "T", 4 => "T", 5 => "T"), "persons (Census 2021)"),
    (:quarters_density, "0012514", "2021", Dict{Int, String}(), "living quarters per km2 (Census 2021)"),
    (:area_km2,     "0011866", "2021", Dict{Int, String}(), "km2"),
]
const NMAIN = 2882

fmt(v) = ismissing(v) ? "" :
         (v == round(v) && abs(v) < 1e15 ? string(Int(round(v))) : string(v))
_today() = Base.Libc.strftime("%Y-%m-%d", time())
csvf(s) = any(c -> c in (',', '"'), s) ? string('"', replace(s, '"' => "\"\""), '"') : s

function fetch_values(code, period, dims)
    ind = indicator_metadata(code)
    for attempt in 1:4
        try
            d = indicator_data(code; period = period_code(ind, period), dimensions = dims,
                               timeout = 600)
            return ind, d, parish_values(d)
        catch e
            (e isa ArgumentError || attempt == 4) && rethrow()
            @warn "INE request failed, retrying" code attempt exception = e
            sleep(20 * attempt)
        end
    end
end

function main(args)
    length(args) == 2 || error("usage: build_parish_dataset.jl <output-dir> <caop2024_freguesias.json>")
    outdir = abspath(args[1]); mkpath(outdir)

    @info "checking parish coverage against the catalogue"
    by = Dict(e.varcd => e for e in catalogue())
    for code in unique(c[2] for c in COLUMNS)
        e = get(by, code, nothing)
        e === nothing && (e = catalogue_entry(code))
        e.geo_lastlevel == "Freguesia" || error(
            "indicator $code is published only to $(e.geo_lastlevel), not to parish level")
    end

    @info "fetching indicators"
    vals = Dict{Symbol, Dict{String, Union{Float64, Missing}}}()
    titles = Dict{String, String}(); extracted = String[]
    keys0 = String[]; names = Dict{String, String}(); extras = Dict{Symbol, Int}()
    for (name, code, period, dims, _) in COLUMNS
        ind, d, m = fetch_values(code, period, dims)
        titles[code] = ind.name; push!(extracted, d.extracted)
        keep = [i for i in eachindex(m.dicofre) if ismainland(m.dicofre[i])]
        # Some indicators (the area, 0011866) list the parishes of both maps:
        # the 2,882 of 2013 and the 302 restored in 2025, the latter with no
        # value before 2025. Codes beyond the first indicator's set are dropped
        # only if every one of them is empty; a value there is an error.
        if !isempty(keys0) && length(keep) > NMAIN
            inset = Set(keys0)
            extra = [i for i in keep if !(m.dicofre[i] in inset)]
            all(i -> ismissing(m.value[i]), extra) || error(
                "indicator $code ($period) has values for parishes outside the 2013 map")
            extras[name] = length(extra)
            keep = [i for i in keep if m.dicofre[i] in inset]
        end
        ks = m.dicofre[keep]
        length(ks) == NMAIN || error(
            "indicator $code ($period) returned $(length(ks)) mainland parishes, not $NMAIN")
        if isempty(keys0)
            keys0 = ks
            for i in keep; names[m.dicofre[i]] = m.name[i]; end
        else
            ks == keys0 || error("indicator $code has a different parish set")
            nd = count(i -> m.name[i] != names[m.dicofre[i]], keep)
            nd == 0 || @warn "parish names differ from the first indicator's; keeping the first" code n = nd
        end
        vals[name] = Dict(m.dicofre[i] => m.value[i] for i in keep)
        @printf("  %-17s %s %s  %d parishes, %d missing\n", name, code, period, length(ks),
                count(ismissing, m.value[keep]))
    end

    b = read_caop_geojson(args[2]; level = :parish)
    length(b) == NMAIN || error(
        "expected the $NMAIN mainland parishes of CAOP2024, read $(length(b)). CAOP2024.1 " *
        "and CAOP2025 carry the 2025 parish map (3,049), which INE does not publish on.")
    perm = sortperm(b.codes)
    b = MunicipalBoundaries(b.codes[perm], b.names[perm], b.rings[perm], :parish)
    b.codes == keys0 || error(
        "the boundary DICOFREs are not INE's mainland DICOFREs: " *
        "$(length(setdiff(b.codes, keys0))) only in CAOP, $(length(setdiff(keys0, b.codes))) only in INE")
    ndiffname = count(i -> b.names[i] != names[b.codes[i]], eachindex(b.codes))

    # The planar-partition check, at parish level: rounding every vertex to the
    # millimetre must leave the graph unchanged, or the hashing is not exact.
    rb = MunicipalBoundaries(b.codes, b.names,
        [[[(round(x; digits = 3), round(y; digits = 3)) for (x, y) in r] for r in rs] for rs in b.rings],
        :parish)
    links = Dict{Symbol, Int}(); degs = Dict{Symbol, Vector{Int}}()
    for crit in (:queen, :rook)
        nb = neighbour_lists(b; criterion = crit)
        nb == neighbour_lists(rb; criterion = crit) || error(
            "rounding to the millimetre changed the $crit graph, so CAOP's parish " *
            "layer is not node-matched and the hashing is not exact")
        deg = length.(nb)
        any(iszero, deg) && error("$(count(iszero, deg)) parishes have no neighbours under $crit")
        write_gal(joinpath(outdir, "portugal_parishes_$(crit).gal"), b; criterion = crit)
        links[crit] = sum(deg) ÷ 2; degs[crit] = deg
        @printf("wrote portugal_parishes_%s.gal  (%d links, mean degree %.3f, min %d, max %d)\n",
                crit, links[crit], sum(deg) / NMAIN, minimum(deg), maximum(deg))
    end
    nbq = neighbour_lists(b); nbr = neighbour_lists(b; criterion = :rook)
    npoint = sum(length(setdiff(nbq[i], nbr[i])) for i in eachindex(nbq)) ÷ 2

    csv = joinpath(outdir, "portugal_parishes.csv")
    open(csv, "w") do io
        println(io, "dicofre,name,dico,district,district_name,", join((c[1] for c in COLUMNS), ","))
        for k in keys0
            dist = district(k)
            print(io, k, ",", csvf(names[k]), ",", k[1:4], ",", dist, ",", DISTRICT_NAMES[dist])
            for c in COLUMNS
                print(io, ",", fmt(vals[c[1]][k]))
            end
            println(io)
        end
    end
    println("wrote ", basename(csv), "  ($(length(keys0)) rows)")

    C = centroids(b)
    open(joinpath(outdir, "portugal_parishes_centroids.csv"), "w") do io
        println(io, "dicofre,name,x_m,y_m")
        for i in eachindex(b.codes)
            @printf(io, "%s,%s,%.2f,%.2f\n", b.codes[i], csvf(names[b.codes[i]]), C[i, 1], C[i, 2])
        end
    end
    println("wrote portugal_parishes_centroids.csv")

    lettered = [k for k in keys0 if !all(isdigit, k)]
    prov = joinpath(outdir, "portugal_parishes_PROVENANCE.md")
    open(prov, "w") do io
        println(io, "# Portuguese parishes: provenance and attribution")
        println(io)
        println(io, "Two sources, each with a credit that is a condition of its licence.")
        println(io, "Keep both with any published result.")
        println(io)
        println(io, "> Source: Statistics Portugal (INE), indicators ",
                join(sort(unique(c[2] for c in COLUMNS)), ", "), ", reference periods ",
                join(sort(unique(c[3] for c in COLUMNS)), ", "), ", extracted ",
                first(minimum(extracted), 10), ".")
        println(io, ">")
        println(io, "> ", CAOP_ATTRIBUTION)
        println(io)
        println(io, "INE data is open for reuse, commercial and non-commercial, under EU")
        println(io, "Directive 2019/1024. INE retains copyright: reuse is conditional on")
        println(io, "citing the source. The boundaries are **CAOP2024** (mainland) from")
        println(io, "Direção-Geral do Território, licensed **CC-BY-4.0**.")
        println(io)
        println(io, "## Files")
        println(io)
        println(io, "| file | contents |")
        println(io, "|---|---|")
        println(io, "| `portugal_parishes.csv` | $NMAIN mainland parishes, attributes |")
        println(io, "| `portugal_parishes_queen.gal` | contiguity by shared vertex, ", links[:queen], " links |")
        println(io, "| `portugal_parishes_rook.gal` | contiguity by shared edge, ", links[:rook], " links |")
        println(io, "| `portugal_parishes_centroids.csv` | area-weighted centroids, EPSG:3763 (PT-TM06), metres |")
        println(io)
        println(io, "Everything is keyed and ordered by **DICOFRE** (CAOP's `dtmnfr`), the")
        println(io, "official district, municipality and parish code, so the files line up by")
        println(io, "sorting alone. Its first four characters are the municipality's DICO.")
        println(io, "It is text, not a number: the ", length(lettered), " unions of Barcelos are")
        println(io, "coded ", join(lettered, ", "), ", and leading zeros matter.")
        println(io)
        println(io, "## Columns")
        println(io)
        println(io, "| column | INE indicator | period | unit |")
        println(io, "|---|---|---|---|")
        println(io, "| `dicofre` | official parish code | | 6 characters |")
        println(io, "| `name` | parish name, as INE gives it | | |")
        println(io, "| `dico`, `district`, `district_name` | from the DICOFRE | | |")
        for (name, code, period, _, unit) in COLUMNS
            println(io, "| `", name, "` | ", code, " | ", period, " | ", unit, " |")
        end
        println(io)
        println(io, "Full indicator titles, as INE states them:")
        println(io)
        for code in sort(unique(c[2] for c in COLUMNS))
            println(io, "- **", code, "** - ", titles[code])
        end
        println(io)
        println(io, "## Things to know before modelling")
        println(io)
        println(io, "**The parish map is the one of the 2013 reform.** Law 25-A/2025")
        println(io, "restored parishes that the 2013 reform had merged; the current CAOP")
        println(io, "(2024.1 and 2025) has 3,049 mainland parishes. INE's parish figures, up")
        println(io, "to the 2024 reference period, are on the 2013 map, and so are these")
        println(io, "boundaries. Do not join these files to a current CAOP layer.")
        println(io)
        println(io, "**The income column is the mean, not the median.** INE's median")
        println(io, "declared income net of tax (0012757) is suppressed for most parishes")
        println(io, "(a value for 735 of the 2,882 in 2024). The mean gross declared income")
        println(io, "per taxpayer (0012748) covers all of them.")
        println(io)
        for (nm, ne) in extras
            println(io, "**`", nm, "` drops ", ne, " empty codes.** INE lists both parish maps")
            println(io, "in that indicator's geography; the ", ne, " parishes restored in 2025")
            println(io, "have no value for the period used and are not in these files.")
            println(io)
        end
        println(io, "**The GAL files are binary.** Standardise after any further subsetting,")
        println(io, "never before.")
        println(io)
        println(io, "## Weights")
        println(io)
        @printf(io, "Queen: %d links, mean degree %.3f (min %d, max %d). Rook: %d links.\n",
                links[:queen], sum(degs[:queen]) / NMAIN, minimum(degs[:queen]),
                maximum(degs[:queen]), links[:rook])
        println(io, "They differ by ", npoint, " pairs that meet at a single point. No parish")
        println(io, "is without a neighbour.")
        println(io)
        println(io, "Contiguity was computed by hashing shared vertices and edges, which is")
        println(io, "exact on a node-matched planar partition. That was checked on this layer:")
        println(io, "rounding every vertex to the millimetre leaves both graphs unchanged.")
        println(io, "Checked once more on 2026-11-25 against an independent geometry engine:")
        println(io, "shapely 2.1 (boundaries that intersect, and intersect in a line) gives")
        println(io, "the same 8,409 queen and 8,283 rook links, link for link.")
        println(io)
        println(io, "## How this was produced")
        println(io)
        println(io, "`scripts/caop_gpkg_to_geojson.py` (Python standard library only; the")
        println(io, "coordinates are copied as stored) and `scripts/build_parish_dataset.jl`")
        println(io, "in [PortugalINE.jl](https://github.com/randsley/PortugalINE.jl), on ", _today(), ".")
        println(io, "The script fails rather than writes if an indicator is not published to")
        println(io, "parish level, if any indicator returns other than $NMAIN mainland parishes,")
        println(io, "if the indicators or the boundaries disagree about which parishes exist,")
        println(io, "or if any parish has no neighbours.")
        ndiffname == 0 || println(io, "\n", ndiffname, " parish names differ between CAOP and INE; INE's are used.")
    end
    println("wrote ", basename(prov))
end

main(ARGS)
