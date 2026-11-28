"""
Panels: the same units over several periods, with one weights matrix.

A cross-section cannot tell a spatial lag from spatially correlated errors;
repeated observations of the same units can. [`join_panel`](@ref) builds that:
units present in the boundaries and in **every** indicator in **every**
period, a value matrix (units x periods) per indicator, and one contiguity
structure over the units. The geometry is fixed, so `W` is the same in every
period, and that only holds if the units are: a unit that exists in some
periods and not others is dropped, not carried with gaps in its geometry.

## Two parish maps

INE publishes its parish figures on the 2013 map, but some indicators list the
units of both maps: the area indicator 0011866 carries 3,184 mainland codes,
the 2,882 of 2013 and the 302 parishes restored in 2025, the latter with no
value before 2025. A unit with data and no boundary that holds **no value in
any period used** is a listing of the other map's units, not a coverage gap,
and is counted apart ([`dropped`](@ref)`(p).empty`) so the real gaps stand out.
A unit with a boundary and a value in the extract but missing from another
extract or period is a real gap, and is named.

## Missing values

Units are kept whatever their values; a suppressed cell stays `missing` in its
column. [`panel_matrices`](@ref) then keeps the units complete in every column
and period it is asked for, and rebuilds `W` over them, for the same reason
[`model_matrix`](@ref PortugalINE.Join.model_matrix) does: a standardised matrix is valid only for the units
it was computed over.
"""
module Panel

using SparseArrays
using Printf: @printf, @sprintf

using ..Codes: isisland
using ..Indicators: IndicatorData, _unit_values
using ..Boundaries: MunicipalBoundaries, contiguity, centroids, write_gal,
                    CAOP_ATTRIBUTION, _noun
using ..Join: _filter_text, _csv_field, _num

import ..Join: dropped, notes
import ..Indicators: ine_citation

export PanelDataset, join_panel, panel_matrices, write_panel

"""
    PanelDataset

Units by periods, aligned with one contiguity structure.

| field | what |
|---|---|
| `keys` | the unit codes (DICO or DICOFRE), sorted; the row order of every matrix |
| `names` | the unit names |
| `periods` | the period labels, in the order given; the column order of every matrix |
| `columns` | a `NamedTuple` of `Matrix{Union{Float64, Missing}}`, `length(keys)` x `length(periods)` |
| `boundaries` | the geometry, subset and reordered to `keys` |
| `adjacency` | **binary** contiguity in `keys` order |
| `criterion` | `:queen` or `:rook` |
| `varcds`, `filters`, `languages`, `column_extracted` | per column: the INE indicator, the dimension filter, the language, the earliest extraction timestamp of its extracts |

`dropped(p)` and `notes(p)` say what the join left out and why.
"""
struct PanelDataset
    keys::Vector{String}
    names::Vector{String}
    periods::Vector{String}
    columns::NamedTuple
    boundaries::MunicipalBoundaries
    adjacency::SparseMatrixCSC{Float64, Int}
    criterion::Symbol
    varcds::Vector{String}
    filters::Vector{Dict{Int, String}}
    languages::Vector{String}
    column_extracted::Vector{String}
    dropped_geometry::Vector{String}
    dropped_data::Vector{String}
    dropped_islands::Vector{String}
    dropped_empty::Vector{String}
    notes::Vector{String}
end

Base.length(p::PanelDataset) = length(p.keys)

"""
    dropped(p::PanelDataset) -> NamedTuple

What [`join_panel`](@ref) left out, as four vectors of codes: `geometry` (a
boundary missing from some indicator or period), `data` (values with no
boundary), `islands` (no boundary because the unit is in Madeira or the Azores)
and `empty` (listed in an extract with no value in any period used and no
boundary: the other parish map's units).
"""
dropped(p::PanelDataset) = (geometry = p.dropped_geometry, data = p.dropped_data,
                            islands = p.dropped_islands, empty = p.dropped_empty)

notes(p::PanelDataset) = p.notes

function Base.show(io::IO, ::MIME"text/plain", p::PanelDataset)
    deg = vec(sum(p.adjacency; dims = 2))
    println(io, "PanelDataset: ", length(p), " ", _noun(p.boundaries.level, length(p)),
            " x ", length(p.periods), " period", length(p.periods) == 1 ? "" : "s",
            " (", first(p.periods), "-", last(p.periods), "), ",
            length(p.columns), " indicator", length(p.columns) == 1 ? "" : "s")
    print(io, "  columns  ")
    for k in keys(p.columns)
        nm = count(ismissing, p.columns[k])
        print(io, " ", k, nm == 0 ? "" : "($(nm) missing)")
    end
    println(io)
    @printf(io, "  weights   %s contiguity, %d links, mean degree %.3f\n",
            p.criterion, Int(sum(deg)) ÷ 2, sum(deg) / length(p))
    if isempty(p.notes)
        println(io, "  notes     none")
    else
        println(io, "  notes")
        foreach(n -> println(io, "    - ", n), p.notes)
    end
end

Base.show(io::IO, p::PanelDataset) =
    print(io, "PanelDataset(", length(p), " x ", length(p.periods), ", ",
          length(p.columns), " indicators)")

# One column's extracts: a single IndicatorData or a vector of them, one
# indicator and one filter, each period held by exactly one extract.
function _column_sources(nm::Symbol, v)
    ds = v isa IndicatorData ? [v] :
         v isa AbstractVector && all(x -> x isa IndicatorData, v) && !isempty(v) ?
            collect(IndicatorData, v) :
         throw(ArgumentError(
             "the value of $(repr(nm)) must be an IndicatorData or a vector of them; " *
             "got $(typeof(v))."))
    length(unique(d.varcd for d in ds)) == 1 || throw(ArgumentError(
        "$(repr(nm)) mixes indicators $(join(unique(d.varcd for d in ds), ", ")); " *
        "a column holds one indicator."))
    length(unique(d.dimensions for d in ds)) == 1 || throw(ArgumentError(
        "$(repr(nm)) mixes dimension filters " *
        join(unique(_filter_text(d.dimensions) for d in ds), " and ") *
        "; a column holds one filter, or its periods would not be comparable."))
    return ds
end

function _extract_for(nm, ds, period)
    hits = [d for d in ds if period in d.periods]
    isempty(hits) && throw(ArgumentError(
        "no extract of $(repr(nm)) ($(ds[1].varcd)) covers period $(repr(period)); " *
        "they cover " * join(sort(unique(p for d in ds for p in d.periods)), ", ") * "."))
    length(hits) == 1 || throw(ArgumentError(
        "$(length(hits)) extracts of $(repr(nm)) cover period $(repr(period)); give each once."))
    return only(hits)
end

"""
    join_panel(b::MunicipalBoundaries, specs...; periods, criterion = :queen) -> PanelDataset

Join indicators over several `periods` (labels, such as `["2018", "2019"]`) to
boundaries, keeping the units present in the boundaries and in every indicator
in every period. Each `spec` is `:column_name => data`, where `data` is one
[`IndicatorData`](@ref) holding all the periods (an unfiltered request) or a
vector of them (one request per period). A column holds one indicator with one
dimension filter, so its periods are comparable.

```julia
b   = read_caop_geojson("caop2024_freguesias.json"; level = :parish, edition = "CAOP2024")
inc = indicator_data("0012748")                                # all periods
bir = indicator_data("0008234"; dimensions = Dict(3 => "T"))   # both sexes
p   = join_panel(b, :income => inc, :births => bir; periods = string.(2018:2023))
m   = panel_matrices(p, :births, :income)
```
"""
function join_panel(b::MunicipalBoundaries, specs::Pair...;
                    periods::AbstractVector, criterion::Symbol = :queen)
    isempty(specs) && throw(ArgumentError("join_panel needs at least one indicator."))
    isempty(periods) && throw(ArgumentError("join_panel needs at least one period."))
    criterion in (:queen, :rook) || throw(ArgumentError(
        "criterion must be :queen or :rook, got $(repr(criterion))."))
    pers = String.(periods)
    length(unique(pers)) == length(pers) || throw(ArgumentError("a period is given twice."))
    length(unique(b.codes)) == length(b.codes) || throw(ArgumentError(
        "the boundaries carry a repeated code, so they cannot be joined on it."))
    level = b.level
    keyname = level === :parish ? "DICOFRE" : "DICO"

    cols = Symbol[]; sources = Vector{IndicatorData}[]
    for s in specs
        nm = first(s)
        nm isa Symbol || throw(ArgumentError(
            "each indicator needs a Symbol column name, as `:births => data`; got $(repr(nm))."))
        nm in cols && throw(ArgumentError("column $(repr(nm)) was given twice."))
        push!(cols, nm); push!(sources, _column_sources(nm, last(s)))
    end

    # Reduce every (column, period) to its units, keyed by DICO or DICOFRE.
    slices = [[_unit_values(_extract_for(nm, ds, p), level; period = p) for p in pers]
              for (nm, ds) in zip(cols, sources)]

    bset = Set(b.codes)
    keep = copy(bset)
    for sc in slices, s in sc
        intersect!(keep, Set(s.key))
    end
    common = sort(collect(keep))
    isempty(common) && throw(ArgumentError(
        "no " * _noun(level, 1) * " is in the boundaries and in every indicator in every " *
        "period. The boundaries hold codes such as $(join(first(sort(b.codes), 3), ", "))."))

    note = String[]

    # Boundaries missing from some column or period.
    dropped_geom = String[]
    for (nm, sc) in zip(cols, slices), (p, s) in zip(pers, sc)
        gone = sort(setdiff(b.codes, s.key))
        isempty(gone) && continue
        union!(dropped_geom, gone)
        push!(note, string(length(gone), " ", _noun(level, length(gone)),
                           length(gone) == 1 ? " has" : " have", " boundaries but no ",
                           nm, " row in ", p, length(gone) <= 8 ? ": " * join(gone, ", ") : ""))
    end
    sort!(dropped_geom)

    # Data with no boundary: islands, the other map's empty listings, the rest.
    island = Dict{String, Bool}(); valued = Dict{String, Bool}()
    for sc in slices, s in sc, i in eachindex(s.key)
        k = s.key[i]
        k in bset && continue
        island[k] = get(island, k, false) || isisland(s.geocod[i])
        valued[k] = get(valued, k, false) || !ismissing(s.value[i])
    end
    nogeom = sort(collect(keys(island)))
    dropped_islands = [k for k in nogeom if island[k]]
    dropped_empty = [k for k in nogeom if !island[k] && !valued[k]]
    dropped_data = [k for k in nogeom if !island[k] && valued[k]]
    isempty(dropped_islands) || push!(note, string(length(dropped_islands), " island ",
        _noun(level, 2), " have data but no boundary, which is expected: CAOP serves ",
        "Madeira and the Azores separately and they have no land neighbours"))
    isempty(dropped_empty) || push!(note, string(length(dropped_empty), " ",
        _noun(level, length(dropped_empty)), " listed in the data have no value in any ",
        "period used and no boundary: units of another map (INE's area indicator ",
        "0011866 lists the 302 parishes restored in 2025 alongside the 2013 map)"))
    isempty(dropped_data) || push!(note, string(length(dropped_data), " non-island ",
        _noun(level, length(dropped_data)), length(dropped_data) == 1 ? " has" : " have",
        " values but no boundary", length(dropped_data) <= 8 ? ": " * join(dropped_data, ", ") : "",
        ". If the boundaries were meant to be the whole mainland, the boundary vintage ",
        "and the indicator's map disagree"))

    # The value matrices, and the names, which must agree across periods and
    # columns; a disagreement is counted, the first spelling kept.
    n = length(common); T = length(pers)
    mats = Any[]
    names = fill("", n)
    namediff = 0
    for sc in slices
        M = Matrix{Union{Float64, Missing}}(missing, n, T)
        for (t, s) in enumerate(sc)
            ix = Dict(s.key[i] => i for i in eachindex(s.key))
            for (r, k) in enumerate(common)
                i = ix[k]
                M[r, t] = s.value[i]
                if isempty(names[r])
                    names[r] = s.name[i]
                elseif s.name[i] != names[r]
                    namediff += 1
                end
            end
        end
        push!(mats, M)
    end
    namediff == 0 || push!(note, string(namediff, " (unit, column, period) name",
        namediff == 1 ? "" : "s", " differ from the first spelling, which is kept. The ",
        keyname, " join is unaffected"))

    pick = [findfirst(==(k), b.codes) for k in common]
    bsub = b[pick]
    A = contiguity(bsub; criterion, standardize = false)
    iso = [common[i] for i in 1:n if sum(A[i, :]) == 0]
    isempty(iso) || push!(note, string(length(iso), " unit", length(iso) == 1 ? "" : "s",
        " have no neighbours after the join",
        length(iso) <= 8 ? ": " * join(iso, ", ") : ""))

    return PanelDataset(common, names, pers, NamedTuple{Tuple(cols)}(Tuple(mats)),
                        bsub, A, criterion,
                        [ds[1].varcd for ds in sources],
                        [copy(ds[1].dimensions) for ds in sources],
                        [ds[1].language for ds in sources],
                        [minimum(d.extracted for d in ds) for ds in sources],
                        dropped_geom, dropped_data, dropped_islands, dropped_empty, note)
end

"""
    panel_matrices(p, y::Symbol, xs::Symbol...; periods = p.periods,
                   standardize = true, intercept = false)

What a spatial panel estimator needs: `(y, X, W, keys, periods, N, T, xnames,
dropped)`, over the units with a value in `y` and every `x` in every period
used.

`y` and the columns of `X` are stacked **period by period**: the first `N`
entries are period 1 for every unit in `keys` order, the next `N` period 2,
and so on, which is the order `kron(I(T), W)` multiplies. `W` is `N x N`,
rebuilt over the surviving units and row-standardised unless
`standardize = false`.
"""
function panel_matrices(p::PanelDataset, y::Symbol, xs::Symbol...;
                        periods::AbstractVector = p.periods,
                        standardize::Bool = true, intercept::Bool = false)
    for c in (y, xs...)
        haskey(p.columns, c) || throw(ArgumentError(
            "no column $(repr(c)) in this panel; it has " * join(keys(p.columns), ", ") * "."))
    end
    y in xs && throw(ArgumentError("$(repr(y)) is both the response and a regressor."))
    pers = String.(periods)
    tix = Int[]
    for q in pers
        t = findfirst(==(q), p.periods)
        t === nothing && throw(ArgumentError(
            "period $(repr(q)) is not in this panel; it has " * join(p.periods, ", ") * "."))
        push!(tix, t)
    end
    used = (y, xs...)
    keep = [i for i in eachindex(p.keys)
            if all(!ismissing(p.columns[c][i, t]) for c in used, t in tix)]
    isempty(keep) && throw(ArgumentError(
        "no unit has a value for all of " * join(used, ", ") * " in every period used."))
    gone = p.keys[setdiff(eachindex(p.keys), keep)]

    bsub = p.boundaries[keep]
    A = contiguity(bsub; criterion = p.criterion, standardize = false)
    deg = vec(sum(A; dims = 2))
    if standardize
        bad = [p.keys[keep[i]] for i in eachindex(deg) if deg[i] == 0]
        isempty(bad) || throw(ArgumentError(
            "dropping the $(length(gone)) incomplete unit(s) left $(length(bad)) with no " *
            "neighbours (" * join(first(bad, 8), ", ") * "), so W cannot be " *
            "row-standardised. Pass `standardize = false`, or choose other columns or periods."))
        W = A ./ deg
    else
        W = A
    end

    stack(c) = Float64[p.columns[c][i, t] for t in tix for i in keep]
    N = length(keep); T = length(tix)
    cs = Vector{Float64}[]; nms = String[]
    intercept && (push!(cs, ones(N * T)); push!(nms, "intercept"))
    for c in xs
        push!(cs, stack(c)); push!(nms, String(c))
    end
    X = isempty(cs) ? zeros(N * T, 0) : reduce(hcat, cs)
    return (y = stack(y), X = X, W = W, keys = p.keys[keep], periods = pers,
            N = N, T = T, xnames = nms, boundaries = bsub, dropped = gone)
end

"""
    ine_citation(p::PanelDataset) -> String

INE's required citation for the panel's indicators and periods, then DGT's
credit for the boundaries.
"""
function ine_citation(p::PanelDataset)
    vs = sort(unique(p.varcds))
    gone = [String(k) for (k, ex) in zip(keys(p.columns), p.column_extracted) if isempty(ex)]
    isempty(gone) || throw(ArgumentError("cannot cite the panel: no extraction date " *
        "recorded for column(s) $(join(gone, ", ")), and INE's citation needs one."))
    ex = minimum(p.column_extracted)
    return string("Source: Statistics Portugal (INE), indicator",
                  length(vs) == 1 ? " " : "s ", join(vs, ", "),
                  ", reference periods ", first(p.periods), " to ", last(p.periods),
                  ", extracted ", first(ex, 10), ". ", CAOP_ATTRIBUTION)
end

_today() = Base.Libc.strftime("%Y-%m-%d", time())

"""
    write_panel(dir, p; name = "panel", gal = true, centroids_file = true,
                coordinate_names = ("lon", "lat")) -> Vector{String}

Write the panel as **long** CSV, one row per unit and period, ordered by period
and then by key (the stacking [`panel_matrices`](@ref) uses), plus the GAL file,
the centroids and a provenance file. The GAL and centroid files have one row
per unit, in key order, because the geometry does not change between periods.
"""
function write_panel(dir::AbstractString, p::PanelDataset;
                     name::AbstractString = "panel", gal::Bool = true,
                     centroids_file::Bool = true,
                     coordinate_names::Tuple{String, String} = ("lon", "lat"))
    mkpath(dir)
    written = String[]
    par = p.boundaries.level === :parish
    keyname = par ? "dicofre" : "dico"

    csv = joinpath(dir, name * ".csv")
    open(csv, "w") do io
        println(io, keyname, ",name,period,", join(keys(p.columns), ","))
        for (t, per) in enumerate(p.periods), i in eachindex(p.keys)
            print(io, p.keys[i], ",", _csv_field(p.names[i]), ",", per)
            for k in keys(p.columns)
                print(io, ",", _num(p.columns[k][i, t]))
            end
            println(io)
        end
    end
    push!(written, csv)

    if gal
        g = joinpath(dir, string(name, "_", p.criterion, ".gal"))
        write_gal(g, p.boundaries; criterion = p.criterion)
        push!(written, g)
    end
    if centroids_file
        C = centroids(p.boundaries)
        c = joinpath(dir, name * "_centroids.csv")
        open(c, "w") do io
            println(io, keyname, ",name,", coordinate_names[1], ",", coordinate_names[2])
            for i in eachindex(p.keys)
                @printf(io, "%s,%s,%.6f,%.6f\n", p.keys[i], _csv_field(p.names[i]), C[i, 1], C[i, 2])
            end
        end
        push!(written, c)
    end

    prov = joinpath(dir, name * "_PROVENANCE.md")
    deg = vec(sum(p.adjacency; dims = 2))
    open(prov, "w") do io
        println(io, "# ", name, ": provenance and attribution")
        println(io)
        println(io, "> ", ine_citation(p))
        println(io)
        println(io, "INE data is open for reuse, commercial and otherwise, under EU Directive")
        println(io, "2019/1024. INE retains copyright, and the one condition is that the source")
        println(io, "be cited. CAOP is CC-BY-4.0 and the credit above is a condition of that")
        println(io, "licence. Keep both with any published result.")
        println(io)
        println(io, "Written ", _today(), " by `write_panel` in PortugalINE.jl.")
        println(io)
        println(io, "## Units and periods")
        println(io)
        println(io, "**", length(p), " ", _noun(p.boundaries.level, length(p)), " x ",
                length(p.periods), " periods** (", join(p.periods, ", "), "), keyed by ",
                uppercase(keyname), ". The CSV is long: one row per unit and period, ",
                "ordered by period and then by ", uppercase(keyname), ". The same units are ",
                "present in every period, so one weights matrix serves them all.")
        println(io)
        d = dropped(p)
        println(io, "| dropped | count |")
        println(io, "|---|---|")
        println(io, "| boundaries missing from some indicator or period | ", length(d.geometry), " |")
        println(io, "| island units with no boundary | ", length(d.islands), " |")
        println(io, "| units of another map (no value, no boundary) | ", length(d.empty), " |")
        println(io, "| other units with values and no boundary | ", length(d.data), " |")
        println(io)
        println(io, "## Columns")
        println(io)
        println(io, "| column | INE indicator | filter | language | extracted | missing (of ",
                length(p) * length(p.periods), ") |")
        println(io, "|---|---|---|---|---|---|")
        for (j, k) in enumerate(keys(p.columns))
            ex = p.column_extracted[j]
            println(io, "| `", k, "` | ", p.varcds[j], " | ", _filter_text(p.filters[j]),
                    " | ", isempty(p.languages[j]) ? "not recorded" : p.languages[j],
                    " | ", isempty(ex) ? "not recorded" : first(ex, 10),
                    " | ", count(ismissing, p.columns[k]), " |")
        end
        println(io)
        println(io, "## Boundaries")
        println(io)
        bd = p.boundaries
        println(io, "| | |")
        println(io, "|---|---|")
        println(io, "| CAOP edition | ", isempty(bd.edition) ? "not stated" : bd.edition, " |")
        println(io, "| file | ", isempty(bd.source) ? "not recorded" : "`" * bd.source * "`", " |")
        println(io, "| SHA-256 | ", isempty(bd.sha256) ? "not recorded" : "`" * bd.sha256 * "`", " |")
        println(io)
        println(io, "## Weights")
        println(io)
        println(io, p.criterion == :queen ? "Queen contiguity: a shared vertex is enough." :
                                            "Rook contiguity: a shared edge is required.")
        println(io, "**", Int(sum(deg)) ÷ 2, " links**, mean degree ",
                @sprintf("%.3f", sum(deg) / length(p)), ", minimum ", Int(minimum(deg)),
                ", maximum ", Int(maximum(deg)), ". The GAL file is binary and not")
        println(io, "row-standardised: standardise after any further subsetting, never before.")
        if !isempty(p.notes)
            println(io)
            println(io, "## What the join noticed")
            println(io)
            foreach(n -> println(io, "- ", n), p.notes)
        end
    end
    push!(written, prov)
    return written
end

end # module
