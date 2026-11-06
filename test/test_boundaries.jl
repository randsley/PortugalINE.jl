# Layer 3: boundaries and weights.
#
# Two kinds of test, deliberately. The synthetic grid pins the algorithms
# against a closed form -- a 3x3 lattice of unit squares has adjacency counts
# that can be worked out on paper, so a wrong implementation cannot pass by
# agreeing with itself. The CAOP fixture then pins them against real
# topology, because real boundaries are where node matching either holds or
# does not, and a synthetic grid cannot tell you which.
#
# The fixture is six real municipalities of the Lisboa district, taken from
# DGT's CAOP (CC-BY-4.0): Lisboa, Loures, Oeiras, Vila Franca de Xira,
# Amadora and Odivelas. They were chosen because Lisboa and Vila Franca de
# Xira meet at a single point, which is one of only two such pairs in the whole
# mainland, so the fixture exercises the queen/rook distinction on data rather
# than on a constructed corner.

using PortugalINE, Test, SparseArrays

const CAOP6 = joinpath(@__DIR__, "fixtures", "caop_lisboa6.json")

# A w x h lattice of unit squares, as a MunicipalBoundaries. Neighbouring
# squares share exact vertices, which is what a clean planar partition means.
function grid_boundaries(w::Int, h::Int)
    codes = String[]; names = String[]; rings = Vector{Vector{Tuple{Float64,Float64}}}[]
    for j in 0:(h - 1), i in 0:(w - 1)
        x = Float64(i); y = Float64(j)
        ring = [(x, y), (x + 1, y), (x + 1, y + 1), (x, y + 1), (x, y)]
        push!(codes, string(1000 + length(codes) + 1))
        push!(names, "cell_$(i)_$(j)")
        push!(rings, [ring])
    end
    return MunicipalBoundaries(codes, names, rings)
end

@testset "synthetic lattice, against a closed form" begin
    b = grid_boundaries(3, 3)
    @test length(b) == 9

    # Rook on a 3x3 lattice: 2 horizontal joins per row times 3 rows, plus 2
    # vertical per column times 3 columns = 12.
    Wr = contiguity(b; criterion = :rook)
    @test Int(sum(Wr)) ÷ 2 == 12
    # Queen adds the diagonals: each of the four 2x2 blocks contributes 2, so
    # 12 + 8 = 20.
    Wq = contiguity(b; criterion = :queen)
    @test Int(sum(Wq)) ÷ 2 == 20

    degr = Int.(vec(sum(Wr; dims = 2)))
    degq = Int.(vec(sum(Wq; dims = 2)))
    # Corners 4, edges 4, centre 1. Rook: 2, 3, 4. Queen: 3, 5, 8.
    @test sort(degr) == sort([2, 3, 2, 3, 4, 3, 2, 3, 2])
    @test sort(degq) == sort([3, 5, 3, 5, 8, 5, 3, 5, 3])
    @test sum(degr) == 24 && sum(degq) == 40

    # Both are symmetric with an empty diagonal.
    @test Wq == Wq' && Wr == Wr'
    @test all(iszero, diag(Matrix(Wq)))

    # Row-standardising divides by the degree, so the centre row of the queen
    # matrix is eight eighths.
    Ws = contiguity(b; criterion = :queen, standardize = true)
    @test all(x -> isapprox(x, 1.0), vec(sum(Ws; dims = 2)))
    centre = 5
    @test count(!iszero, Ws[centre, :]) == 8
    @test all(isapprox(1 / 8), filter(!iszero, Ws[centre, :]))

    # Centroids of unit squares sit at their middles exactly.
    C = centroids(b)
    @test C[1, :] ≈ [0.5, 0.5]
    @test C[centre, :] ≈ [1.5, 1.5]
    @test C[9, :] ≈ [2.5, 2.5]

    # A one-cell lattice has no neighbours, and row-standardising must say so
    # rather than return NaN.
    one = grid_boundaries(1, 1)
    @test Int(sum(contiguity(one))) == 0
    @test_throws ArgumentError contiguity(one; standardize = true)
end

@testset "a lattice of separated squares has no neighbours" begin
    # Squares that touch nothing: hashing finds no shared vertex, which is the
    # signature of boundaries that are not a planar partition.
    codes = ["1001", "1002"]
    rings = [[[(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0), (0.0, 0.0)]],
             [[(5.0, 5.0), (6.0, 5.0), (6.0, 6.0), (5.0, 6.0), (5.0, 5.0)]]]
    b = MunicipalBoundaries(codes, ["a", "b"], rings)
    @test Int(sum(contiguity(b))) == 0
    err = try; contiguity(b; standardize = true); catch e; e; end
    @test err isa ArgumentError
    @test occursin("no neighbours", err.msg)
end

@testset "real CAOP boundaries" begin
    b = read_caop_geojson(CAOP6)
    @test length(b) == 6
    @test b.codes == ["1106", "1107", "1110", "1114", "1115", "1116"]
    @test b.names[1] == "Lisboa"
    @test b.names[4] == "Vila Franca de Xira"

    # Pinned from the source data: this subset has 9 queen links and 8 rook
    # links, and every degree is fixed.
    Wq = contiguity(b; criterion = :queen)
    Wr = contiguity(b; criterion = :rook)
    @test Int(sum(Wq)) ÷ 2 == 9
    @test Int(sum(Wr)) ÷ 2 == 8
    @test Int.(vec(sum(Wq; dims = 2))) == [5, 3, 2, 2, 3, 3]
    @test Int.(vec(sum(Wr; dims = 2))) == [4, 3, 2, 1, 3, 3]
    @test Wq == Wq' && Wr == Wr'
    @test count(iszero, vec(sum(Wq; dims = 2))) == 0

    # The whole point of the fixture: Lisboa and Vila Franca de Xira share a
    # vertex and not an edge, so they are queen neighbours and not rook ones.
    # Everything else is identical between the two criteria.
    li = 1; vfx = 4
    @test Wq[li, vfx] == 1.0
    @test Wr[li, vfx] == 0.0
    @test Int(sum(Wq - Wr)) ÷ 2 == 1
    ii, jj, _ = findnz(Wq - Wr)
    @test Set(zip(ii, jj)) == Set([(li, vfx), (vfx, li)])

    # Named neighbours, not just counts: Lisboa borders the other five.
    nb = neighbour_lists(b; criterion = :queen)
    @test sort(b.codes[nb[li]]) == ["1107", "1110", "1114", "1115", "1116"]
    # Oeiras touches only Lisboa and Amadora within this subset.
    @test sort(b.codes[nb[3]]) == ["1106", "1115"]
end

@testset "centroids land where they should" begin
    b = read_caop_geojson(CAOP6)
    C = centroids(b)
    @test size(C) == (6, 2)
    # Every centroid is inside the mainland's bounding box.
    @test all(-9.6 .< C[:, 1] .< -6.1)
    @test all(36.9 .< C[:, 2] .< 42.3)
    # Lisboa is a small, compact municipality, so its area centroid is within a
    # few hundredths of a degree of the city. The moment formula once divided
    # by 2*area where it should divide by 3*sum-of-cross-products, which put
    # every centroid at exactly half its coordinates -- (-4.58, 19.37) here,
    # a pair of numbers that looks nothing like Lisbon but would have fed a
    # distance weighting without complaint. Hence a pinned real coordinate.
    @test isapprox(C[1, 1], -9.14; atol = 0.05)
    @test isapprox(C[1, 2], 38.72; atol = 0.05)
    # Not the vertex mean: Lisboa's boundary is far more detailed along the
    # river, so the two differ.
    vs = [p for r in b.rings[1] for p in r]
    vmean = [sum(first, vs) / length(vs), sum(last, vs) / length(vs)]
    @test !isapprox(C[1, 1], vmean[1]; atol = 1e-6)
end

@testset "k nearest neighbours" begin
    b = read_caop_geojson(CAOP6)
    for k in (1, 2, 3)
        Wk = knn_contiguity(b, k)
        @test all(==(Float64(k)), vec(sum(Wk; dims = 2)))
        @test all(iszero, diag(Matrix(Wk)))
    end
    # Row-standardised, every row sums to one however many neighbours.
    @test all(x -> isapprox(x, 1.0),
              vec(sum(knn_contiguity(b, 3; standardize = true); dims = 2)))
    # k nearest is not symmetric in general, and on a 3x3 lattice with k = 3 it
    # is not: a corner's three nearest do not all have it among theirs.
    g = grid_boundaries(3, 3)
    @test knn_contiguity(g, 3) != knn_contiguity(g, 3)'
    # Bounds are refused by name.
    @test_throws ArgumentError knn_contiguity(b, 0)
    @test_throws ArgumentError knn_contiguity(b, 6)
end

@testset "GAL output is readable and says what it should" begin
    b = read_caop_geojson(CAOP6)
    path = tempname() * ".gal"
    write_gal(path, b; criterion = :queen)
    lines = readlines(path)
    # Header, then two lines per unit.
    @test length(lines) == 1 + 2 * 6
    hdr = split(lines[1])
    @test hdr[1] == "0" && hdr[2] == "6" && hdr[4] == "dtmn"
    # Lisboa's block: its code, its degree, then its five neighbours.
    @test split(lines[2]) == ["1106", "5"]
    @test sort(split(lines[3])) == ["1107", "1110", "1114", "1115", "1116"]
    # Degrees in the file match the matrix.
    deg = Int.(vec(sum(contiguity(b; criterion = :queen); dims = 2)))
    for i in 1:6
        @test parse(Int, split(lines[2i])[2]) == deg[i]
        @test length(split(lines[2i + 1])) == deg[i]
    end
    # Named ids are available, and differ from codes.
    p2 = tempname() * ".gal"
    write_gal(p2, b; criterion = :queen, id = :name)
    @test split(readlines(p2)[1])[4] == "municipio"
    @test startswith(readlines(p2)[2], "Lisboa")
    rm(path); rm(p2)
    @test_throws ArgumentError write_gal(tempname(), b; id = :nonsense)
end

@testset "bad input is refused by name" begin
    b = read_caop_geojson(CAOP6)
    @test_throws ArgumentError neighbour_lists(b; criterion = :bishop)
    # A file that is not a FeatureCollection.
    notfc = tempname() * ".json"
    write(notfc, "{\"type\":\"Point\",\"coordinates\":[0,0]}")
    @test_throws ArgumentError read_caop_geojson(notfc)
    # A feature whose code property is missing or malformed.
    nocode = tempname() * ".json"
    write(nocode, "{\"type\":\"FeatureCollection\",\"features\":[{\"properties\":{\"x\":1}," *
                  "\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[0,0],[1,0],[1,1],[0,0]]]}}]}")
    @test_throws ArgumentError read_caop_geojson(nocode)
    badcode = tempname() * ".json"
    write(badcode, "{\"type\":\"FeatureCollection\",\"features\":[{\"properties\":{\"dtmn\":\"11\"}," *
                   "\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[0,0],[1,0],[1,1],[0,0]]]}}]}")
    @test_throws ArgumentError read_caop_geojson(badcode)
    rm(notfc); rm(nocode); rm(badcode)
end

@testset "the DGT attribution travels with the data" begin
    # CAOP is CC-BY-4.0 and the credit is a licence condition, so the string is
    # part of the package rather than a line in a README someone may not read.
    @test occursin("Direção-Geral do Território", CAOP_ATTRIBUTION)
    @test occursin("CC-BY-4.0", CAOP_ATTRIBUTION)
end
