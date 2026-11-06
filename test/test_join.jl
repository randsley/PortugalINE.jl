# Layer 4: the join.
#
# The join is where a wrong answer is quietest. Nothing throws if the key is
# wrong -- rows simply go missing -- and nothing throws if a row-standardised
# matrix is sliced instead of rebuilt; the estimates just drift. So these tests
# do two things beyond checking the happy path.
#
# First, they measure the alternatives. The claim that the DICO is the right
# key is tested by joining two real extracts on all three candidates and
# counting the matches, so the figure in the documentation is the figure the
# suite enforces.
#
# Second, they assert the rebuilt matrix differs from the sliced one. A test
# that only checked "rows sum to one" would pass on either, because slicing a
# standardised matrix leaves the untouched rows summing to one and only breaks
# the rows next to what was dropped.

using PortugalINE, Test, SparseArrays
using PortugalINE.Boundaries: MunicipalBoundaries

const JFIX = joinpath(@__DIR__, "fixtures")
const JCACHE = mktempdir()
cache_response!(joinpath(JFIX, "ine_data_0014580.json"), :data, "0014580";
                period = "S7A2023", dir = JCACHE)
cache_response!(joinpath(JFIX, "ine_data_0008074_T2022.json"), :data, "0008074";
                period = "S7A2022", dimensions = Dict(3 => "T"), dir = JCACHE)

pp_data = indicator_data("0014580"; period = "S7A2023", cache = JCACHE)
cr_data = indicator_data("0008074"; period = "S7A2022",
                         dimensions = Dict(3 => "T"), cache = JCACHE)
lisboa6 = read_caop_geojson(joinpath(JFIX, "caop_lisboa6.json"))

@testset "the DICO is the key, and the alternatives are counted" begin
    # 0014580 is published on NUTS 2024 and 0008074 on NUTS 2013. Both carry
    # all 308 municipalities, so every shortfall below is a key failing, not
    # missing data.
    a = municipal_values(pp_data)
    b = municipal_values(cr_data)
    @test length(a.dico) == 308 && length(b.dico) == 308

    ia = Dict(a.dico .=> eachindex(a.dico))
    ib = Dict(b.dico .=> eachindex(b.dico))
    common = sort(collect(intersect(Set(a.dico), Set(b.dico))))

    # DICO: everything.
    @test length(common) == 308

    # NUTS code: 132. A join on the identifier INE returns first would lose
    # 176 municipalities, 57% of the country, without raising anything.
    @test count(d -> a.geocod[ia[d]] == b.geocod[ib[d]], common) == 132
    @test a.geocod[ia["1106"]] == "1A01106"      # Lisboa, NUTS 2024
    @test b.geocod[ib["1106"]] == "1701106"      # Lisboa, NUTS 2013

    # Name: 305, which is worse than it looks. The three mismatches are the
    # disambiguating suffix, and without it the name is not even unique --
    # Calheta is 3101 in Madeira and 4501 in the Azores.
    @test count(d -> a.name[ia[d]] == b.name[ib[d]], common) == 305
    @test a.name[ia["3101"]] == "Calheta (R.A.M.)"
    @test b.name[ib["3101"]] == "Calheta"
    @test b.name[ib["4501"]] == "Calheta"
    @test length(unique(b.name)) < 308           # names are not a key at all

    # And the DICO really is the tail of both codes.
    @test all(d -> endswith(a.geocod[ia[d]], d) && endswith(b.geocod[ib[d]], d),
              common)
end

@testset "a join of two indicators onto real boundaries" begin
    ds = join_municipal(lisboa6, :purchasing_power => pp_data,
                        :crime_rate => cr_data)
    @test ds isa MunicipalDataset
    @test length(ds) == 6

    # DICO order, which is the order of every other field and of the GAL file.
    @test ds.dico == ["1106", "1107", "1110", "1114", "1115", "1116"]
    @test issorted(ds.dico)
    @test ds.name == ["Lisboa", "Loures", "Oeiras", "Vila Franca de Xira",
                      "Amadora", "Odivelas"]
    @test ds.boundaries.codes == ds.dico

    @test keys(ds.columns) == (:purchasing_power, :crime_rate)
    @test ds.columns.purchasing_power ==
          [181.35, 100.74, 150.05, 99.88, 102.65, 96.08]
    @test ds.columns.crime_rate == [50.9, 28.0, 23.8, 23.6, 33.3, 18.5]
    @test eltype(ds.columns.purchasing_power) == Union{Float64, Missing}

    # Provenance is per column and in column order. This mattered: pairing the
    # names with a sorted unique list of codes attributed 0008074 to
    # purchasing_power, which would have been written into a provenance file
    # and believed.
    @test ds.varcds == ["0014580", "0008074"]
    @test ds.periods == ["2023", "2022"]
    @test first(ds.extracted, 10) == "2026-11-06"

    # The NUTS codes are kept per column, which is what makes the vintage
    # visible rather than merely survivable.
    @test ds.nuts.purchasing_power[1] == "1A01106"
    @test ds.nuts.crime_rate[1] == "1701106"

    # The adjacency matches layer 3's own fixture: 9 queen links over these six.
    @test Int(sum(ds.adjacency)) ÷ 2 == 9
    @test ds.adjacency == ds.adjacency'
    @test all(iszero, diag(Matrix(ds.adjacency)))
    @test ds.criterion == :queen
    # Binary, not standardised, deliberately.
    @test all(x -> x == 1.0, nonzeros(ds.adjacency))

    @test Int(sum(join_municipal(lisboa6, :pp => pp_data;
                                 criterion = :rook).adjacency)) ÷ 2 == 8
end

@testset "what the join dropped, and why it is split three ways" begin
    ds = join_municipal(lisboa6, :purchasing_power => pp_data)
    d = dropped(ds)
    # No boundary here lacks data.
    @test isempty(d.geometry)
    # 30 islands, which is expected and is not a fault.
    @test length(d.islands) == 30
    # The island districts, pinned as a set rather than listed from memory --
    # 32 is Porto Santo, which an enumeration of "Madeira and the Azores"
    # written out by hand leaves out.
    @test sort(unique(c[1:2] for c in d.islands)) ==
          ["31", "32", "41", "42", "43", "44", "45", "46", "47", "48", "49"]
    @test "3201" in d.islands
    # The rest: 308 municipalities of data against 6 boundaries.
    @test length(d.data) == 272
    @test length(d.islands) + length(d.data) == 302
    @test length(d.data) + length(d.islands) + length(ds) == 308

    # Islands and the rest are counted apart because only the second kind
    # indicates a problem, and the notes say which is which.
    ns = notes(ds)
    @test any(n -> occursin("island municipalities have data but no boundary", n), ns)
    @test any(n -> occursin("non-island", n) && occursin("deliberate", n), ns)
end

@testset "the vintage disagreement is reported, not just survived" begin
    ds = join_municipal(lisboa6, :purchasing_power => pp_data,
                        :crime_rate => cr_data)
    ns = notes(ds)
    v = ns[findfirst(n -> occursin("NUTS vintages", n), ns)]
    @test occursin("different NUTS code", v)
    @test occursin("for 6 of 6", v)
    @test occursin("DICO join matched all 6", v)
    @test occursin("NUTS code would have matched 0", v)

    # And the name disagreement, on a pair where it actually occurs. These six
    # are mainland, so their names agree; the note must be absent rather than
    # fabricated.
    @test !any(n -> occursin("differ between the first indicator", n), ns)
end

@testset "standardising happens last, and the matrix is rebuilt not sliced" begin
    ds = join_municipal(lisboa6, :purchasing_power => pp_data)
    W = spatial_weights(ds)
    @test all(x -> isapprox(x, 1.0), vec(sum(W; dims = 2)))
    @test spatial_weights(ds; standardize = false) == ds.adjacency

    # Drop Oeiras (row 3) by making its value missing, then ask for a model
    # matrix. The surviving matrix must be rebuilt over five units.
    col = copy(ds.columns.purchasing_power); col[3] = missing
    holed = MunicipalDataset(ds.dico, ds.name, (purchasing_power = col,),
                             ds.nuts, ds.boundaries, ds.adjacency, ds.criterion,
                             ds.varcds, ds.periods, ds.extracted,
                             ds.dropped_geometry, ds.dropped_data,
                             ds.dropped_islands, ds.notes)
    m = model_matrix(holed, :purchasing_power)
    @test m.dropped == ["1110"]
    @test m.dico == ["1106", "1107", "1114", "1115", "1116"]
    @test length(m.y) == 5
    @test size(m.W) == (5, 5)
    @test all(x -> isapprox(x, 1.0), vec(sum(m.W; dims = 2)))

    # The point: slicing the standardised matrix is not the same answer. Rows
    # that lost a neighbour no longer sum to one, and this is the failure a
    # "rows sum to one" check misses, because the untouched rows still do.
    keep = [1, 2, 4, 5, 6]
    sliced = W[keep, keep]
    @test !all(x -> isapprox(x, 1.0), vec(sum(sliced; dims = 2)))
    @test sliced != m.W
    # Lisboa and Amadora both bordered Oeiras, so both differ; Loures did not.
    @test sum(sliced[1, :]) < 0.999
    @test isapprox(sum(sliced[2, :]), 1.0)
end

@testset "model_matrix" begin
    ds = join_municipal(lisboa6, :purchasing_power => pp_data,
                        :crime_rate => cr_data)
    m = model_matrix(ds, :purchasing_power, :crime_rate)
    @test m.y == ds.columns.purchasing_power
    @test size(m.X) == (6, 1)
    @test m.X[:, 1] == ds.columns.crime_rate
    @test m.xnames == ["crime_rate"]
    @test m.dico == ds.dico
    @test isempty(m.dropped)
    @test eltype(m.y) == Float64 && eltype(m.X) == Float64

    mi = model_matrix(ds, :purchasing_power, :crime_rate; intercept = true)
    @test size(mi.X) == (6, 2)
    @test all(==(1.0), mi.X[:, 1])
    @test mi.xnames == ["intercept", "crime_rate"]

    # A response with no regressors is legitimate: Moran's I needs only y and W.
    m0 = model_matrix(ds, :purchasing_power)
    @test size(m0.X) == (6, 0)
    @test length(m0.y) == 6

    @test_throws ArgumentError model_matrix(ds, :nonexistent)
    @test_throws ArgumentError model_matrix(ds, :purchasing_power, :nope)
    @test_throws ArgumentError model_matrix(ds, :purchasing_power,
                                            :purchasing_power)
    # Every row incomplete is an error, not a zero-row matrix.
    allmiss = MunicipalDataset(ds.dico, ds.name,
                               (c = Union{Float64, Missing}[missing for _ in 1:6],),
                               ds.nuts, ds.boundaries, ds.adjacency,
                               ds.criterion, ["0014580"], ["2023"],
                               ds.extracted, String[], String[], String[],
                               String[])
    @test_throws ArgumentError model_matrix(allmiss, :c)
end

@testset "an isolated unit is named, not divided by zero" begin
    # Two municipalities that do not touch: Oeiras (1110) and Vila Franca de
    # Xira (1114) border Lisboa but not each other.
    pick = [findfirst(==(c), lisboa6.codes) for c in ("1110", "1114")]
    pair = MunicipalBoundaries(lisboa6.codes[pick], lisboa6.names[pick],
                               lisboa6.rings[pick])
    ds = join_municipal(pair, :purchasing_power => pp_data)
    @test length(ds) == 2
    @test Int(sum(ds.adjacency)) == 0
    @test any(n -> occursin("no neighbours after the join", n), notes(ds))

    e = try; spatial_weights(ds); catch e; e; end
    @test e isa ArgumentError
    @test occursin("cannot row-standardise", e.msg)
    @test occursin("1110", e.msg)
    # Unstandardised is still available, since that is a legitimate choice.
    @test Int(sum(spatial_weights(ds; standardize = false))) == 0

    # And model_matrix refuses for the same reason, naming the unit.
    e2 = try; model_matrix(ds, :purchasing_power); catch e; e; end
    @test e2 isa ArgumentError && occursin("no neighbours", e2.msg)
    @test size(model_matrix(ds, :purchasing_power; standardize = false).W) == (2, 2)
end

@testset "dropping incomplete rows can isolate a unit, and that is caught" begin
    # Oeiras touches only Lisboa and Amadora among these six. Hole both and
    # Oeiras is cut off, so the rebuilt matrix cannot be standardised -- a
    # failure that cannot happen if the matrix is merely sliced, which is the
    # whole argument for rebuilding.
    ds = join_municipal(lisboa6, :purchasing_power => pp_data)
    col = copy(ds.columns.purchasing_power)
    col[1] = missing; col[5] = missing      # Lisboa, Amadora
    holed = MunicipalDataset(ds.dico, ds.name, (v = col,), ds.nuts,
                             ds.boundaries, ds.adjacency, ds.criterion,
                             ds.varcds[1:1], ds.periods[1:1], ds.extracted,
                             String[], String[], String[], String[])
    e = try; model_matrix(holed, :v); catch e; e; end
    @test e isa ArgumentError
    @test occursin("incomplete row", e.msg)
    @test occursin("no neighbours", e.msg)
    @test occursin("1110", e.msg)           # Oeiras, named
    # Unstandardised still returns, with Oeiras' row empty and visible.
    m = model_matrix(holed, :v; standardize = false)
    @test length(m.y) == 4
    @test count(iszero, vec(sum(m.W; dims = 2))) == 1
end

@testset "bad joins are refused with the reason" begin
    @test_throws ArgumentError join_municipal(lisboa6)
    @test_throws ArgumentError join_municipal(lisboa6, :a => pp_data,
                                              :a => cr_data)
    @test_throws ArgumentError join_municipal(lisboa6, :a => pp_data;
                                              criterion = :bishop)
    @test_throws ArgumentError join_municipal(lisboa6, "a" => pp_data)
    @test_throws ArgumentError join_municipal(lisboa6, :a => "not data")

    # A multi-period extract must say which period the column holds, rather
    # than having one chosen for it.
    multi = IndicatorData("0014580", "x", ["2021", "2023"], "", "",
                          pp_data.table)
    e = try; join_municipal(lisboa6, :a => multi); catch e; e; end
    @test e isa ArgumentError && occursin("covers 2 periods", e.msg)

    # No overlap at all explains the likely cause rather than returning
    # nothing: boundaries keyed on something that is not a DICO.
    wrong = MunicipalBoundaries(["9901", "9902"], ["x", "y"],
                                [lisboa6.rings[1], lisboa6.rings[2]])
    e2 = try; join_municipal(wrong, :a => pp_data); catch e; e; end
    @test e2 isa ArgumentError
    @test occursin("no municipality is present in both", e2.msg)
    @test occursin("NUTS code", e2.msg)
end

@testset "write_dataset is the handoff" begin
    ds = join_municipal(lisboa6, :purchasing_power => pp_data,
                        :crime_rate => cr_data)
    out = mktempdir()
    files = write_dataset(out, ds; name = "lisboa6")
    @test length(files) == 4
    @test all(isfile, files)
    @test basename.(files) == ["lisboa6.csv", "lisboa6_queen.gal",
                               "lisboa6_centroids.csv",
                               "lisboa6_PROVENANCE.md"]

    csv = readlines(files[1])
    @test csv[1] == "dico,name,purchasing_power,crime_rate"
    @test length(csv) == 7
    @test csv[2] == "1106,Lisboa,181.35,50.9"
    # Row order is DICO order, the same as the GAL file's.
    @test [split(l, ',')[1] for l in csv[2:end]] == ds.dico

    gal = readlines(files[2])
    @test length(gal) == 1 + 2 * 6
    @test split(gal[1])[2] == "6"
    @test split(gal[2]) == ["1106", "5"]
    @test [split(gal[2i])[1] for i in 1:6] == ds.dico

    cen = readlines(files[3])
    @test cen[1] == "dico,name,lon,lat"
    @test length(cen) == 7
    lon = parse(Float64, split(cen[2], ',')[3])
    @test isapprox(lon, -9.14; atol = 0.05)      # Lisboa

    prov = read(files[4], String)
    # The citation both licences require, in the file that travels with the data.
    @test occursin("Statistics Portugal (INE), indicators 0008074, 0014580", prov)
    @test occursin("Direção-Geral do Território", prov)
    @test occursin("CC-BY-4.0", prov)
    @test occursin("2019/1024", prov)
    # Per-column provenance, correctly paired. The table is the regression
    # test for the mapping bug: purchasing_power is 0014580 and not 0008074.
    @test occursin("| `purchasing_power` | 0014580 | 2023 | 0 |", prov)
    @test occursin("| `crime_rate` | 0008074 | 2022 | 0 |", prov)
    @test occursin("binary and not row-standardised", prov)
    @test occursin("island units with no boundary | 30", prov)
    # Every note from the join is carried through.
    @test all(n -> occursin(n, prov), notes(ds))

    # The files it writes are optional, and the CSV is not.
    only_csv = write_dataset(mktempdir(), ds; name = "x", gal = false,
                             centroids_file = false)
    @test length(only_csv) == 2
    @test basename.(only_csv) == ["x.csv", "x_PROVENANCE.md"]
end

@testset "missing values survive to the CSV as empty, not as a number" begin
    ds = join_municipal(lisboa6, :purchasing_power => pp_data)
    col = copy(ds.columns.purchasing_power); col[2] = missing
    holed = MunicipalDataset(ds.dico, ds.name, (pp = col,), ds.nuts,
                             ds.boundaries, ds.adjacency, ds.criterion,
                             ["0014580"], ["2023"], ds.extracted,
                             String[], String[], String[], String[])
    f = write_dataset(mktempdir(), holed; name = "h", gal = false,
                      centroids_file = false)
    csv = readlines(f[1])
    @test csv[3] == "1107,Loures,"
    @test occursin("| `pp` | 0014580 | 2023 | 1 |", read(f[2], String))
end

@testset "a name with a comma is quoted" begin
    ds = join_municipal(lisboa6, :purchasing_power => pp_data)
    odd = MunicipalDataset(ds.dico, ["A, B"; ds.name[2:end]],
                           ds.columns, ds.nuts, ds.boundaries, ds.adjacency,
                           ds.criterion, ["0014580"], ["2023"], ds.extracted,
                           String[], String[], String[], String[])
    f = write_dataset(mktempdir(), odd; name = "q", gal = false,
                      centroids_file = false)
    @test readlines(f[1])[2] == "1106,\"A, B\",181.35"
end

@testset "show says what the dataset is" begin
    ds = join_municipal(lisboa6, :purchasing_power => pp_data,
                        :crime_rate => cr_data)
    s = sprint(show, MIME"text/plain"(), ds)
    @test occursin("6 municipalities, 2 indicators", s)
    @test occursin("queen contiguity, 9 links", s)
    @test occursin("mean degree 3.000", s)
    @test occursin("INE 0014580, 0008074", s)
    @test occursin("purchasing_power", s)
    # Notes are printed, because a note nobody reads is a note nobody acts on.
    @test occursin("island municipalities", s)
    @test occursin("MunicipalDataset(6 municipalities", sprint(show, ds))
end
