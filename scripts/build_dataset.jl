#!/usr/bin/env julia
#
# Build a municipal spatial dataset end to end, in Julia: indicators from INE,
# boundaries from DGT, joined on DICO, written out as CSV plus GAL plus a
# provenance file.
#
#     julia --project=. scripts/build_dataset.jl <output-dir> [caop.json]
#
# With no second argument the boundaries are downloaded from DGT's OGC API,
# which is about 200 MB of GeoJSON, so pass a local copy when iterating.
#
# This replaces `scripts/build_spatial_dataset.py`, the pyptine-based interim
# that produced the first extract before layer 2 existed. That script is kept
# for comparison, not because anything still needs it.

using PortugalINE
using Printf

const CAOP_URL = "https://ogcapi.dgterritorio.gov.pt/collections/municipios/items?f=json&limit=400"

# Each entry is a column name, the INE indicator, and what it measures. All
# five are published down to Município, which `ismunicipal` confirms from the
# catalogue without a request per indicator.
const INDICATORS = [
    :purchasing_power  => "0014580",   # per capita purchasing power
    :pp_share_national => "0014581",   # its share of the national total
    :pp_dynamism       => "0014582",   # the purchasing-power dynamism factor
    :density           => "0013189",   # population density
    :ageing_ratio      => "0012909",   # ageing ratio, NUTS 2024
]

function fetch_caop(dest::AbstractString)
    @info "downloading CAOP mainland municipalities (about 200 MB)" CAOP_URL
    run(`curl -sS --max-time 900 $CAOP_URL -o $dest`)
    return dest
end

function main(args)
    isempty(args) && error("usage: build_dataset.jl <output-dir> [caop.json]")
    outdir = abspath(args[1])

    # Check coverage before fetching anything: the catalogue states each
    # indicator's finest geography, so an indicator that stops at NUTS III is
    # caught here rather than after a download that cannot be used. 0013351,
    # the ageing ratio on NUTS 2013, is exactly that trap -- it returns 39 rows
    # and no municipality, which is why 0012909 is in the list above.
    @info "checking municipal coverage against the catalogue"
    cat = catalogue()
    by = Dict(e.varcd => e for e in cat)
    for (name, code) in INDICATORS
        e = get(by, code, nothing)
        if e === nothing
            @warn "not in the main-group catalogue; coverage unverified" name code
            continue
        end
        ismunicipal(e) || error(
            "indicator $code ($name) is published only to $(e.geo_lastlevel), " *
            "so it cannot carry a municipal W. Pick another indicator.")
        @printf("  %-18s %s  %-10s %s\n", name, code, e.geo_lastlevel, e.title)
    end

    @info "fetching indicators"
    specs = Pair{Symbol, Any}[]
    for (name, code) in INDICATORS
        ind = indicator_metadata(code)
        per = ind.dimensions[1].categories[end]          # the latest period
        d = indicator_data(code; period = per.code)
        @printf("  %-18s %s  period %-8s %d rows\n", name, code, per.label, length(d))
        push!(specs, name => (d, per.label))
    end

    src = length(args) >= 2 ? args[2] :
          fetch_caop(joinpath(tempdir(), "caop_municipios.json"))
    b = read_caop_geojson(src)
    length(b) == 278 || error(
        "expected the 278 mainland municipalities, read $(length(b)). The " *
        "islands are a separate CAOP collection and have no land neighbours, " *
        "so they must not be mixed in here.")

    ds = join_municipal(b, specs...; criterion = :queen)
    println()
    show(stdout, MIME"text/plain"(), ds)
    println()

    # The periods are not all the same -- INE publishes these on different
    # cycles -- so say so rather than letting a reader assume one year.
    if length(unique(ds.periods)) > 1
        @warn "the columns are not all the same reference period" ds.periods
    end

    files = write_dataset(outdir, ds)
    println()
    for f in files
        println("wrote ", f)
    end
    println()
    println(ine_citation(ds))
end

main(ARGS)
