"""
Municipal boundaries, and spatial weights built from them.

The boundaries come from **CAOP**, the Carta Administrativa Oficial de
Portugal, which Direção-Geral do Território publishes through an OGC API and
licenses **CC-BY-4.0** with public access unrestricted. Reuse requires the
credit DGT specifies; see [`CAOP_ATTRIBUTION`](@ref).

## Why there is no geometry dependency

Contiguity here is computed by hashing vertices and edges, not by intersecting
polygons, because CAOP is a **clean planar partition**: where two municipalities
share a border, both rings carry the *same* vertices, to the bit. That was
measured rather than assumed. Hashing exact `Float64` pairs and hashing
coordinates rounded to six decimals give the identical graph over the 278
mainland municipalities: 739 queen links, mean degree 5.32, no isolated unit.
If rounding had changed the answer the topology would have been dirty and a
geometry engine would have been needed; it did not, so GEOS, ArchGDAL and their
build chains are all avoidable, and reading a GeoJSON plus hashing tuples is
exact.

This holds for CAOP. It is not a general property of shapefiles, and
[`contiguity`](@ref) reports enough for a caller to check it on data of their
own: a planar partition that is *not* node-matched shows up as isolated units
or an implausibly thin graph.

## Queen and rook

**Queen** contiguity joins municipalities sharing at least one vertex; **rook**
requires a shared edge, meaning two consecutive vertices in common. On the
mainland the two differ by exactly **two pairs**, both meeting at a single
point: Mêda with Sernancelhe, and Lisboa with Vila Franca de Xira. The
distinction is usually taught in the abstract; on these data it is two named
pairs out of 739, which is worth knowing before treating the choice as
consequential.
"""
module Boundaries

using SparseArrays
using LinearAlgebra: Diagonal
using JSON3

using ..Codes: ismunicipality

export MunicipalBoundaries, CAOP_ATTRIBUTION,
       read_caop_geojson, contiguity, neighbour_lists, centroids,
       knn_contiguity, write_gal, ncounties

"""
    CAOP_ATTRIBUTION

The credit Direção-Geral do Território requires for any published use of CAOP,
adapted or not, under its CC-BY-4.0 licence. Carry it with anything built on
these boundaries.
"""
const CAOP_ATTRIBUTION =
    "Informação geográfica cedida pela Direção-Geral do Território " *
    "(CAOP, CC-BY-4.0, https://creativecommons.org/licenses/by/4.0/)"

const Ring = Vector{Tuple{Float64, Float64}}

"""
    MunicipalBoundaries

Polygon rings for a set of municipalities, with their DICO codes and names.

# Fields
- `codes`: the DICO of each municipality, in feature order.
- `names`: the municipality names.
- `rings`: for each municipality, its rings. A municipality with islands or
  exclaves has more than one, and every ring is used for contiguity, so an
  exclave's neighbours are found as readily as the mainland body's.
"""
struct MunicipalBoundaries
    codes::Vector{String}
    names::Vector{String}
    rings::Vector{Vector{Ring}}
end

"""
    ncounties(b::MunicipalBoundaries) -> Int

How many municipalities `b` holds.
"""
ncounties(b::MunicipalBoundaries) = length(b.codes)

Base.length(b::MunicipalBoundaries) = length(b.codes)

function Base.show(io::IO, b::MunicipalBoundaries)
    nv = sum(length(r) for m in b.rings for r in m)
    print(io, "MunicipalBoundaries(", length(b.codes), " municipalities, ",
          sum(length, b.rings), " rings, ", nv, " vertices)")
end

# Collect every coordinate ring out of a GeoJSON coordinate array, whatever its
# nesting: Polygon nests one level deeper than LineString, MultiPolygon one
# deeper again, and CAOP mixes Polygon and MultiPolygon across features.
function _collect_rings!(out::Vector{Ring}, coords)
    isempty(coords) && return out
    first_el = coords[1]
    if first_el isa Number
        return out  # a bare position; nothing to collect
    elseif first_el[1] isa Number
        ring = Ring(undef, length(coords))
        @inbounds for i in eachindex(coords)
            p = coords[i]
            ring[i] = (Float64(p[1]), Float64(p[2]))
        end
        push!(out, ring)
    else
        for c in coords
            _collect_rings!(out, c)
        end
    end
    return out
end

"""
    read_caop_geojson(path; code_property = "dtmn", name_property = "municipio")

Read municipal boundaries from a CAOP GeoJSON feature collection, as DGT's OGC
API serves it:

```
https://ogcapi.dgterritorio.gov.pt/collections/municipios/items?f=json&limit=400
```

That collection is the **mainland**: 278 municipalities, which is the set with a
connected contiguity graph. The 30 island municipalities of Madeira and the
Azores are published separately and have no land neighbours at all, so a
contiguity matrix spanning all 308 has 30 zero rows and cannot be
row-standardised.

`code_property` must name a property holding the DICO; in CAOP it is `dtmn`.
Each is checked to be four digits, because the DICO is what joins these
boundaries to INE's indicators and a silent mismatch there is unrecoverable
later.

The file is large — the full mainland collection is about 200 MB of JSON for
1.25 million vertices — so expect this to take a few seconds and a few
gigabytes of transient memory.
"""
function read_caop_geojson(path::AbstractString;
                           code_property::AbstractString = "dtmn",
                           name_property::AbstractString = "municipio")
    fc = JSON3.read(read(path, String))
    haskey(fc, :features) || throw(ArgumentError(
        "$(repr(path)) is not a GeoJSON FeatureCollection: no \"features\" key"))
    feats = fc.features
    codes = String[]
    names = String[]
    rings = Vector{Ring}[]
    code_sym = Symbol(code_property)
    name_sym = Symbol(name_property)
    for (i, f) in enumerate(feats)
        props = get(f, :properties, nothing)
        props === nothing && throw(ArgumentError(
            "feature $i has no properties, so its DICO cannot be read"))
        haskey(props, code_sym) || throw(ArgumentError(
            "feature $i has no property $(repr(code_property)); " *
            "CAOP calls the municipality code \"dtmn\""))
        code = string(props[code_sym])
        (length(code) == 4 && all(isdigit, code)) || throw(ArgumentError(
            "feature $i has $(repr(code_property)) = $(repr(code)), which is " *
            "not a four-digit DICO; without it these boundaries cannot be " *
            "joined to INE indicators"))
        geom = get(f, :geometry, nothing)
        geom === nothing && throw(ArgumentError("feature $i has no geometry"))
        rs = Ring[]
        _collect_rings!(rs, geom.coordinates)
        isempty(rs) && throw(ArgumentError(
            "feature $i ($code) yielded no rings; its geometry is " *
            string(get(geom, :type, "of unknown type"))))
        push!(codes, code)
        push!(names, haskey(props, name_sym) ? string(props[name_sym]) : code)
        push!(rings, rs)
    end
    if length(unique(codes)) != length(codes)
        dup = join([c for c in unique(codes) if count(==(c), codes) > 1], ", ")
        throw(ArgumentError("duplicate DICO codes: $dup"))
    end
    return MunicipalBoundaries(codes, names, rings)
end

# A ring's vertices, with a duplicated closing vertex dropped so that a closed
# and an unclosed ring hash to the same set.
function _open_ring(r::Ring)
    (length(r) > 1 && r[1] == r[end]) ? view(r, 1:(length(r) - 1)) : view(r, 1:length(r))
end

"""
    neighbour_lists(b; criterion = :queen) -> Vector{Vector{Int}}

The neighbours of each municipality, as sorted index lists.

`criterion` is `:queen` (sharing at least one vertex) or `:rook` (sharing an
edge, that is two consecutive vertices). See the module docstring for why
hashing is exact on CAOP and what to check before trusting it on other data.
"""
function neighbour_lists(b::MunicipalBoundaries; criterion::Symbol = :queen)
    criterion in (:queen, :rook) || throw(ArgumentError(
        "criterion must be :queen (a shared vertex) or :rook (a shared edge), " *
        "got $(repr(criterion))"))
    n = length(b.codes)
    if criterion === :queen
        owners = Dict{Tuple{Float64, Float64}, Vector{Int}}()
        for i in 1:n, r in b.rings[i]
            for p in _open_ring(r)
                push!(get!(() -> Int[], owners, p), i)
            end
        end
        return _adjacency_from(owners, n)
    else
        owners = Dict{NTuple{4, Float64}, Vector{Int}}()
        for i in 1:n, r in b.rings[i]
            v = _open_ring(r)
            m = length(v)
            m < 2 && continue
            for j in 1:m
                a = v[j]
                c = v[j == m ? 1 : j + 1]
                a == c && continue
                # Orient the segment so the two polygons that share it, which
                # traverse their borders in opposite directions, hash alike.
                key = a < c ? (a[1], a[2], c[1], c[2]) : (c[1], c[2], a[1], a[2])
                push!(get!(() -> Int[], owners, key), i)
            end
        end
        return _adjacency_from(owners, n)
    end
end

function _adjacency_from(owners::Dict{K, Vector{Int}}, n::Int) where {K}
    sets = [Set{Int}() for _ in 1:n]
    for (_, ms) in owners
        length(ms) < 2 && continue
        u = unique(ms)
        length(u) < 2 && continue
        for a in u, c in u
            a == c || push!(sets[a], c)
        end
    end
    return [sort!(collect(s)) for s in sets]
end

"""
    contiguity(b; criterion = :queen, standardize = false) -> SparseMatrixCSC{Float64,Int}

A contiguity weights matrix over the municipalities of `b`, in feature order.

With `standardize = true` the rows are divided by their sums. That throws if any
row is empty rather than producing `NaN`: an isolated unit means either that the
boundaries are not a node-matched planar partition, or that island municipalities
have been mixed in with the mainland, and both are worth hearing about before
the matrix reaches an estimator.

The matrix is symmetric and has a zero diagonal. On mainland CAOP it holds 739
non-zero pairs under `:queen` and 737 under `:rook`.
"""
function contiguity(b::MunicipalBoundaries; criterion::Symbol = :queen,
                    standardize::Bool = false)
    nb = neighbour_lists(b; criterion = criterion)
    n = length(nb)
    I = Int[]; J = Int[]; V = Float64[]
    for i in 1:n, j in nb[i]
        push!(I, i); push!(J, j); push!(V, 1.0)
    end
    W = sparse(I, J, V, n, n)
    if standardize
        rs = vec(sum(W; dims = 2))
        bad = findall(iszero, rs)
        if !isempty(bad)
            throw(ArgumentError(
                "cannot row-standardise: $(length(bad)) municipalit" *
                (length(bad) == 1 ? "y has" : "ies have") * " no neighbours (" *
                join(b.names[first(bad, 5)], ", ") *
                (length(bad) > 5 ? ", ..." : "") *
                "). Island municipalities share no land border, so a " *
                "contiguity matrix including them cannot be row-standardised; " *
                "use the mainland set or a neighbour-count weighting."))
        end
        W = Diagonal(1 ./ rs) * W
    end
    return W
end

"""
    centroids(b) -> Matrix{Float64}

An `n x 2` matrix of polygon centroids, one row per municipality, in the
coordinates the boundaries carry.

The centroid is the area-weighted centroid of the rings, computed by the
standard polygon moment formula, not the mean of the vertices: vertices cluster
where a border is intricate, so averaging them pulls the result toward the
fiddly side of the municipality. For a municipality of several rings the rings
are combined by signed area, which also makes holes subtract as they should.

A degenerate ring of zero area falls back to its vertex mean, since the
moment formula divides by that area.
"""
function centroids(b::MunicipalBoundaries)
    n = length(b.codes)
    C = Matrix{Float64}(undef, n, 2)
    for i in 1:n
        sx = 0.0; sy = 0.0; sa = 0.0
        for r in b.rings[i]
            v = _open_ring(r)
            m = length(v)
            m < 3 && continue
            a2 = 0.0; cx = 0.0; cy = 0.0
            for j in 1:m
                x1, y1 = v[j]
                x2, y2 = v[j == m ? 1 : j + 1]
                cr = x1 * y2 - x2 * y1
                a2 += cr
                cx += (x1 + x2) * cr
                cy += (y1 + y2) * cr
            end
            if a2 != 0.0
                sx += cx; sy += cy; sa += a2
            end
        end
        if sa != 0.0
            # With a2 = sum of cross products = 2A, the centroid is
            # sum((x1+x2)*cross) / (3*a2). An earlier version divided by 3 and
            # then by 2*a2, which put every centroid at exactly half its true
            # coordinates -- Lisboa at (-4.58, 19.37) rather than (-9.14,
            # 38.72). The test suite pins real coordinates for that reason: a
            # centroid that is wrong by a constant factor still looks like a
            # plausible pair of numbers, and feeding it to a distance-based
            # weighting would have produced a plausible-looking W as well.
            C[i, 1] = sx / (3 * sa); C[i, 2] = sy / (3 * sa)
        else
            vs = [p for r in b.rings[i] for p in _open_ring(r)]
            C[i, 1] = sum(first, vs) / length(vs)
            C[i, 2] = sum(last, vs) / length(vs)
        end
    end
    return C
end

"""
    knn_contiguity(b, k; standardize = false) -> SparseMatrixCSC{Float64,Int}

A k-nearest-neighbour weights matrix from the centroids, by Euclidean distance.

Unlike contiguity this gives **every** unit exactly `k` neighbours, so it is the
answer when island municipalities must be kept: no row is empty and the matrix
row-standardises. The price is that it is **not symmetric** — being among your
`k` nearest does not make you one of theirs — and estimators that assume a
symmetric `W` will be wrong on it. Symmetrise deliberately if you need that,
and say which way.

On lon/lat coordinates the distance is planar in degrees, which distorts with
latitude. Over mainland Portugal, about 4 degrees of latitude, the distortion is
small; project the coordinates first if it matters.
"""
function knn_contiguity(b::MunicipalBoundaries, k::Int; standardize::Bool = false)
    n = length(b.codes)
    1 <= k < n || throw(ArgumentError(
        "k must be at least 1 and less than the $(n) municipalities, got $k"))
    C = centroids(b)
    I = Int[]; J = Int[]; V = Float64[]
    d = Vector{Float64}(undef, n)
    for i in 1:n
        @inbounds for j in 1:n
            d[j] = (C[j, 1] - C[i, 1])^2 + (C[j, 2] - C[i, 2])^2
        end
        d[i] = Inf
        for j in partialsortperm(d, 1:k)
            push!(I, i); push!(J, j); push!(V, standardize ? 1 / k : 1.0)
        end
    end
    return sparse(I, J, V, n, n)
end

"""
    write_gal(path, b; criterion = :queen, id = :code)

Write the contiguity graph as a **GeoDa GAL** file, the format
SpatialEconometrics.jl already reads for the Columbus data. This is how the
boundaries reach that package without it gaining any dependency on this one:
the GAL file is committed, and nothing at the far end has to parse a polygon or
reach the network.

`id` is `:code` to label units by DICO, or `:name` by municipality name. DICO is
the better choice — it is what joins to INE's indicators, and two
municipalities are called Calheta.

The first line is `0 n <name> <idvar>`, as GeoDa writes it, then for each unit a
line giving its id and neighbour count followed by a line of neighbour ids.
"""
function write_gal(path::AbstractString, b::MunicipalBoundaries;
                   criterion::Symbol = :queen, id::Symbol = :code)
    id in (:code, :name) || throw(ArgumentError("id must be :code or :name, got $(repr(id))"))
    labels = id === :code ? b.codes : b.names
    nb = neighbour_lists(b; criterion = criterion)
    n = length(nb)
    open(path, "w") do io
        println(io, "0 ", n, " municipios ", id === :code ? "dtmn" : "municipio")
        for i in 1:n
            println(io, labels[i], " ", length(nb[i]))
            println(io, join((labels[j] for j in nb[i]), " "))
        end
    end
    return path
end

end # module
