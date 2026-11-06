#!/usr/bin/env julia
#
# Check this package against a dataset produced some other way, value by value.
#
#     julia --project=. scripts/verify_against_reference.jl <caop.json> <data-dir>
#
# Written to check layers 2 and 4 against the extract that
# scripts/build_spatial_dataset.py produced through pyptine, which is the
# dataset committed in SpatialEconometrics.jl under notebooks/data. Two
# independent routes to the same numbers is the only real evidence that either
# is right, and the unit tests cannot supply it: they run offline against six
# municipalities.
#
# It is not in CI. It needs the network and about 200 MB of CAOP GeoJSON, and
# INE revises published figures, so a failure here is as likely to be a
# revision as a regression -- which is itself worth knowing, and is why the
# reference period is pinned below rather than taken as the latest available.
#
# Result on 2026-11-06: identical. All five indicators across 308
# municipalities match to the last published digit, every name agrees, the 278
# mainland DICOs match in the same order, and the queen graph is the same 739
# links.
#
# Two checks:
#
#   A. Layer 2 alone, all 308 municipalities x 5 indicators, against the CSV.
#      No boundaries needed, so this isolates the API client.
#   B. The full layer 4 join over the real CAOP, against the CSV's mainland
#      rows and against the committed queen GAL file.
#

using PortugalINE
using Printf

length(ARGS) >= 2 || error(
    "usage: verify_against_reference.jl <caop.json> <reference-data-dir>\n" *
    "  <reference-data-dir> holds portugal_municipalities.csv and " *
    "portugal_municipalities_queen.gal")

const CAOP = ARGS[1]
const REF = ARGS[2]
const CSV_PATH = joinpath(REF, "portugal_municipalities.csv")
const GAL_PATH = joinpath(REF, "portugal_municipalities_queen.gal")

const COLUMNS = [
    :purchasing_power  => "0014580",
    :pp_share_national => "0014581",
    :pp_dynamism       => "0014582",
    :density           => "0013189",
    :ageing_ratio      => "0012909",
]

# ---------------------------------------------------------------------------
# the committed CSV
# ---------------------------------------------------------------------------

function read_reference(path)
    lines = readlines(path)
    hdr = split(lines[1], ',')
    rows = Dict{String, Dict{String, String}}()
    order = String[]
    for l in lines[2:end]
        isempty(strip(l)) && continue
        # No quoted fields in this file; assert that rather than assume it.
        @assert !occursin('"', l) "the reference CSV has a quoted field; the naive split is wrong"
        f = split(l, ',')
        @assert length(f) == length(hdr) "ragged row: $l"
        d = f[1]
        rows[d] = Dict(zip(hdr, f))
        push!(order, d)
    end
    return hdr, order, rows
end

hdr, ref_order, ref = read_reference(CSV_PATH)
println("reference CSV: ", length(ref_order), " rows, columns ", join(hdr, ", "))
mainland_ref = [d for d in ref_order if ref[d]["mainland"] == "true"]
println("  mainland rows: ", length(mainland_ref))

# The reference prints values with the precision INE publishes, so compare as
# parsed numbers and report the largest absolute difference rather than doing
# string equality, which would fail on "100" against "100.0".
parse_ref(d, c) = let s = ref[d][c]
    isempty(s) ? missing : parse(Float64, s)
end

# ---------------------------------------------------------------------------
# A. layer 2 alone
# ---------------------------------------------------------------------------

println("\n=== A. layer 2 against the CSV, all 308 municipalities ===")
extracts = Dict{Symbol, Any}()
failA = 0
for (name, code) in COLUMNS
    ind = indicator_metadata(code)
    pc = period_code(ind, "2023")
    d = indicator_data(code; period = pc)
    m = municipal_values(d)
    extracts[name] = (d, m)

    ours = Dict(m.dico .=> m.value)
    missing_here = setdiff(keys(ref), keys(ours))
    extra_here = setdiff(keys(ours), keys(ref))
    worst = 0.0; worst_at = ""
    bad = 0
    for d0 in ref_order
        want = parse_ref(d0, String(name))
        got = get(ours, d0, missing)
        if ismissing(want) || ismissing(got)
            ismissing(want) == ismissing(got) || (bad += 1)
            continue
        end
        e = abs(want - got)
        if e > worst
            worst = e; worst_at = d0
        end
        e > 1e-9 && (bad += 1)
    end
    @printf("  %-18s %s  period %-6s n=%3d  missing=%d extra=%d  mismatches=%d  max|diff|=%.3g%s\n",
            name, code, only(d.periods), length(m.dico), length(missing_here),
            length(extra_here), bad, worst,
            worst > 0 ? " at $worst_at" : "")
    global failA += bad + length(missing_here) + length(extra_here)
end
println(failA == 0 ? "  A: PASS -- every value identical" : "  A: FAIL ($failA)")

# Names, which the Python script also wrote.
nm = extracts[:purchasing_power][2]
namebad = [d for d in ref_order if nm.name[findfirst(==(d), nm.dico)] != ref[d]["name"]]
println("  names differing from the CSV: ", length(namebad),
        isempty(namebad) ? "" : " -> " * join(first(namebad, 5), ", "))

# ---------------------------------------------------------------------------
# B. the full join over real boundaries
# ---------------------------------------------------------------------------

println("\n=== B. layer 4 over the real CAOP ===")
b = read_caop_geojson(CAOP)
println("  CAOP: ", length(b), " municipalities")

specs = Pair{Symbol, Any}[name => (extracts[name][1], "2023") for (name, _) in COLUMNS]
ds = join_municipal(b, specs...; criterion = :queen)
show(stdout, MIME"text/plain"(), ds)

failB = 0
if length(ds) != length(mainland_ref)
    println("  !! row count ", length(ds), " != ", length(mainland_ref))
    failB += 1
end
if ds.dico != sort(mainland_ref)
    println("  !! DICO sets differ; symmetric difference: ",
            symdiff(ds.dico, mainland_ref))
    failB += 1
else
    println("  DICO set and order match the CSV's mainland rows exactly")
end

for (name, _) in COLUMNS
    col = ds.columns[name]
    local worst = 0.0; local bad = 0
    for i in eachindex(ds.dico)
        want = parse_ref(ds.dico[i], String(name)); got = col[i]
        (ismissing(want) || ismissing(got)) && continue
        e = abs(want - got); e > worst && (worst = e)
        e > 1e-9 && (bad += 1)
    end
    bad == 0 || println("  !! ", name, ": ", bad, " mismatches")
    global failB += bad
    @printf("  %-18s mismatches=%d  max|diff|=%.3g\n", name, bad, worst)
end

# The weights, against the committed GAL.
out = mktempdir()
files = write_dataset(out, ds; name = "verify")
ourgal = readlines(files[2])
refgal = readlines(GAL_PATH)

function gal_pairs(lines)
    s = Set{Tuple{String, String}}()
    i = 2
    while i < length(lines)
        id, k = split(lines[i])
        nb = parse(Int, k) == 0 ? String[] : split(lines[i + 1])
        for n in nb
            push!(s, (min(id, n), max(id, n)))
        end
        i += 2
    end
    return s
end

ours = gal_pairs(ourgal); theirs = gal_pairs(refgal)
println("\n  GAL: ours ", length(ours), " links, committed ", length(theirs), " links")
d1 = setdiff(ours, theirs); d2 = setdiff(theirs, ours)
if isempty(d1) && isempty(d2)
    println("  GAL: PASS -- identical contiguity graph")
else
    println("  !! only in ours:     ", collect(d1))
    println("  !! only in committed:", collect(d2))
    failB += length(d1) + length(d2)
end
println("  header ours=", ourgal[1], " committed=", refgal[1])

println("\n", failA == 0 && failB == 0 ?
        "VERIFIED: the Julia pipeline reproduces the committed dataset." :
        "DIFFERENCES FOUND: A=$failA B=$failB")
