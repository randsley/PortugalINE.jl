using PortugalINE, Test, SparseArrays, LinearAlgebra
using PortugalINE.Codes: DISTRICT_NAMES

# The fixture is a real INE response: the geography dimension of indicator
# 0014580 (per capita purchasing power), pulled 2026-11-06. Every count below is
# a property of the actual hierarchy, not of a handful of chosen examples, so a
# parser that works on the easy codes and fails on the rest cannot pass.
const FIXTURE = joinpath(@__DIR__, "fixtures", "ine_geo_0014580.json")

raw   = read(FIXTURE, String)
codes = String[]
names = String[]
for m in eachmatch(r"\"geocod\":\s*\"([^\"]+)\",\s*\"name\":\s*\"([^\"]*)\"", raw)
    push!(codes, m.captures[1]); push!(names, m.captures[2])
end

@testset "PortugalINE" begin

@testset "the fixture is the shape INE returned" begin
    @test length(codes) == 347
    @test length(unique(codes)) == 347
end

@testset "levels partition the hierarchy exactly" begin
    by = Dict(l => count(c -> geolevel(c) == l, codes) for l in instances(GeoLevel))
    @test by[MUNICIPALITY] == 308
    @test by[NUTS3] == 26
    @test by[NUTS1] == 3
    @test by[NUTS2] == 9           # the ten 2-character codes, less "PT"
    @test by[COUNTRY] == 1
    @test sum(values(by)) == 347   # nothing unclassified, nothing double-counted
end

@testset "a municipality code is not seven digits" begin
    mun = filter(ismunicipality, codes)
    @test length(mun) == 308
    # The point of the module: the naive pattern finds fewer than half.
    naive = count(c -> occursin(r"^[0-9]{7}$", c), mun)
    @test naive == 147
    @test naive < length(mun)
    # 14 NUTS III prefixes carry a letter, and they are municipalities too.
    lettered = filter(c -> !occursin(r"^[0-9]{3}$", nuts3(c)), mun)
    @test length(unique(nuts3.(lettered))) == 14
    @test "11D1819" in mun          # Tabuaço
    @test nuts3("11D1819") == "11D"
end

@testset "DICO is a usable join key and the NUTS prefix is not" begin
    mun = filter(ismunicipality, codes)
    d = dico.(mun)
    @test all(x -> all(isdigit, x) && length(x) == 4, d)
    @test length(unique(d)) == 308          # unique across every municipality
    # The prefix is not unique per municipality, which is why it cannot be the key.
    @test length(unique(nuts3.(mun))) == 26
    # And it does not determine the district: Arouca is in the Porto NUTS III
    # region and the Aveiro district at once.
    @test nuts3("11A0104") == "11A"
    @test district("11A0104") == 1
    @test DISTRICT_NAMES[district("11A0104")] == "Aveiro"
    @test DISTRICT_NAMES[district("1910101")] == "Aveiro"   # Águeda, NUTS III 191
    @test nuts3("1910101") != nuts3("11A0104")             # same district, different region
end

@testset "mainland and islands split 278 to 30" begin
    mun = filter(ismunicipality, codes)
    @test count(ismainland, mun) == 278
    @test count(isisland, mun) == 30
    @test count(ismainland, mun) + count(isisland, mun) == length(mun)
    @test isisland("3003106")                 # Porto Moniz, Madeira
    @test ismainland("1111601")               # Arcos de Valdevez
    @test all(c -> haskey(DISTRICT_NAMES, district(c)), mun)
end

@testset "a code of unknown shape is refused, not guessed" begin
    @test_throws ArgumentError geolevel("")
    @test_throws ArgumentError geolevel("1234")
    @test_throws ArgumentError geolevel("12345678")
    # Level-specific accessors refuse the wrong level by name.
    @test_throws ArgumentError dico("11D")
    @test_throws ArgumentError nuts3("PT")
    @test_throws ArgumentError district("111")
    # A 7-character code whose tail is not numeric is not a municipality code,
    # and silently returning the letters would poison a join.
    @test_throws ArgumentError dico("11D18XY")
end

@testset "PT is the country, not a NUTS II region" begin
    @test geolevel("PT") == COUNTRY
    @test geolevel("11") == NUTS2
    @test "PT" in codes
end


@testset "2. the indicator API" begin
    include("test_indicators.jl")
end

@testset "3. boundaries and weights" begin
    include("test_boundaries.jl")
end

end
