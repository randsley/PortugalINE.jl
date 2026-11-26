# Layer 5: parishes (freguesias).
#
# The fixtures are real. Two INE responses pulled 2026-11-25: indicator 0012748
# (gross declared income per taxpayer, 2024), which gives 9-character codes
# with a NUTS III prefix, and 0012328 (unemployment rate, Census 2021, both
# sexes), which gives the bare 6-character DICOFRE. And the ten parishes of
# Amadora (1115) and Odivelas (1116) from DGT's CAOP2024 GeoPackage
# (CC-BY-4.0), converted by scripts/caop_gpkg_to_geojson.py with the EPSG:3763
# coordinates unchanged. CAOP2024 and not the current CAOP2025: INE's parish
# figures are on the parish map of the 2013 reform, which CAOP2024.1 and later
# no longer carry.

using PortugalINE, Test, SparseArrays
using PortugalINE.Boundaries: MunicipalBoundaries

const PFIX = joinpath(@__DIR__, "fixtures")
const PCACHE = mktempdir()
cache_response!(joinpath(PFIX, "ine_data_0012748_2024.json"), :data, "0012748";
                period = "S7A2024", dir = PCACHE)
cache_response!(joinpath(PFIX, "ine_data_0012328_2021_T.json"), :data, "0012328";
                period = "S7A2021", dimensions = Dict(3 => "T"), dir = PCACHE)
inc = indicator_data("0012748"; period = "S7A2024", cache = PCACHE)
une = indicator_data("0012328"; period = "S7A2021", dimensions = Dict(3 => "T"),
                     cache = PCACHE)
b10 = read_caop_geojson(joinpath(PFIX, "caop2024_freguesias_amadora_odivelas.json");
                        level = :parish)

@testset "parish codes in both of INE's forms" begin
    @test geolevel("11C130741") == PARISH
    @test geolevel("130741") == PARISH
    @test isparish("1A0111603") && isparish("111603")
    @test !isparish("1111601") && !isparish("1116")
    @test dicofre("1A0111603") == "111603" == dicofre("111603")
    @test district("1A0111603") == 11 && district("111603") == 11
    @test isisland("200420602")                  # Ponta Garça, Azores
    @test ismainland("130741")
    @test nuts3("1A0111603") == "1A0"
    @test_throws ArgumentError nuts3("111603")   # the bare form has no prefix
    @test_throws ArgumentError dico("111603")    # a parish is not a municipality
    @test_throws ArgumentError dicofre("1111601")
    @test_throws ArgumentError dicofre("11211XX02")
    # Barcelos (0302) coded its eight 2013 unions with letters. A six-digit
    # check dropped them; this is the case that found it.
    @test dicofre("1120302FA") == "0302FA" && isparish("0302FA")
    @test geolevel("0302FH") == PARISH
end

@testset "parish_values reads both forms to one key" begin
    a = parish_values(inc)
    c = parish_values(une)
    @test length(a.dicofre) == 3092 == length(c.dicofre)
    @test a.dicofre == c.dicofre                   # same parishes, same order
    @test issorted(a.dicofre)
    @test count(ismainland, a.dicofre) == 2882
    @test count(d -> !all(isdigit, d), a.dicofre) == 8      # the Barcelos unions
    @test all(==(9), length.(a.geocod)) && all(==(6), length.(c.geocod))
    @test count(i -> a.name[i] == c.name[i], eachindex(a.name)) == 3092
    @test count(ismissing, a.value) == 0 && count(ismissing, c.value) == 0
    i = searchsortedfirst(a.dicofre, "111603")
    @test a.geocod[i] == "1A0111603" && a.name[i] == "Odivelas"
    @test a.value[i] == 17156.0 && c.value[i] == 8.3
    # The bare 4-digit municipal rows of the Census form were dropped by
    # municipal_values before the bare forms were recognised.
    m = municipal_values(une)
    @test length(m.dico) == 308 && m.geocod[1] == "0101"
    # Power: the municipal reader does not see parishes, and vice versa.
    @test all(ismunicipality, municipal_values(inc).geocod)
    @test !any(ismunicipality, a.geocod)
end

@testset "parish boundaries and their contiguity" begin
    @test b10.level === :parish && length(b10) == 10
    @test b10.codes == ["111512", "111513", "111514", "111515", "111516",
                        "111517", "111603", "111608", "111609", "111610"]
    A = contiguity(b10)
    @test nnz(A) == 30 && A == A'
    @test nnz(contiguity(b10; criterion = :rook)) == 30
    nb = neighbour_lists(b10)
    # Across the municipal border: Encosta do Sol and Mina de Água (Amadora)
    # touch Pontinha e Famões (Odivelas).
    @test b10.codes[nb[8]] == ["111514", "111516", "111603", "111610"]
    @test b10.codes[nb[9]] == ["111603"]
    # The planar-partition claim, at parish level and in metres: rounding the
    # vertices to the millimetre leaves the graph unchanged.
    r = MunicipalBoundaries(b10.codes, b10.names,
        [[[(round(x; digits = 3), round(y; digits = 3)) for (x, y) in rg] for rg in rs]
         for rs in b10.rings], :parish)
    @test contiguity(r) == A
    @test occursin("10 parishes", sprint(show, b10))
    # Power: the municipal reader refuses parish codes, and the parish reader
    # refuses municipal ones.
    @test_throws ArgumentError read_caop_geojson(
        joinpath(PFIX, "caop2024_freguesias_amadora_odivelas.json"); code_property = "dtmnfr")
    @test_throws ArgumentError read_caop_geojson(
        joinpath(PFIX, "caop_lisboa6.json"); level = :parish, code_property = "dtmn")
    @test_throws ArgumentError read_caop_geojson(
        joinpath(PFIX, "caop_lisboa6.json"); level = :county)
end

@testset "the parish join, and what it writes" begin
    ds = join_municipal(b10, :income => inc, :unemployment => une)
    @test length(ds) == 10 && ds.dico == b10.codes
    @test ds.boundaries.level === :parish
    @test ds.columns.income[7] == 17156.0 && ds.columns.unemployment[7] == 8.3
    @test length(dropped(ds).islands) == 210
    @test length(dropped(ds).data) == 2872
    @test any(n -> occursin("bare code with no NUTS prefix", n), notes(ds))
    @test !any(n -> occursin("NUTS vintages", n), notes(ds))
    @test occursin("10 parishes", sprint(show, MIME("text/plain"), ds))
    dir = mktempdir()
    files = write_dataset(dir, ds; name = "pt_parishes", coordinate_names = ("x_m", "y_m"))
    @test readline(files[1]) == "dicofre,name,income,unemployment"
    @test startswith(readline(files[2]), "0 10 freguesias dtmnfr")
    @test readline(files[3]) == "dicofre,name,x_m,y_m"
    prov = read(files[4], String)
    @test occursin("**10 parishes**", prov)
    @test occursin("Direção-Geral do Território", prov)     # CAOP's CC-BY credit
    # The GAL round-trips to the same graph, ordered by DICOFRE.
    gal = readlines(files[2])
    @test gal[2] == "111512 2" && gal[3] == "111513 111517"
    m = model_matrix(ds, :income, :unemployment)
    @test size(m.X) == (10, 1) && all(sum(m.W; dims = 2) .≈ 1)
end

@testset "residence abroad is not a parish" begin
    # 0008234 (live births) carries "Estrangeiro" as 000000000 / 000000. District
    # 00 does not exist; before this, ismainland (district <= 18) took it for a
    # mainland parish, so it sat among the 2,882 as a 2,883rd.
    @test !isparish("000000000") && !isparish("000000")
    @test !ismunicipality("0000000") && !ismunicipality("0000")
    @test isparish("11C130741") && isparish("130741")
    @test_throws ArgumentError ismainland("000000000")
    @test_throws ArgumentError isisland("000000000")
    # The district ranges are bounded on both sides.
    @test ismainland("130741") && !isisland("130741")
    @test isisland("310101") && !ismainland("310101")
    # parish_values leaves it out rather than keying it as a parish.
    t = (period = ["2023", "2023", "2023"],
         geocod = ["000000000", "11C130741", "1A0110601"],
         geodsg = ["Estrangeiro", "Vila Boa", "x"],
         value = Union{Float64, Missing}[295.0, 3.0, 7.0])
    pv = parish_values(PortugalINE.IndicatorData("0008234", "births", ["2023"], "", "", t))
    @test pv.dicofre == ["110601", "130741"]
end
