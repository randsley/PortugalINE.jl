"""
Joining indicators to geometry, which is where the two halves of this package
meet and where the errors are silent.

[`join_municipal`](@ref) takes a [`MunicipalBoundaries`](@ref) and one or more
[`IndicatorData`](@ref) extracts and returns a [`MunicipalDataset`](@ref): one
row per municipality present in *all* of them, in DICO order, with a contiguity
matrix built over exactly those units and nothing else.

## Why the key is the DICO, measured

Indicator 0014580 is published on NUTS 2024 and 0008074 on NUTS 2013. Both
carry all 308 municipalities. Joining them:

| key | matches |
|---|---|
| NUTS code (`geocod`) | **132 of 308** |
| name (`geodsg`) | 305 of 308 |
| DICO | **308 of 308** |

Lisboa is `1A01106` under NUTS 2024 and `1701106` under NUTS 2013, so a join on
the code INE returns as its primary identifier loses 57% of the country without
raising anything. A join on name is worse than its 305 suggests: the three
mismatches are `Calheta (R.A.M.)` against `Calheta` and two like it, and
`Calheta` is *two different municipalities* — 3101 in Madeira and 4501 in the
Azores — so a name join is ambiguous rather than merely incomplete.

The DICO is the last four characters of either code, and it is stable because
it is the official district-and-municipality number rather than a statistical
grouping. [`municipal_values`](@ref) keys on it, this layer joins on it, and
the GAL files from [`write_gal`](@ref) are ordered by it, so the data and the
matrix line up without a lookup table.

## Why the matrix is rebuilt and not sliced

Dropping a unit changes its neighbours' degrees, so a row-standardised `W` from
the full set is wrong for any subset of it: the surviving rows no longer sum to
one. Everything here therefore carries **binary** adjacency and standardises
last — [`spatial_weights`](@ref) on the dataset, and
[`model_matrix`](@ref) again after dropping incomplete cases. A unit left with
no neighbours is named in the error rather than divided by zero.

## The islands

The 30 island municipalities have data and no land neighbours. CAOP serves the
mainland as its own collection, so the usual join silently settles on 278
units — which is the right answer and the wrong way to reach it. Every unit
dropped is recorded on the dataset, and the ones dropped for being islands are
counted separately from the ones dropped for anything else, because the second
kind means a vintage or coverage problem and the first does not.
"""
module Join

using SparseArrays
using Printf: @sprintf, @printf

using ..Codes: isisland
using ..Indicators: IndicatorData, municipal_values
using ..Boundaries: MunicipalBoundaries, contiguity, neighbour_lists, centroids,
                    write_gal, CAOP_ATTRIBUTION

import ..Indicators: ine_citation

export MunicipalDataset, join_municipal, spatial_weights, model_matrix,
       write_dataset, dropped, notes

"""
    MunicipalDataset

One row per municipality, aligned with a contiguity structure over exactly
those municipalities.

| field | what |
|---|---|
| `dico` | the join key, sorted; the row order of everything else |
| `name` | the municipality name |
| `columns` | a `NamedTuple` of one `Vector{Union{Float64, Missing}}` per indicator |
| `nuts` | a `NamedTuple` of the NUTS codes each indicator supplied, as a vintage record |
| `boundaries` | the geometry, subset and reordered to match `dico` |
| `adjacency` | **binary** contiguity in `dico` order; standardise with [`spatial_weights`](@ref) |
| `criterion` | `:queen` or `:rook`, as built |
| `varcds`, `periods` | the INE code and reference period **per column, in column order** |
| `extracted` | the earliest extraction timestamp among the sources |

`columns` and `nuts` are `NamedTuple`s of equal-length vectors, so each is
already a valid Tables.jl column table. `adjacency` is deliberately not
row-standardised; see this module's documentation for why.
"""
struct MunicipalDataset
    dico::Vector{String}
    name::Vector{String}
    columns::NamedTuple
    nuts::NamedTuple
    boundaries::MunicipalBoundaries
    adjacency::SparseMatrixCSC{Float64, Int}
    criterion::Symbol
    # varcds and periods are parallel to `columns`, one entry per column, and
    # deliberately not deduplicated: the provenance table in `write_dataset`
    # pairs them with the column names positionally, and a sorted unique list
    # silently attributes the wrong indicator to a column.
    varcds::Vector{String}
    periods::Vector{String}
    extracted::String
    dropped_geometry::Vector{String}
    dropped_data::Vector{String}
    dropped_islands::Vector{String}
    notes::Vector{String}
end

Base.length(ds::MunicipalDataset) = length(ds.dico)

"""
    dropped(ds) -> NamedTuple

What the join left out, as three vectors of DICO codes: `geometry` (a boundary
with no data in some indicator), `data` (data with no boundary, excluding
islands) and `islands` (data with no boundary because the unit is in Madeira or
the Azores, which CAOP serves as separate collections).

The split matters. Islands dropping out is expected and is not a fault. A
mainland municipality dropping out means the extracts disagree about what
exists, which is a vintage or coverage problem worth looking at before the
estimates are believed.
"""
dropped(ds::MunicipalDataset) = (geometry = ds.dropped_geometry,
                                 data = ds.dropped_data,
                                 islands = ds.dropped_islands)

"""
    notes(ds) -> Vector{String}

Everything the join noticed and did not treat as fatal, in the order it was
noticed: units dropped and why, names the indicators disagreed on, NUTS
vintages that differ between extracts, and units left without neighbours.
Printed by `show`, and worth reading before the first regression.
"""
notes(ds::MunicipalDataset) = ds.notes

function Base.show(io::IO, ::MIME"text/plain", ds::MunicipalDataset)
    deg = vec(sum(ds.adjacency; dims = 2))
    println(io, "MunicipalDataset: ", length(ds), " municipalities, ",
            length(ds.columns), " indicator",
            length(ds.columns) == 1 ? "" : "s")
    println(io, "  key       dico, sorted; rows match `adjacency` and `boundaries`")
    print(io, "  columns  ")
    for k in keys(ds.columns)
        nm = count(ismissing, ds.columns[k])
        print(io, " ", k, nm == 0 ? "" : "($(nm) missing)")
    end
    println(io)
    @printf(io, "  %-9s %s contiguity, %d links, mean degree %.3f, min %d, max %d\n",
            "weights", ds.criterion, Int(sum(deg)) ÷ 2, sum(deg) / length(ds),
            Int(minimum(deg)), Int(maximum(deg)))
    println(io, "  provenance INE ", join(unique(ds.varcds), ", "), "; period",
            length(unique(ds.periods)) == 1 ? " " : "s ",
            join(sort(unique(ds.periods)), ", "))
    if isempty(ds.notes)
        println(io, "  notes      none")
    else
        println(io, "  notes")
        for n in ds.notes
            println(io, "    - ", n)
        end
    end
end

Base.show(io::IO, ds::MunicipalDataset) =
    print(io, "MunicipalDataset(", length(ds), " municipalities, ",
          length(ds.columns), " indicators, ", ds.criterion, ")")

# A spec is `:name => data` or `:name => (data, period)`. The resolved period
# comes back with it, because an extract covering several periods is reduced to
# one here and recording all of them would overstate what the column holds.
function _reduce_spec(spec::Pair)
    nm = first(spec)
    nm isa Symbol || throw(ArgumentError(
        "each indicator needs a Symbol column name, as `:density => data`; " *
        "got $(repr(nm))."))
    v = last(spec)
    if v isa IndicatorData
        length(v.periods) == 1 || throw(ArgumentError(
            "$(repr(nm)) covers $(length(v.periods)) periods " *
            "($(join(v.periods, ", "))); give it as " *
            "`$(repr(nm)) => (data, period)` so the column records which one " *
            "it holds."))
        return nm, v, only(v.periods), municipal_values(v)
    elseif v isa Tuple{IndicatorData, Any}
        return nm, v[1], String(v[2]), municipal_values(v[1]; period = v[2])
    else
        throw(ArgumentError(
            "the value of $(repr(nm)) must be an IndicatorData, or a tuple " *
            "(data, period) when the extract covers more than one period; " *
            "got $(typeof(v))."))
    end
end

"""
    join_municipal(b::MunicipalBoundaries, specs...; criterion = :queen)

Join one or more indicator extracts to boundaries on DICO, and build a
contiguity structure over the municipalities present in all of them.

Each `spec` is `:column_name => data`, or `:column_name => (data, period)` when
the extract covers more than one period.

```julia
b  = read_caop_geojson("caop_municipios.json")
pp = indicator_data("0014580"; period = "2023")
de = indicator_data("0013189"; period = "2023")
ds = join_municipal(b, :purchasing_power => pp, :density => de)

W = spatial_weights(ds)                       # row-standardised
m = model_matrix(ds, :purchasing_power, :density)
```

The result is an inner join: a municipality missing from any one extract is
dropped from all of them, so every column has the same length and the same
meaning per row. What was dropped is kept — see [`dropped`](@ref) — and
anything the join noticed but did not treat as fatal is in [`notes`](@ref).
"""
function join_municipal(b::MunicipalBoundaries, specs::Pair...;
                        criterion::Symbol = :queen)
    isempty(specs) && throw(ArgumentError(
        "join_municipal needs at least one indicator, as `:name => data`."))
    criterion in (:queen, :rook) || throw(ArgumentError(
        "criterion must be :queen or :rook, got $(repr(criterion))."))

    cols = Symbol[]; sources = IndicatorData[]; pers = String[]; reduced = []
    for s in specs
        nm, data, per, m = _reduce_spec(s)
        nm in cols && throw(ArgumentError(
            "column $(repr(nm)) was given twice."))
        push!(cols, nm); push!(sources, data); push!(pers, per); push!(reduced, m)
    end

    note = String[]

    # The boundaries' own codes are the DICO: CAOP's `dtmn` property is the
    # same four-digit district-and-municipality number. That is what makes the
    # join direct rather than a lookup.
    bcodes = b.codes
    length(unique(bcodes)) == length(bcodes) || throw(ArgumentError(
        "the boundaries carry a repeated code, so they cannot be joined on " *
        "it. Read them once with `read_caop_geojson` rather than concatenating."))

    keep = Set(bcodes)
    for m in reduced
        intersect!(keep, Set(m.dico))
    end
    common = sort(collect(keep))
    isempty(common) && throw(ArgumentError(
        "no municipality is present in both the boundaries and every " *
        "indicator. The boundaries hold $(length(bcodes)) codes such as " *
        "$(join(first(sort(bcodes), 3), ", ")) and the first indicator holds " *
        "$(length(reduced[1].dico)) such as " *
        "$(join(first(reduced[1].dico, 3), ", ")). If one set is DICO and the " *
        "other is a NUTS code, that is the mismatch."))

    # Boundaries with no data, per indicator, named while the list is short
    # enough to act on.
    dropped_geom = String[]
    for (nm, m) in zip(cols, reduced)
        gone = sort(setdiff(bcodes, m.dico))
        isempty(gone) && continue
        union!(dropped_geom, gone)
        push!(note, string(length(gone), " municipalit",
                           length(gone) == 1 ? "y has" : "ies have",
                           " boundaries but no ", nm, " value",
                           length(gone) <= 8 ? ": " * join(gone, ", ") : ""))
    end
    sort!(dropped_geom)

    # Data with no boundary, with the islands counted apart: islands are
    # expected, anything else is not.
    datacodes = sort(unique(reduce(vcat, [m.dico for m in reduced])))
    nogeom = sort(setdiff(datacodes, bcodes))
    island_lookup = Dict{String, Bool}()
    for m in reduced, i in eachindex(m.dico)
        island_lookup[m.dico[i]] = get(island_lookup, m.dico[i], false) ||
                                   isisland(m.geocod[i])
    end
    dropped_islands = [d for d in nogeom if get(island_lookup, d, false)]
    dropped_data = [d for d in nogeom if !get(island_lookup, d, false)]
    if !isempty(dropped_islands)
        push!(note, string(length(dropped_islands),
                           " island municipalities have data but no boundary, ",
                           "which is expected: CAOP serves Madeira and the ",
                           "Azores as separate collections and they have no ",
                           "land neighbours in any case"))
    end
    if !isempty(dropped_data)
        push!(note, string(length(dropped_data), " non-island municipalit",
                           length(dropped_data) == 1 ? "y has" : "ies have",
                           " data but no boundary",
                           length(dropped_data) <= 8 ? ": " * join(dropped_data, ", ") : "",
                           ". Expected if the boundaries are a deliberate ",
                           "subset; if they were meant to be the whole ",
                           "mainland then the boundary vintage and the ",
                           "indicator's geography version disagree about ",
                           "what exists"))
    end

    # Index each source once.
    idx = [Dict(m.dico[i] => i for i in eachindex(m.dico)) for m in reduced]

    values = Any[]; nutscols = Any[]
    for (m, ix) in zip(reduced, idx)
        push!(values, Union{Float64, Missing}[m.value[ix[d]] for d in common])
        push!(nutscols, String[m.geocod[ix[d]] for d in common])
    end

    # Names, taken from the first indicator and cross-checked against the rest.
    # A disagreement here is the reason a name is not the key: the island
    # municipalities carry a disambiguating "(R.A.M.)" or "(R.A.A.)" in some
    # indicators and not others, and without it `Calheta` names two different
    # places.
    names = String[reduced[1].name[idx[1][d]] for d in common]
    for (nm, m, ix) in zip(cols[2:end], reduced[2:end], idx[2:end])
        diff = [d for d in common if m.name[ix[d]] != names[searchsortedfirst(common, d)]]
        isempty(diff) && continue
        push!(note, string(length(diff), " name",
                           length(diff) == 1 ? "" : "s",
                           " differ between the first indicator and ", nm,
                           length(diff) <= 6 ?
                               ": " * join((string(d, " ",
                                   repr(names[searchsortedfirst(common, d)]),
                                   " vs ", repr(m.name[ix[d]])) for d in diff), "; ") :
                               "",
                           ". The DICO join is unaffected; a name join would not be"))
    end

    # NUTS vintages. Two extracts giving different codes for the same
    # municipality is the whole argument for keying on the DICO, so say so with
    # the count rather than leaving it to be rediscovered.
    for i in 2:length(nutscols)
        same = count(j -> nutscols[i][j] == nutscols[1][j], eachindex(common))
        same == length(common) && continue
        push!(note, string(cols[i], " reports a different NUTS code from ",
                           cols[1], " for ", length(common) - same, " of ",
                           length(common), " municipalities, so the two were ",
                           "published on different NUTS vintages. The DICO ",
                           "join matched all ", length(common),
                           "; a join on the NUTS code would have matched ",
                           same))
    end

    # Subset and reorder the geometry to the join, then build adjacency over
    # exactly those units.
    bi = Dict(bcodes[i] => i for i in eachindex(bcodes))
    pick = [bi[d] for d in common]
    bsub = MunicipalBoundaries(b.codes[pick], b.names[pick], b.rings[pick])
    A = contiguity(bsub; criterion, standardize = false)

    deg = vec(sum(A; dims = 2))
    iso = [common[i] for i in eachindex(common) if deg[i] == 0]
    if !isempty(iso)
        push!(note, string(length(iso), " unit",
                           length(iso) == 1 ? "" : "s",
                           " have no neighbours after the join",
                           length(iso) <= 8 ? ": " * join(iso, ", ") : "",
                           ". Row-standardising would divide by zero, so ",
                           "`spatial_weights` refuses it; use a k-nearest ",
                           "weighting or drop them deliberately"))
    end

    return MunicipalDataset(common, names,
                            NamedTuple{Tuple(cols)}(Tuple(values)),
                            NamedTuple{Tuple(cols)}(Tuple(nutscols)),
                            bsub, A, criterion,
                            [s.varcd for s in sources], pers,
                            minimum(s.extracted for s in sources),
                            dropped_geom, dropped_data, dropped_islands, note)
end

"""
    spatial_weights(ds; standardize = true) -> SparseMatrixCSC

The contiguity matrix over the dataset's municipalities, row-standardised by
default.

Standardising happens here rather than when the dataset was built, because
dropping a unit changes its neighbours' degrees: a standardised matrix is only
valid for the exact set of units it was computed over.
"""
function spatial_weights(ds::MunicipalDataset; standardize::Bool = true)
    standardize || return copy(ds.adjacency)
    deg = vec(sum(ds.adjacency; dims = 2))
    bad = [ds.dico[i] for i in eachindex(deg) if deg[i] == 0]
    isempty(bad) || throw(ArgumentError(
        "cannot row-standardise: " * string(length(bad)) *
        " unit(s) have no neighbours (" * join(first(bad, 8), ", ") *
        "). Pass `standardize = false`, or use a weighting that gives every " *
        "unit neighbours."))
    return ds.adjacency ./ deg
end

"""
    model_matrix(ds, y::Symbol, xs::Symbol...; standardize = true, intercept = false)

Everything an estimator needs, over the rows where `y` and every `x` are all
present: `(y, X, W, dico, xnames, dropped)`.

`W` is rebuilt over the surviving rows, not sliced out of the dataset's matrix,
because a row-standardised matrix is only valid for the units it was computed
over. If dropping incomplete cases leaves a unit with no neighbours, that is an
error naming the unit rather than a division by zero.

```julia
m = model_matrix(ds, :purchasing_power, :log_density, :ageing)
fit_spatial(SAR(), m.W, m.X, m.y)
```
"""
function model_matrix(ds::MunicipalDataset, y::Symbol, xs::Symbol...;
                      standardize::Bool = true, intercept::Bool = false)
    for c in (y, xs...)
        haskey(ds.columns, c) || throw(ArgumentError(
            "no column $(repr(c)) in this dataset; it has " *
            join(keys(ds.columns), ", ") * "."))
    end
    y in xs && throw(ArgumentError(
        "$(repr(y)) is both the response and a regressor."))

    used = (y, xs...)
    keep = [i for i in eachindex(ds.dico)
            if all(!ismissing(ds.columns[c][i]) for c in used)]
    isempty(keep) && throw(ArgumentError(
        "no municipality has a value for all of " * join(used, ", ") * "."))
    gone = ds.dico[setdiff(eachindex(ds.dico), keep)]

    bsub = MunicipalBoundaries(ds.boundaries.codes[keep],
                               ds.boundaries.names[keep],
                               ds.boundaries.rings[keep])
    A = contiguity(bsub; criterion = ds.criterion, standardize = false)
    deg = vec(sum(A; dims = 2))
    if standardize
        bad = [ds.dico[keep[i]] for i in eachindex(deg) if deg[i] == 0]
        isempty(bad) || throw(ArgumentError(
            "dropping the " * string(length(gone)) *
            " incomplete row(s) left " * string(length(bad)) *
            " unit(s) with no neighbours (" * join(first(bad, 8), ", ") *
            "), so the matrix cannot be row-standardised. Impute, or pass " *
            "`standardize = false`, or use a k-nearest weighting."))
        W = A ./ deg
    else
        W = A
    end

    yv = Float64[ds.columns[y][i] for i in keep]
    cs = Vector{Float64}[]
    nms = String[]
    if intercept
        push!(cs, ones(length(keep))); push!(nms, "intercept")
    end
    for c in xs
        push!(cs, Float64[ds.columns[c][i] for i in keep]); push!(nms, String(c))
    end
    X = isempty(cs) ? zeros(length(keep), 0) : reduce(hcat, cs)

    return (y = yv, X = X, W = W, dico = ds.dico[keep], xnames = nms,
            boundaries = bsub, dropped = gone)
end

"""
    ine_citation(ds::MunicipalDataset) -> String

The citation INE's reuse terms require for the indicators in this dataset,
followed by DGT's required credit for the boundaries, which is a condition of
CAOP's CC-BY-4.0 licence.
"""
function ine_citation(ds::MunicipalDataset)
    # Deduplicated for display: `varcds` and `periods` are per column, so two
    # columns drawn from one indicator must not cite it twice.
    vs = sort(unique(ds.varcds)); ps = sort(unique(ds.periods))
    return string("Source: Statistics Portugal (INE), indicator",
                  length(vs) == 1 ? " " : "s ", join(vs, ", "),
                  ", reference period", length(ps) == 1 ? " " : "s ",
                  join(ps, ", "), ", extracted ",
                  first(ds.extracted, 10), ". ", CAOP_ATTRIBUTION)
end

_today() = Base.Libc.strftime("%Y-%m-%d", time())

"""
    write_dataset(dir, ds; name = "portugal_municipalities", gal = true,
                  centroids_file = true) -> Vector{String}

Write the dataset out as the three files an analysis elsewhere actually needs,
and return their paths:

| file | contents |
|---|---|
| `<name>.csv` | `dico`, `name`, one column per indicator |
| `<name>_<criterion>.gal` | the contiguity structure, GeoDa GAL, in DICO order |
| `<name>_centroids.csv` | area-weighted centroids, for distance weightings |
| `<name>_PROVENANCE.md` | the citations, the counts, and every note from the join |

This is the handoff. GAL and CSV cross the gap as small text files that nothing
at the far end has to parse a polygon or hit a network to read, and because
both are ordered by DICO they line up by sorting alone. The provenance file is
written because INE's reuse condition and CAOP's licence both require a credit,
and a credit that lives only in a README travels badly.
"""
function write_dataset(dir::AbstractString, ds::MunicipalDataset;
                       name::AbstractString = "portugal_municipalities",
                       gal::Bool = true, centroids_file::Bool = true)
    mkpath(dir)
    written = String[]

    csv = joinpath(dir, name * ".csv")
    open(csv, "w") do io
        println(io, "dico,name,", join(keys(ds.columns), ","))
        for i in eachindex(ds.dico)
            print(io, ds.dico[i], ",", _csv_field(ds.name[i]))
            for k in keys(ds.columns)
                v = ds.columns[k][i]
                print(io, ",", ismissing(v) ? "" : string(v))
            end
            println(io)
        end
    end
    push!(written, csv)

    if gal
        g = joinpath(dir, string(name, "_", ds.criterion, ".gal"))
        write_gal(g, ds.boundaries; criterion = ds.criterion)
        push!(written, g)
    end

    if centroids_file
        C = centroids(ds.boundaries)
        c = joinpath(dir, name * "_centroids.csv")
        open(c, "w") do io
            println(io, "dico,name,lon,lat")
            for i in eachindex(ds.dico)
                @printf(io, "%s,%s,%.6f,%.6f\n", ds.dico[i],
                        _csv_field(ds.name[i]), C[i, 1], C[i, 2])
            end
        end
        push!(written, c)
    end

    prov = joinpath(dir, name * "_PROVENANCE.md")
    deg = vec(sum(ds.adjacency; dims = 2))
    open(prov, "w") do io
        println(io, "# ", name, ": provenance and attribution")
        println(io)
        println(io, "> ", ine_citation(ds))
        println(io)
        println(io, "INE data is open for reuse, commercial and otherwise, under")
        println(io, "EU Directive 2019/1024. INE retains copyright, and the one")
        println(io, "condition is that the source be cited. CAOP is CC-BY-4.0 and the")
        println(io, "credit above is a condition of that licence. Keep both with any")
        println(io, "published result.")
        println(io)
        println(io, "Written ", _today(), " by `write_dataset` in PortugalINE.jl.")
        println(io)
        println(io, "## Units")
        println(io)
        println(io, "**", length(ds), " municipalities**, keyed and ordered by DICO,")
        println(io, "the official district-and-municipality code. Every file here uses")
        println(io, "that order, so they line up by sorting alone.")
        println(io)
        println(io, "The key is the DICO and not INE's `geocod` because the NUTS code")
        println(io, "changes between vintages while the DICO does not, and not the name")
        println(io, "because `Calheta` names two municipalities, 3101 in Madeira and")
        println(io, "4501 in the Azores.")
        println(io)
        d = dropped(ds)
        println(io, "| dropped | count |")
        println(io, "|---|---|")
        println(io, "| boundaries with no indicator value | ", length(d.geometry), " |")
        println(io, "| island units with no boundary | ", length(d.islands), " |")
        println(io, "| other units with no boundary | ", length(d.data), " |")
        println(io)
        println(io, "## Columns")
        println(io)
        println(io, "| column | INE indicator | period | missing |")
        println(io, "|---|---|---|---|")
        for (j, k) in enumerate(keys(ds.columns))
            println(io, "| `", k, "` | ", ds.varcds[j], " | ", ds.periods[j],
                    " | ", count(ismissing, ds.columns[k]), " |")
        end
        println(io)
        println(io, "## Weights")
        println(io)
        println(io, ds.criterion == :queen ?
                "Queen contiguity: a shared vertex is enough." :
                "Rook contiguity: a shared edge is required.")
        println(io, "**", Int(sum(deg)) ÷ 2, " links**, mean degree ",
                @sprintf("%.3f", sum(deg) / length(ds)), ", minimum ",
                Int(minimum(deg)), ", maximum ", Int(maximum(deg)), ".")
        println(io)
        println(io, "The GAL file is **binary and not row-standardised**. Standardise")
        println(io, "after any further subsetting, never before: dropping a unit")
        println(io, "changes its neighbours' degrees, so a standardised matrix is only")
        println(io, "valid for the exact set of units it was computed over.")
        if !isempty(ds.notes)
            println(io)
            println(io, "## What the join noticed")
            println(io)
            for n in ds.notes
                println(io, "- ", n)
            end
        end
    end
    push!(written, prov)

    return written
end

# Minimal CSV quoting: municipality names carry commas in the disambiguated
# island forms, such as "Calheta (R.A.M.)" -- which do not, but the Azorean
# "Lagoa (R.A.A.)" style and any future rename might.
function _csv_field(s::AbstractString)
    needs = any(c -> c in (',', '"', '\n', '\r'), s)
    needs || return String(s)
    return string('"', replace(String(s), '"' => "\"\""), '"')
end

end # module
