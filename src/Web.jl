"""
    Web

Layer 6: boundaries and data as files a browser map draws. Web maps (MapLibre,
deck.gl, D3) want longitude and latitude, small files, and borders that stay
shared when they are simplified, so neighbouring units do not open slivers or
overlap. This layer reprojects, simplifies each shared border once, and writes
TopoJSON beside the values and the weights' links.

The geometry it writes is for **display only**. Simplification moves vertices,
so weights computed from it would differ from the exact ones; the GAL files
are the weights.
"""
module Web

using ..Boundaries: MunicipalBoundaries, Ring, centroids, CAOP_ATTRIBUTION
using ..Join: MunicipalDataset, _filter_text
using ..Panel: PanelDataset
using ..Indicators: ine_citation
using JSON3
using Printf
using SparseArrays: findnz

export ptm06_to_wgs84, write_webmap

# --- EPSG:3763 (PT-TM06/ETRS89) to longitude and latitude ---------------------
#
# Transverse Mercator on GRS80, origin 39°40'05.73"N 8°07'59.19"W, scale 1, no
# false easting or northing. Inverted with Krüger's series to fourth order in
# n, which is good to well under a millimetre over Portugal. ETRS89 and WGS84
# differ by under a metre, which PROJ itself treats as nothing for this
# transformation; display needs no better.
const _A_GRS80 = 6378137.0
const _F_GRS80 = 1 / 298.257222101
const _LAT0 = 39.66825833333333
const _LON0 = -8.133108333333333

const _TM = let
    f = _F_GRS80; n = f / (2 - f); e = sqrt(f * (2 - f))
    A = _A_GRS80 / (1 + n) * (1 + n^2 / 4 + n^4 / 64)
    α = (n / 2 - 2n^2 / 3 + 5n^3 / 16 + 41n^4 / 180,
         13n^2 / 48 - 3n^3 / 5 + 557n^4 / 1440,
         61n^3 / 240 - 103n^4 / 140,
         49561n^4 / 161280)
    β = (n / 2 - 2n^2 / 3 + 37n^3 / 96 - n^4 / 360,
         n^2 / 48 + n^3 / 15 - 437n^4 / 1440,
         17n^3 / 480 - 37n^4 / 840,
         4397n^4 / 161280)
    δ = (2n - 2n^2 / 3 - 2n^3 + 116n^4 / 45,
         7n^2 / 3 - 8n^3 / 5 - 227n^4 / 45,
         56n^3 / 15 - 136n^4 / 35,
         4279n^4 / 630)
    φ0 = deg2rad(_LAT0)
    χ0 = atan(sinh(asinh(tan(φ0)) - e * atanh(e * sin(φ0))))
    M0 = A * (χ0 + sum(α[j] * sin(2j * χ0) for j in 1:4))
    (; A, β, δ, M0)
end

"""
    ptm06_to_wgs84(x, y) -> (lon, lat)

Convert a point in EPSG:3763 (PT-TM06/ETRS89, metres: the coordinates of
CAOP's mainland GeoPackages) to longitude and latitude in degrees. Pure Julia,
checked against PROJ to 1e-9 degrees (a tenth of a millimetre).
"""
function ptm06_to_wgs84(x::Real, y::Real)
    (; A, β, δ, M0) = _TM
    ξ = (y + M0) / A; η = x / A
    ξ′ = ξ; η′ = η
    for j in 1:4
        ξ′ -= β[j] * sin(2j * ξ) * cosh(2j * η)
        η′ -= β[j] * cos(2j * ξ) * sinh(2j * η)
    end
    χ = asin(sin(ξ′) / cosh(η′))
    φ = χ + sum(δ[j] * sin(2j * χ) for j in 1:4)
    λ = deg2rad(_LON0) + atan(sinh(η′), cos(ξ′))
    return (rad2deg(λ), rad2deg(φ))
end

const _CRS = ("EPSG:3763", "EPSG:4326")

function _projector(crs::AbstractString)
    crs == "EPSG:3763" && return p -> ptm06_to_wgs84(p[1], p[2])
    crs == "EPSG:4326" && return p -> (Float64(p[1]), Float64(p[2]))
    throw(ArgumentError(
        "crs must be one of $(join(_CRS, ", ")), the systems CAOP's mainland files " *
        "use (the GeoPackages are EPSG:3763, DGT's OGC API serves EPSG:4326); got " *
        "$(repr(crs)). The boundaries do not record it, so it is not guessed."))
end

# --- polygons from flat rings ---------------------------------------------------
#
# The boundaries keep a unit's rings as one flat list; holes are told apart by
# containment, not by orientation, which CAOP does not guarantee. A ring at an
# even nesting depth among its unit's rings is an outer ring, one at an odd depth
# a hole of the smallest ring containing it.

_open(r) = (length(r) > 1 && r[1] == r[end]) ? r[1:(end - 1)] : r

_area2(r) = (s = 0.0; for i in eachindex(r)
    j = i == lastindex(r) ? firstindex(r) : i + 1
    s += r[i][1] * r[j][2] - r[j][1] * r[i][2]
end; s)

function _inside(p, r)
    x, y = p; c = false; n = length(r)
    for i in 1:n
        (xi, yi) = r[i]; (xj, yj) = r[i == 1 ? n : i - 1]
        ((yi > y) != (yj > y)) && x < (xj - xi) * (y - yi) / (yj - yi) + xi && (c = !c)
    end
    return c
end

# A ring lies inside another if one of its vertices that is not a vertex of
# the other does (a hole may touch its outer ring at a vertex).
function _within(a, b)
    vb = Set(b)
    for p in a
        p in vb && continue
        return _inside(p, b)
    end
    return false
end

function _polygons(rings::Vector{<:AbstractVector})
    rs = [_open(r) for r in rings]
    order = sortperm([abs(_area2(r)) for r in rs]; rev = true)
    parent = zeros(Int, length(rs)); depth = zeros(Int, length(rs))
    for (k, i) in enumerate(order), i2 in Iterators.reverse(order[1:(k - 1)])
        if _within(rs[i], rs[i2])
            parent[i] = i2; depth[i] = depth[i2] + 1
            break
        end
    end
    polys = Vector{Vector{Int}}()
    slot = Dict{Int, Int}()
    for i in order
        if iseven(depth[i])
            push!(polys, [i]); slot[i] = length(polys)
        else
            push!(polys[slot[parent[i]]], i)
        end
    end
    return polys
end

# --- topology: shared borders as shared arcs ------------------------------------
#
# A vertex is a junction when it has other than two distinct neighbours across
# every ring that uses it: where three units meet, where a border reaches the
# coast, a pinch. Between two junctions every ring that runs along a border
# visits the same vertices, so cutting at junctions gives each shared border as
# one arc, traversed forwards by one unit and backwards by the other. A ring
# with no junction (an enclave, or an island) is one closed arc starting at its
# smallest vertex, which both units sharing it pick alike.

const P2 = NTuple{2, Float64}

function _topology(rings::Vector{Vector{P2}})
    nb = Dict{P2, Set{P2}}()
    for r in rings, i in eachindex(r)
        s = get!(Set{P2}, nb, r[i])
        push!(s, r[i == 1 ? lastindex(r) : i - 1], r[i == lastindex(r) ? 1 : i + 1])
    end
    junction = Set(p for (p, s) in nb if length(s) != 2)
    arcs = Vector{Vector{P2}}(); index = Dict{Vector{P2}, Int}()
    refs = Vector{Vector{Int}}()
    for r in rings
        js = findall(in(junction), r)
        if isempty(js)
            k = argmin(r)
            a = [r[k:end]; r[1:k]]
            pieces = [a]
        else
            rot = [r[js[1]:end]; r[1:(js[1] - 1)]]
            cut = [findall(in(junction), rot); length(rot) + 1]
            rot = [rot; rot[1]]
            pieces = [rot[cut[m]:cut[m + 1]] for m in 1:(length(cut) - 1)]
        end
        ref = Int[]
        for a in pieces
            # The canonical direction is the lexicographically smaller one, so
            # both units sharing a border find the same arc (a closed arc and
            # its reverse start at the same vertex, so this holds for them too).
            b = reverse(a)
            fwd = a <= b
            c = fwd ? a : b
            id = get!(index, c) do
                push!(arcs, c); length(arcs)
            end
            push!(ref, fwd ? id - 1 : -id)      # TopoJSON: ~i is -(i + 1)
        end
        push!(refs, ref)
    end
    return arcs, refs
end

# Douglas-Peucker, keeping both ends. A closed arc is split at the vertex
# farthest from its start first, so it cannot collapse to a point.
function _dp(a::Vector{P2}, tol::Float64)
    n = length(a)
    n <= 2 && return copy(a)
    if a[1] == a[end]
        far = argmax([hypot(p[1] - a[1][1], p[2] - a[1][2]) for p in a])
        h1 = _dp(a[1:far], tol); h2 = _dp(a[far:end], tol)
        return [h1; h2[2:end]]
    end
    keep = falses(n); keep[1] = keep[n] = true
    stack = [(1, n)]
    while !isempty(stack)
        (i, j) = pop!(stack)
        j <= i + 1 && continue
        (x1, y1) = a[i]; (x2, y2) = a[j]
        dx = x2 - x1; dy = y2 - y1; L = hypot(dx, dy)
        best = -1.0; k = 0
        for m in (i + 1):(j - 1)
            d = L == 0 ? hypot(a[m][1] - x1, a[m][2] - y1) :
                abs(dy * a[m][1] - dx * a[m][2] + x2 * y1 - y2 * x1) / L
            d > best && (best = d; k = m)
        end
        if best > tol
            keep[k] = true
            push!(stack, (i, k), (k, j))
        end
    end
    return a[keep]
end

# The distinct vertices a ring would have from its (simplified) arcs.
function _ring_size(ref, arcs)
    n = 0
    for r in ref
        a = arcs[r >= 0 ? r + 1 : -r]
        n += length(a) - 1
    end
    return n
end

function _simplify(arcs, refs, tol::Float64)
    tols = fill(tol, length(arcs))
    out = [_dp(a, tol) for a in arcs]
    # A ring left with fewer than three vertices is a sliver: simplify its arcs
    # less, which changes them for both units that share them.
    for _ in 1:20
        bad = [k for (k, ref) in enumerate(refs) if _ring_size(ref, out) < 3]
        isempty(bad) && break
        for k in bad, r in refs[k]
            i = r >= 0 ? r + 1 : -r
            tols[i] /= 4
            out[i] = tols[i] < 1e-9 ? copy(arcs[i]) : _dp(arcs[i], tols[i])
        end
    end
    return out
end

# --- TopoJSON -------------------------------------------------------------------

const _Q = 1_000_000      # quantisation grid: about half a metre over Portugal

function _topojson(b::MunicipalBoundaries, names, project, tol::Float64)
    flat = Vector{Vector{P2}}(); owner = Int[]; polys = Vector{Vector{Vector{Int}}}()
    for (u, rs) in enumerate(b.rings)
        ps = _polygons(rs)
        base = length(flat)
        for r in rs
            push!(flat, [(Float64(p[1]), Float64(p[2])) for p in _open(r)])
            push!(owner, u)
        end
        push!(polys, [[base + i for i in poly] for poly in ps])
    end
    arcs, refs = _topology(flat)
    nv0 = sum(length, arcs)
    sarcs = _simplify(arcs, refs, tol)
    ll = [[project(p) for p in a] for a in sarcs]
    xs = [p[1] for a in ll for p in a]; ys = [p[2] for a in ll for p in a]
    x0, x1 = extrema(xs); y0, y1 = extrema(ys)
    sx = (x1 - x0) / (_Q - 1); sy = (y1 - y0) / (_Q - 1)
    qarcs = Vector{Vector{NTuple{2, Int}}}()
    for a in ll
        q = [(round(Int, (p[1] - x0) / sx), round(Int, (p[2] - y0) / sy)) for p in a]
        # Quantising can make neighbours coincide; drop repeats, keep the ends.
        k = [q[1]]
        for i in 2:length(q)
            (q[i] != k[end] || i == length(q)) && push!(k, q[i])
        end
        d = [k[1]]
        for i in 2:length(k)
            push!(d, (k[i][1] - k[i - 1][1], k[i][2] - k[i - 1][2]))
        end
        push!(qarcs, d)
    end
    geoms = map(eachindex(b.codes)) do u
        ps = [[refs[i] for i in poly] for poly in polys[u]]
        length(ps) == 1 ?
            (type = "Polygon", id = b.codes[u], properties = (name = names[u],), arcs = ps[1]) :
            (type = "MultiPolygon", id = b.codes[u], properties = (name = names[u],), arcs = ps)
    end
    topo = (type = "Topology", bbox = [x0, y0, x1, y1],
            transform = (scale = [sx, sy], translate = [x0, y0]),
            objects = (units = (type = "GeometryCollection", geometries = geoms),),
            arcs = [[[p[1], p[2]] for p in a] for a in qarcs])
    uses = zeros(Int, length(arcs))
    for ref in refs, r in ref
        uses[r >= 0 ? r + 1 : -r] += 1
    end
    stats = (vertices_in = nv0, vertices_out = sum(length, qarcs), arcs = length(arcs),
             shared = count(>(1), uses))
    return topo, stats
end

# --- values and links -----------------------------------------------------------

_jnum(v) = ismissing(v) || !isfinite(v) ? nothing : v

function _links(b::MunicipalBoundaries, A, project)
    C = centroids(b)
    I, J, _ = findnz(A)
    pairs = sort!([[i - 1, j - 1] for (i, j) in zip(I, J) if i < j])
    return (units = length(b.codes),
            centroids = [[round(c[1]; digits = 6), round(c[2]; digits = 6)]
                         for c in (project((C[i, 1], C[i, 2])) for i in axes(C, 1))],
            links = pairs)
end

"""
    write_webmap(dir, p::PanelDataset; crs, name = "portugal_parishes_panel", tolerance = 20.0)
    write_webmap(dir, ds::MunicipalDataset; crs, name = "portugal_municipalities", tolerance = 20.0)

Write what a browser map needs, for the units of a panel or a dataset:

- `<name>.topo.json`: TopoJSON in longitude and latitude, one object `units`
  with each unit's code as `id` and its name as the dataset keeps it (INE's). Each shared border is one arc,
  simplified once (Douglas-Peucker, `tolerance` metres), so neighbours stay
  flush. Coordinates are quantised to a 10⁶ grid, about half a metre.
- `<name>.values.json`: the codes, the periods and every column, as
  `values[period][unit]` (`null` where INE suppressed the cell), with the
  indicator and filter of each column.
- `<name>.links.json`: the weights' links as pairs of 0-based unit indices,
  `i < j`, and each unit's centroid in longitude and latitude, to draw `W` as
  a network.
- `<name>_WEBMAP.md`: provenance, both credits, and how the geometry was
  changed.

`crs` is the boundaries' coordinate system, `"EPSG:3763"` for CAOP's mainland
GeoPackages and `"EPSG:4326"` for DGT's OGC API; it is required because the
boundaries do not record it. The geometry is for display: weights come from the
GAL files, which use the exact vertices.
"""
function write_webmap end

function write_webmap(dir::AbstractString, p::PanelDataset; crs::AbstractString,
                      name::AbstractString = "portugal_parishes_panel", tolerance::Real = 20.0)
    cols = collect(keys(p.columns))
    vals = Dict(String(c) => (indicator = p.varcds[k], filter = _filter_text(p.filters[k]),
                              language = p.languages[k], extracted = p.column_extracted[k],
                              values = [[_jnum(p.columns[c][i, t]) for i in eachindex(p.keys)]
                                        for t in eachindex(p.periods)])
                for (k, c) in enumerate(cols))
    values = (name = name, level = String(p.boundaries.level), key = _key(p.boundaries),
              units = p.keys, names = p.names, periods = p.periods,
              columns = vals, order = String.(cols))
    return _write(dir, name, p.boundaries, p.adjacency, p.criterion, values, crs,
                  Float64(tolerance), ine_citation(p))
end

function write_webmap(dir::AbstractString, ds::MunicipalDataset; crs::AbstractString,
                      name::AbstractString = "portugal_municipalities", tolerance::Real = 20.0)
    cols = collect(keys(ds.columns))
    vals = Dict(String(c) => (indicator = ds.varcds[k], period = ds.periods[k],
                              filter = _filter_text(ds.filters[k]), language = ds.languages[k],
                              extracted = ds.column_extracted[k],
                              values = [[_jnum(v) for v in ds.columns[c]]])
                for (k, c) in enumerate(cols))
    values = (name = name, level = String(ds.boundaries.level), key = _key(ds.boundaries),
              units = ds.dico, names = ds.name, periods = [""],
              columns = vals, order = String.(cols))
    return _write(dir, name, ds.boundaries, ds.adjacency, ds.criterion, values, crs,
                  Float64(tolerance), ine_citation(ds))
end

_key(b) = b.level === :parish ? "dicofre" : "dico"

function _write(dir, name, b, A, criterion, values, crs, tol, citation)
    project = _projector(crs)
    tol >= 0 || throw(ArgumentError("tolerance must be at least 0 metres, got $tol."))
    # Simplification works in the boundaries' own units: metres for EPSG:3763,
    # degrees (of latitude) for EPSG:4326.
    toln = crs == "EPSG:4326" ? tol / 111_320 : tol
    mkpath(dir)
    # Names as the dataset keeps them (INE's spelling), so both files agree.
    topo, st = _topojson(b, values.names, project, toln)
    files = String[]
    f = joinpath(dir, "$name.topo.json"); open(io -> JSON3.write(io, topo), f, "w"); push!(files, f)
    f = joinpath(dir, "$name.values.json"); open(io -> JSON3.write(io, values), f, "w"); push!(files, f)
    lk = _links(b, A, project)
    f = joinpath(dir, "$name.links.json")
    open(io -> JSON3.write(io, (criterion = String(criterion), lk...)), f, "w"); push!(files, f)
    f = joinpath(dir, "$(name)_WEBMAP.md")
    open(f, "w") do io
        println(io, "# $name: web map layers")
        println(io)
        # `citation` (ine_citation) already ends with DGT's credit.
        println(io, "> ", citation)
        println(io)
        println(io, "Both credits are conditions of reuse: show them on any map drawn from these files.")
        println(io)
        println(io, "| file | contents |")
        println(io, "|---|---|")
        println(io, "| `$name.topo.json` | ", length(b.codes), " units, TopoJSON, longitude and latitude |")
        println(io, "| `$name.values.json` | ", length(values.order), " columns x ", length(values.periods), " period(s) |")
        println(io, "| `$name.links.json` | ", length(lk.links), " ", criterion, " links and centroids |")
        println(io)
        println(io, "## The geometry is for display")
        println(io)
        println(io, "Boundaries: CAOP edition `", isempty(b.edition) ? "unstated" : b.edition,
                "`, file `", basename(b.source), "`, SHA-256 `", b.sha256, "`, ", crs, ".")
        @printf(io, "Each shared border was simplified once, as one arc (Douglas-Peucker, %g m), ", tol)
        println(io, "so neighbours stay flush: ", st.arcs, " arcs, ", st.shared, " of them shared.")
        println(io, "Vertices: ", st.vertices_in, " in, ", st.vertices_out, " out. Reprojected to ",
                "longitude and latitude (ETRS89, the same as WGS84 to under a metre) and quantised ",
                "to a 10^6 grid. **Do not compute weights from it**: the links file carries the ",
                "weights, computed on the exact vertices.")
    end
    push!(files, f)
    return files
end

end # module
