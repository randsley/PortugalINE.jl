# Panels: the same units over several periods, one weights matrix.
#
# The boundaries are the ten real CAOP2024 parishes of Amadora and Odivelas
# (`b10`, from test_parishes.jl). The extracts are built here, because what is
# under test is the bookkeeping -- which units survive, which are dropped and
# why, how the periods stack -- and that needs every case in one small panel:
# an island row, an empty listing of the other parish map, a value with no
# boundary, a suppressed cell, a unit absent from one period.

using PortugalINE, Test, SparseArrays
using PortugalINE: IndicatorData

const PB = read_caop_geojson(joinpath(@__DIR__, "fixtures",
                                      "caop2024_freguesias_amadora_odivelas.json");
                             level = :parish, edition = "CAOP2024")
const K = PB.codes   # 111512 ... 111610, ten parishes

# One extract over several periods, 9-character codes, as an unfiltered request
# returns it.
function extract(varcd, rows; dims = Dict{Int, String}(), extracted = "2026-11-26T10:00:00Z")
    per = String[]; geo = String[]; nm = String[]; val = Union{Float64, Missing}[]
    for (p, code, v) in rows
        push!(per, p); push!(geo, code); push!(nm, "n" * code[end-5:end]); push!(val, v)
    end
    t = (period = per, geocod = geo, geodsg = nm, value = val)
    IndicatorData(varcd, "x", sort(unique(per)), "", extracted, t, "PT", dims, "u")
end

inc_rows = Tuple{String, String, Union{Float64, Missing}}[(p, "1A0" * k, 1000.0 * i + parse(Int, p)) for p in ("2018", "2019")
                                                        for (i, k) in enumerate(K)]
append!(inc_rows, [("2018", "300310101", 5.0), ("2019", "300310101", 6.0),  # an island parish
                   ("2018", "1A0111599", missing), ("2019", "1A0111599", missing),  # other map, empty
                   ("2018", "1A0111598", 7.0)])                              # a value, no boundary
INC = extract("0012748", inc_rows)

# Births as two single-period extracts, bare codes, filtered to both sexes; one
# suppressed cell (111512 in 2019).
bir(p) = extract("0008234", [(p, k, (p == "2019" && k == "111512") ? missing : Float64(i))
                             for (i, k) in enumerate(K)];
                 dims = Dict(3 => "T"), extracted = "2026-11-20T10:00:00Z")
BIR = [bir("2018"), bir("2019")]

@testset "the units present everywhere, by period" begin
    p = join_panel(PB, :income => INC, :births => BIR; periods = ["2018", "2019"])
    # The exported ine_citation, not a function of Panel's own (it was, once).
    @test occursin("0012748", ine_citation(p)) && which(ine_citation, (typeof(p),)).module === PortugalINE.Panel
    # A column with no extraction date: the citation is refused, naming it,
    # not printed without the date.
    pu = join_panel(PB, :income => INC, :births => [bir("2018"), extract("0008234", [("2019", k, 1.0) for k in K];
                    dims = Dict(3 => "T"), extracted = "")]; periods = ["2018", "2019"])
    @test_throws r"births.*INE's citation needs one" ine_citation(pu)
    @test p.keys == K
    @test p.periods == ["2018", "2019"]
    @test size(p.columns.income) == (10, 2) && size(p.columns.births) == (10, 2)
    @test p.columns.income[3, 2] == 3000.0 + 2019
    @test ismissing(p.columns.births[1, 2]) && p.columns.births[1, 1] == 1.0
    @test p.adjacency == contiguity(PB)
    # What was left out, four ways.
    d = dropped(p)
    @test d.islands == ["310101"]
    @test d.empty == ["111599"]
    @test d.data == ["111598"]
    @test isempty(d.geometry)
    @test any(n -> occursin("another map", n), notes(p))
    # Provenance per column: the filter, the language, the earliest extraction.
    @test p.varcds == ["0012748", "0008234"]
    @test p.filters == [Dict{Int, String}(), Dict(3 => "T")]
    @test p.languages == ["PT", "PT"]
    @test p.column_extracted == ["2026-11-26T10:00:00Z", "2026-11-20T10:00:00Z"]
    @test occursin("10 parishes x 2 periods", sprint(show, MIME("text/plain"), p))
end

@testset "a unit absent from one period is dropped from all, and named" begin
    short = [bir("2018"), extract("0008234", [("2019", k, 1.0) for k in K[1:9]];
                                  dims = Dict(3 => "T"))]
    p = join_panel(PB, :income => INC, :births => short; periods = ["2018", "2019"])
    @test p.keys == K[1:9]
    @test dropped(p).geometry == [K[10]]
    @test any(n -> occursin("no births row in 2019: $(K[10])", n), notes(p))
    @test size(p.adjacency) == (9, 9)
    # One period only: the unit is back.
    @test join_panel(PB, :income => INC, :births => short; periods = ["2018"]).keys == K
end

@testset "a column is one indicator with one filter, each period once" begin
    other = extract("0012748", [("2019", k, 1.0) for k in K]; dims = Dict(3 => "H"))
    @test_throws ArgumentError join_panel(PB, :b => [bir("2018"), other]; periods = ["2018"])
    mixed = extract("0099999", [("2019", k, 1.0) for k in K])
    @test_throws ArgumentError join_panel(PB, :b => [bir("2018"), mixed]; periods = ["2018"])
    @test_throws ArgumentError join_panel(PB, :b => [bir("2018"), bir("2018")]; periods = ["2018"])
    e = try; join_panel(PB, :b => BIR; periods = ["2018", "2020"]); catch e; e; end
    @test e isa ArgumentError && occursin("covers period \"2020\"", e.msg)
    @test_throws ArgumentError join_panel(PB, :b => BIR; periods = String[])
    @test_throws ArgumentError join_panel(PB, :b => BIR; periods = ["2018", "2018"])
    @test_throws ArgumentError join_panel(PB, :b => BIR, :b => BIR; periods = ["2018"])
    @test_throws ArgumentError join_panel(PB, :b => "nonsense"; periods = ["2018"])
end

@testset "panel_matrices stacks by period and rebuilds W" begin
    p = join_panel(PB, :income => INC, :births => BIR; periods = ["2018", "2019"])
    m = panel_matrices(p, :births, :income; intercept = true)
    # 111512 is suppressed in 2019, so it goes from both periods.
    @test m.dropped == ["111512"]
    @test m.keys == K[2:10]
    @test (m.N, m.T) == (9, 2)
    @test length(m.y) == 18 && size(m.X) == (18, 2)
    # Period-major: the first N are 2018 for every unit, then 2019.
    @test m.y[1:9] == Float64.(2:10) && m.y[10:18] == Float64.(2:10)
    @test m.X[1, 2] == 2000.0 + 2018 && m.X[10, 2] == 2000.0 + 2019
    @test m.X[:, 1] == ones(18) && m.xnames == ["intercept", "income"]
    # W over the nine, rebuilt, not sliced from the ten.
    @test size(m.W) == (9, 9)
    @test all(sum(m.W; dims = 2) .≈ 1)
    A9 = contiguity(PB[2:10])
    @test m.W == A9 ./ vec(sum(A9; dims = 2))
    # Restricting the periods brings 111512 back.
    @test panel_matrices(p, :births, :income; periods = ["2018"]).N == 10
    @test_throws ArgumentError panel_matrices(p, :births, :nope)
    @test_throws ArgumentError panel_matrices(p, :births, :births)
    @test_throws ArgumentError panel_matrices(p, :births; periods = ["2017"])
end

@testset "write_panel: long CSV, one GAL, provenance" begin
    p = join_panel(PB, :income => INC, :births => BIR; periods = ["2018", "2019"])
    files = write_panel(mktempdir(), p; name = "pp", coordinate_names = ("x_m", "y_m"))
    @test basename.(files) == ["pp.csv", "pp_queen.gal", "pp_centroids.csv", "pp_PROVENANCE.md"]
    csv = readlines(files[1])
    @test csv[1] == "dicofre,name,period,income,births"
    @test length(csv) == 1 + 20
    @test startswith(csv[2], "111512,n111512,2018,")
    # Whole numbers as INE publishes them, without ".0".
    @test csv[2] == "111512,n111512,2018,3018,1"
    @test startswith(csv[12], "111512,n111512,2019,") && endswith(csv[12], ",")   # suppressed
    @test length(readlines(files[3])) == 11
    @test startswith(readline(files[2]), "0 10 freguesias dtmnfr")
    prov = read(files[4], String)
    @test occursin("**10 parishes x 2 periods**", prov)
    @test occursin("| `births` | 0008234 | Dim3=T | PT | 2026-11-20 | 1 |", prov)
    @test occursin("| units of another map (no value, no boundary) | 1 |", prov)
    @test occursin("| CAOP edition | CAOP2024 |", prov)
    @test occursin("reference periods 2018 to 2019", prov)
    @test occursin("Direção-Geral do Território", prov)
end
