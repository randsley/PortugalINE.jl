# Layer 6: web map layers. Runs after test_panel.jl, whose fixtures (PB, INC,
# BIR) it reuses: the ten CAOP2024 parishes of Amadora and Odivelas.
using PortugalINE.Web: _topology, _polygons, _open, _simplify

# Decode a TopoJSON ring (arc refs) back to vertex sequences in the arcs' units.
function _decode(ref, arcs)
    out = NTuple{2, Float64}[]
    for r in ref
        a = r >= 0 ? arcs[r + 1] : reverse(arcs[-r])
        append!(out, isempty(out) ? a : a[2:end])
    end
    return out[1:(end - 1)]                     # open
end
# Equal as rings: the same cyclic sequence, either direction.
function _samering(a, b)
    length(a) == length(b) || return false
    k = findfirst(==(a[1]), b); k === nothing && return false
    rot = [b[k:end]; b[1:(k - 1)]]
    rot == a && return true
    rb = reverse(b); k = findfirst(==(a[1]), rb)
    return [rb[k:end]; rb[1:(k - 1)]] == a
end

@testset "EPSG:3763 to longitude and latitude, against PROJ" begin
    # pyproj 3.8 (PROJ), EPSG:3763 -> EPSG:4326, 2026-11-26.
    ref = [((0.0, 0.0), (-8.1331083333, 39.6682583333)),
           ((-87000.0, -105000.0), (-9.1334539337, 38.7181965658)),     # Lisboa
           ((-25000.0, 280000.0), (-8.4357536818, 42.1891877369)),      # Minho
           ((150000.0, -290000.0), (-6.4470370518, 37.0437427894)),     # past the SE corner
           ((-60000.0, -190000.0), (-8.8158038184, 37.9547497137))]
    for ((x, y), (lon, lat)) in ref
        l1, l2 = ptm06_to_wgs84(x, y)
        @test abs(l1 - lon) < 1e-9 && abs(l2 - lat) < 1e-9
    end
end

@testset "shared borders become shared arcs, and decode exactly" begin
    flat = [_open(r) for rs in PB.rings for r in rs]
    arcs, refs = _topology(flat)
    @test all(i -> _samering(_decode(refs[i], arcs), flat[i]), eachindex(flat))
    uses = zeros(Int, length(arcs))
    for ref in refs, r in ref; uses[r >= 0 ? r + 1 : -r] += 1; end
    @test maximum(uses) == 2 && count(==(2), uses) > 0      # each border once, two users
    # Every vertex survives in exactly one place: arcs overlap only at junctions.
    interior = [p for a in arcs for p in a[2:(end - 1)]]
    @test length(interior) == length(unique(interior))
    # Simplified, a shared border is still the same vertices on both sides,
    # because it is one arc; and no ring collapses.
    s = _simplify(arcs, refs, 50.0)
    @test sum(length, s) < sum(length, arcs) ÷ 2
    @test all(ref -> length(_decode(ref, s)) >= 3, refs)
    @test all(i -> s[i][1] == arcs[i][1] && s[i][end] == arcs[i][end], eachindex(arcs))
end

@testset "holes by containment, not orientation" begin
    sq(x0, y0, d) = [(x0, y0), (x0 + d, y0), (x0 + d, y0 + d), (x0, y0 + d), (x0, y0)]
    # An outer square, a hole in it (same orientation, so orientation cannot
    # tell), an island in the hole, and a separate square.
    rs = [sq(0.0, 0.0, 10.0), sq(2.0, 2.0, 6.0), sq(4.0, 4.0, 2.0), sq(20.0, 0.0, 3.0)]
    @test sort(sort.(_polygons(rs))) == [[1, 2], [3], [4]]
end

@testset "write_webmap: TopoJSON, values, links, provenance" begin
    p = join_panel(PB, :income => INC, :births => BIR; periods = ["2018", "2019"])
    dir = mktempdir()
    @test_throws ArgumentError write_webmap(dir, p; crs = "EPSG:9999")
    files = write_webmap(dir, p; crs = "EPSG:3763", name = "t", tolerance = 10)
    @test basename.(files) == ["t.topo.json", "t.values.json", "t.links.json", "t_WEBMAP.md"]
    topo = JSON3.read(read(files[1], String))
    g = topo.objects.units.geometries
    @test [String(x.id) for x in g] == p.keys
    @test String(g[1].properties.name) == p.names[1]
    # Longitude and latitude, in Lisbon's northwest.
    x0, y0, x1, y1 = topo.bbox
    @test -9.3 < x0 < x1 < -9.1 && 38.7 < y0 < y1 < 38.85
    v = JSON3.read(read(files[2], String))
    @test collect(v.periods) == ["2018", "2019"] && String(v.key) == "dicofre"
    @test length(v.columns.income.values) == 2 && length(v.columns.income.values[1]) == 10
    @test v.columns.income.values[1][1] == p.columns.income[1, 1]
    @test String(v.columns.births.filter) == "Dim3=T"
    l = JSON3.read(read(files[3], String))
    @test length(l.links) == nnz(p.adjacency) ÷ 2
    @test all(e -> 0 <= e[1] < e[2] < 10, l.links)
    @test length(l.centroids) == 10 && -9.3 < l.centroids[1][1] < -9.1
    md = read(files[4], String)
    @test occursin(CAOP_ATTRIBUTION, md) && occursin("Do not compute weights", md)
    @test occursin(PB.sha256, md)
end
