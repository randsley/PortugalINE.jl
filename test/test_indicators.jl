# Layer 2: the indicator API.
#
# Every test here runs offline, against response bodies captured from INE on
# 2026-11-06 and seeded into a temporary cache with `cache_response!`. That
# choice does more than keep CI off the network: because the cache is keyed by
# the request URL, a seeded response is only found if the code builds exactly
# the URL it would have fetched. So these tests exercise the public entry
# points end to end -- URL construction, cache lookup, parsing -- rather than
# calling the parsers directly and leaving the request side unchecked.
#
# One test seeds a deliberately altered body and asserts the altered value
# comes back. That is the proof that no request went out; without it, a run on
# a machine with network access could pass by silently fetching the real thing.

using PortugalINE, Test
using PortugalINE.Indicators: _cache_file, _fetch, _clean, _parse_catalogue,
                              _meta_url, _data_url, _catalogue_url

const FIX = joinpath(@__DIR__, "fixtures")
const F_META = joinpath(FIX, "ine_meta_0014580.json")
const F_DATA = joinpath(FIX, "ine_data_0014580.json")
const F_D3   = joinpath(FIX, "ine_data_0008074_T2022.json")
const F_CAT1 = joinpath(FIX, "ine_catalogue_0014580.xml")
const F_CATM = joinpath(FIX, "ine_catalogue_main.xml")
const F_FAIL = joinpath(FIX, "ine_unknown_code.json")

# One cache for the whole file, seeded once.
const CACHE = mktempdir()
cache_response!(F_META, :metadata, "0014580"; dir = CACHE)
cache_response!(F_DATA, :data, "0014580"; period = "S7A2023", dir = CACHE)
cache_response!(F_DATA, :data, "0014580"; dir = CACHE)
cache_response!(F_D3, :data, "0008074"; period = "S7A2022",
                dimensions = Dict(3 => "T"), dir = CACHE)
cache_response!(F_CAT1, :catalogue, "0014580"; dir = CACHE)
cache_response!(F_CATM, :catalogue; dir = CACHE)
cache_response!(F_FAIL, :metadata, "9999999"; dir = CACHE)

@testset "the fixtures are UTF-8, not a mangled copy of one" begin
    # Every INE endpoint answers with charset=UTF-8 and the bytes are clean.
    # Portuguese place names are the test: a cp1252 round trip turns "ç" into
    # a replacement character, and a fixture that had been through one would
    # make every name comparison below pass against the wrong string.
    raw = read(F_DATA, String)
    @test isvalid(raw)
    @test occursin("Tabuaço", raw)
    @test !occursin('�', raw)
    @test occursin("Município", read(F_CAT1, String))
end

@testset "metadata" begin
    ind = indicator_metadata("0014580"; cache = CACHE)
    @test ind isa Indicator
    @test ind.varcd == "0014580"
    @test ind.periodicity == "Biennial"
    @test ind.decimals == 2            # arrives as the string "2"
    @test ind.power10 == 0
    @test ind.first_period == "2023" && ind.last_period == "2023"
    @test ind.language == "EN"
    @test startswith(ind.name, "Per capita purchasing power")

    # Dim1 is always the period and Dim2 always geography. The package relies
    # on that, so it is asserted rather than assumed.
    @test length(ind.dimensions) == 2
    @test [d.number for d in ind.dimensions] == [1, 2]
    @test ind.dimensions[1].label == "Data reference period"
    @test occursin("Geographic localization", ind.dimensions[2].label)
    @test occursin("NUTS - 2024", ind.dimensions[2].label)
    @test ind.dimensions[2].version == "05257"

    # The geography dimension lists every unit, at every level: 347 of them,
    # which is the same hierarchy layer 1 is tested against.
    geo = ind.dimensions[2].categories
    @test length(geo) == 347
    @test count(c -> c.level == 5, geo) == 308      # municipalities
    @test count(c -> c.level == 1, geo) == 1        # Portugal
    @test geo[1].code == "PT" && geo[1].label == "Portugal"
    @test "1A01106" in [c.code for c in geo]        # Lisboa
    # Categories come back in INE's own display order, not insertion order.
    @test issorted([c.order for c in geo])

    per = ind.dimensions[1].categories
    @test length(per) == 1
    @test per[1].code == "S7A2023"
    @test per[1].label == "2023"
    @test periods(ind) == ["2023"]
end

@testset "a period label is not a period code" begin
    ind = indicator_metadata("0014580"; cache = CACHE)
    # The trap: the filter wants the code, the response is keyed by the label.
    @test period_code(ind, "2023") == "S7A2023"
    @test period_code(ind, "S7A2023") == "S7A2023"   # idempotent
    err = try; period_code(ind, "2019"); catch e; e; end
    @test err isa ArgumentError
    @test occursin("neither a period code nor a period label", err.msg)
    @test occursin("2023", err.msg)                  # says what is available
end

@testset "data" begin
    d = indicator_data("0014580"; period = "2023", cache = CACHE)
    @test d isa IndicatorData
    @test d.varcd == "0014580"
    @test d.periods == ["2023"]
    @test length(d) == 347
    @test d.extracted == "2026-11-06T23:13:38.218Z"

    t = d.table
    @test keys(t) == (:period, :geocod, :geodsg, :value)
    @test all(c -> length(c) == 347, values(t))
    @test eltype(t.value) == Union{Float64, Missing}
    @test all(==("2023"), t.period)

    # valor is a String with a decimal point; ind_string is the localised form
    # with a comma. Parsing the wrong one loses the fraction.
    i = findfirst(==("3003106"), t.geocod)
    @test t.geodsg[i] == "Porto Moniz"
    @test t.value[i] == 61.78

    j = findfirst(==("1A01106"), t.geocod)
    @test t.geodsg[j] == "Lisboa"
    @test t.value[j] == 181.35

    # Portugal's value is "100" with no decimal point at all, and must parse.
    k = findfirst(==("PT"), t.geocod)
    @test t.value[k] == 100.0
    @test !any(ismissing, t.value)

    # Asking for the code gives the identical result to asking for the label,
    # and by a different URL, so both are seeded and both are exercised.
    d2 = indicator_data("0014580"; period = "S7A2023", cache = CACHE)
    @test d2.table.value == t.value
end

@testset "a dimension beyond period and geography" begin
    d = indicator_data("0008074"; period = "S7A2022",
                       dimensions = Dict(3 => "T"), cache = CACHE)
    @test d.periods == ["2022"]
    @test length(d) == 344
    t = d.table
    # The echoed dimension becomes two columns, and dim_3_t is renamed because
    # "_t" says nothing about what it holds.
    @test keys(t) == (:period, :geocod, :geodsg, :value, :dim_3, :dim_3_label)
    @test all(==("T"), t.dim_3)
    @test all(==("Overall total"), t.dim_3_label)
    i = findfirst(==("3003101"), t.geocod)
    @test t.value[i] == 13.5

    # Dim1 and Dim2 are refused by name, with the reason, rather than being
    # passed through to produce a response this package cannot use.
    e1 = try; indicator_data("0008074"; dimensions = Dict(1 => "S7A2022"),
                             cache = CACHE); catch e; e; end
    @test e1 isa ArgumentError && occursin("reference period", e1.msg)
    e2 = try; indicator_data("0008074"; dimensions = Dict(2 => "PT"),
                             cache = CACHE); catch e; e; end
    @test e2 isa ArgumentError && occursin("geography", e2.msg)
end

@testset "municipal_values keys on DICO and drops the aggregates" begin
    d = indicator_data("0014580"; period = "2023", cache = CACHE)
    m = municipal_values(d)
    @test keys(m) == (:dico, :name, :value)

    # 347 rows in, 308 out: the other 39 are Portugal, NUTS I, NUTS II and
    # NUTS III totals. Keeping them would double-count the country four times.
    @test length(m.dico) == 308
    @test length(unique(m.dico)) == 308
    @test all(x -> length(x) == 4 && all(isdigit, x), m.dico)
    @test issorted(m.dico)

    # Lisboa: NUTS code 1A01106, DICO 1106. The NUTS prefix is the part that
    # changes between vintages, which is why the key is the DICO.
    i = findfirst(==("1106"), m.dico)
    @test m.name[i] == "Lisboa"
    @test m.value[i] == 181.35
    @test m.value[findfirst(==("1301"), m.dico)] isa Float64

    # Sorted by DICO is the ordering the GAL weights files use, so the two line
    # up without a join. 1106 is Lisboa in both.
    @test m.dico[1] == "0101"

    # A multi-period extract has to be told which period.
    multi = IndicatorData("x", "x", ["2021", "2023"], "", "", d.table)
    e = try; municipal_values(multi); catch e; e; end
    @test e isa ArgumentError && occursin("pass `period =", e.msg)
end

@testset "an unfiltered third dimension is caught, not averaged" begin
    # Two rows for the same municipality mean a dimension is still open. Left
    # alone that silently gives whichever row sorted last; here it is refused,
    # and the message says why.
    t = (period = ["2023", "2023"], geocod = ["1A01106", "1A01106"],
         geodsg = ["Lisboa", "Lisboa"], value = Union{Float64, Missing}[1.0, 2.0])
    d = IndicatorData("0000001", "two rows per unit", ["2023"], "", "", t)
    e = try; municipal_values(d); catch e; e; end
    @test e isa ArgumentError
    @test occursin("DICO is not unique", e.msg)
    @test occursin("1106", e.msg)
end

@testset "suppressed cells stay missing" begin
    @test parse_value("61.78") == 61.78
    @test parse_value("100") == 100.0
    @test parse_value(nothing) === missing
    @test parse_value("") === missing
    @test parse_value("-") === missing
    @test parse_value("x") === missing
    @test parse_value("not a number") === missing
    @test parse_value(2.5) == 2.5
    # The localised form would parse as 61 under a naive Float64 parse, which
    # is why ind_string is never read.
    @test parse_value("61,78") === missing
end

@testset "failure arrives with HTTP 200 and is thrown anyway" begin
    e = try; indicator_metadata("9999999"; cache = CACHE); catch e; e; end
    @test e isa ArgumentError
    # INE's own message, not a substitute.
    @test occursin("The indicator code does not exist", e.msg)
    @test occursin("Cod 1", e.msg)
end

@testset "bad arguments are refused before a request" begin
    # Leading zeros matter, so a code must be a seven-digit string.
    @test_throws ArgumentError indicator_metadata("14580"; cache = CACHE)
    @test_throws ArgumentError indicator_metadata("00145800"; cache = CACHE)
    @test_throws ArgumentError indicator_metadata("001458X"; cache = CACHE)
    @test_throws ArgumentError indicator_metadata("0014580"; language = "FR",
                                                  cache = CACHE)
    @test_throws ArgumentError cache_response!(F_META, :nonsense, "0014580";
                                               dir = CACHE)
    # An empty body would be cached and then fail to parse on every later call.
    @test_throws ArgumentError cache_response!("", :catalogue; dir = mktempdir())
end

@testset "catalogue: one entry" begin
    e = catalogue_entry("0014580"; cache = CACHE)
    @test e isa CatalogueEntry
    @test e.varcd == "0014580"
    @test e.title == "Per capita purchasing power"
    @test e.theme == "Living conditions and citizenship"
    @test e.subtheme == "Poverty and economic inequality"
    @test e.source == "Statistics Portugal, Study on the local purchasing power"
    @test e.last_period == "S7A2023"
    @test e.last_update == "06-11-2025"
    # The CDATA holds " Biennial" with a leading space; cleaning removes it.
    @test e.periodicity == "Biennial"
    @test "INE" in e.keywords
    @test "Poverty and economic inequality" in e.keywords

    # The field the request is for.
    @test e.geo_lastlevel == "Município"
    @test ismunicipal(e)
end

@testset "catalogue: the main group, and what it answers" begin
    cat = catalogue(cache = CACHE)
    @test length(cat) == 326
    @test length(unique(c.varcd for c in cat)) == 326
    @test all(c -> occursin(r"^[0-9]{7}$", c.varcd), cat)
    @test all(c -> !isempty(c.title), cat)

    lv = Dict(l => count(c -> c.geo_lastlevel == l, cat)
              for l in unique(c.geo_lastlevel for c in cat))
    @test lv["Município"] == 98
    @test lv["Freguesia"] == 17
    @test lv["Portugal"] == 114

    # Why this is worth a request: the alternative way to learn that 115 of
    # INE's 326 main indicators reach municipal level is 326 data requests of
    # tens of kilobytes each.
    @test count(ismunicipal, cat) == 115
    @test count(ismunicipal, cat) == lv["Município"] + lv["Freguesia"]

    # Freguesia counts because a freguesia sits inside one municipality, so it
    # aggregates up. NUTS III does not, however it is spelled -- and INE
    # spells it both ways in the same document, which is the reason
    # ismunicipal exists.
    @test haskey(lv, "NUTS III") && haskey(lv, "NUTS 3")
    @test lv["NUTS III"] == 17 && lv["NUTS 3"] == 5
    @test !any(ismunicipal, filter(c -> startswith(c.geo_lastlevel, "NUTS"), cat))

    # Every level is accounted for, so a level this package does not recognise
    # cannot hide in the tail.
    @test sum(values(lv)) == 326
end

@testset "the group catalogue localises the theme and nothing else" begin
    # Measured against INE, not assumed: fetching opc=3 with lang=EN and
    # lang=PT gives 326 identical titles -- all of them Portuguese -- and 326
    # differing themes. So the same indicator reads "Poder de compra per
    # capita" here and "Per capita purchasing power" through opc=1, which
    # honours the language throughout. A search that assumed otherwise would
    # return nothing and look like an absent indicator.
    cat = catalogue(cache = CACHE)
    e = cat[findfirst(c -> c.varcd == "0014580", cat)]
    @test e.title == "Poder de compra per capita"
    @test catalogue_entry("0014580"; cache = CACHE).title ==
          "Per capita purchasing power"
    @test e.theme == "Living conditions and citizenship"     # localised
    @test e.geo_lastlevel == "Município"                     # not localised

    # No description in the group listing is English, and the themes carry no
    # Portuguese diacritic, which is the split stated above.
    @test count(c -> occursin("Geographic localization", c.description), cat) == 0
    @test count(c -> occursin("Localização geográfica", c.description), cat) == 129
    @test all(c -> !occursin(r"[ãçõáéíúâêô]", c.theme), cat)
end

@testset "searching the catalogue" begin
    cat = catalogue(cache = CACHE)
    hits = search_catalogue(cat, "poder de compra")
    @test !isempty(hits)
    @test "0014580" in [h.varcd for h in hits]
    # The English phrase is absent from this listing, by INE's design.
    @test isempty(search_catalogue(cat, "purchasing power"))
    # The theme is localised, so an English theme name does match.
    @test !isempty(search_catalogue(cat, "Living conditions"))

    mun = search_catalogue(cat, "poder de compra"; municipal_only = true)
    @test all(ismunicipal, mun)
    @test length(mun) <= length(hits)

    # Accent- and case-insensitive, because the themes and place names carry
    # accents and nobody types them into a search.
    @test !isempty(search_catalogue(cat, "POPULACAO"))
    @test search_catalogue(cat, "população") == search_catalogue(cat, "populacao")

    @test isempty(search_catalogue(cat, "zzzznotathing"))
    @test_throws ArgumentError search_catalogue(cat, "")
end

@testset "a document that is not a catalogue is refused" begin
    e = try; _parse_catalogue("<html><body>503</body></html>", "u"); catch e; e; end
    @test e isa ArgumentError
    @test occursin("not an INE catalogue document", e.msg)
    # An empty catalogue is a failure too: a silently empty list would read as
    # "INE published nothing", which is never the truth.
    e2 = try; _parse_catalogue("<catalog></catalog>", "u"); catch e; e; end
    @test e2 isa ArgumentError && occursin("no <indicator> entries", e2.msg)
end

@testset "CDATA, entities and indentation are all cleaned" begin
    @test _clean("<![CDATA[Município]]>") == "Município"
    @test _clean("  a\n\t b  ") == "a b"
    @test _clean("A &amp; B") == "A & B"
    @test _clean("<![CDATA[ Biennial]]>") == "Biennial"
    @test _clean("") == ""
end

@testset "the cache is keyed by URL and is actually read" begin
    # The URLs are stable and distinct, which is what makes the key work.
    @test _meta_url("0014580", "EN") != _data_url("0014580", "EN")
    @test _data_url("0014580", "EN"; period = "S7A2023") !=
          _data_url("0014580", "EN")
    @test _catalogue_url("EN") != _catalogue_url("EN"; varcd = "0014580")
    @test _cache_file(_meta_url("0014580", "EN"), "d") !=
          _cache_file(_meta_url("0014580", "PT"), "d")
    @test occursin("meta_", basename(_cache_file(_meta_url("0014580", "EN"), "d")))

    # The proof that nothing is fetched: seed an altered body and read the
    # alteration back. If a request went out, the real title would win.
    tmp = mktempdir()
    altered = replace(read(F_CAT1, String),
                      "Per capita purchasing power" => "A TITLE INE NEVER USED")
    cache_response!(altered, :catalogue, "0014580"; dir = tmp)
    @test catalogue_entry("0014580"; cache = tmp).title == "A TITLE INE NEVER USED"

    # And clearing it empties the directory.
    @test clear_ine_cache!(dir = tmp) == 1
    @test clear_ine_cache!(dir = tmp) == 0
    @test clear_ine_cache!(dir = joinpath(tmp, "never-created")) == 0
end

@testset "the citation INE's terms require" begin
    d = indicator_data("0014580"; period = "2023", cache = CACHE)
    c = ine_citation(d)
    @test occursin("Statistics Portugal (INE)", c)
    @test occursin("indicator 0014580", c)
    @test occursin("reference period 2023", c)
    @test occursin("extracted 2026-11-06", c)   # the date, not the timestamp

    d3 = indicator_data("0008074"; period = "S7A2022",
                        dimensions = Dict(3 => "T"), cache = CACHE)
    c2 = ine_citation(d, d3)
    @test occursin("indicators 0008074, 0014580", c2)   # sorted, pluralised
    @test occursin("reference periods 2022, 2023", c2)
    @test_throws ArgumentError ine_citation()
    @test occursin("Statistics Portugal (INE)", INE_ATTRIBUTION)
end

# ---------------------------------------------------------------------------
# Live API, off by default.
#
# Set PORTUGALINE_LIVE_TESTS=1 to run these. They are not in CI because INE
# resets connections under load often enough that a green suite would stop
# meaning anything, and because the fixtures above already pin the parsing.
# What they catch is drift: a renamed field or a changed response shape, which
# no offline fixture can see.
# ---------------------------------------------------------------------------
if get(ENV, "PORTUGALINE_LIVE_TESTS", "0") == "1"
    @testset "live: the API still has the shape the fixtures captured" begin
        live = mktempdir()
        ind = indicator_metadata("0014580"; cache = live)
        @test ind.varcd == "0014580"
        @test [d.number for d in ind.dimensions] == [1, 2]
        @test occursin("Geographic localization", ind.dimensions[2].label)
        @test !isempty(periods(ind))

        last = ind.dimensions[1].categories[end]
        d = indicator_data("0014580"; period = last.code, cache = live)
        # Keyed by the label, filtered by the code: the trap, live.
        @test d.periods == [last.label]
        m = municipal_values(d)
        @test length(m.dico) == 308
        @test count(!ismissing, m.value) > 300

        e = catalogue_entry("0014580"; cache = live)
        @test e.geo_lastlevel == "Município"
        @test e.title == "Per capita purchasing power"
        @test_throws ArgumentError indicator_metadata("9999999"; cache = live)
    end
end
