# PortugalINE.jl

A Julia client for **Statistics Portugal (INE)**, built for spatial work: the
geography codes, the indicator API, and weights matrices from INE's own
geometry.

> **Status: 0.1.0-DEV.** All four layers are implemented and tested.
> `scripts/build_dataset.jl` runs the whole pipeline -- catalogue check,
> indicators, boundaries, join, output -- in Julia.
> `scripts/build_spatial_dataset.py` is kept as the
> [`pyptine`](https://github.com/randsley/pyptine) route that produced the
> first extract before layer 2 existed, not because anything still needs it.

## Why this exists

[`pyptine`](https://github.com/randsley/pyptine) already covers the attribute
side of INE in Python, and covers it well. It has no geospatial support at all,
and for spatial econometrics the geometry *is* the problem: `y` and `X` come
from the API, but `W` comes from the boundaries. This package is the geometry
half plus enough of the API to join to it.

## Scope

| layer | what | status |
|---|---|---|
| 1. Codes | the geography code hierarchy, DICO parsing, mainland/island | done |
| 2. API | catalogue (`xml_indic.jsp`), indicators (`pindica.jsp`), disk cache | done |
| 3. Geometry | CAOP reader, `W` by queen/rook contiguity and k-nearest, GAL output | done |
| 4. Join | indicators to geometry on DICO, island handling made explicit | done |

Deliberately **out of scope**: plotting, descriptive analytics (year-on-year,
moving averages) and a CLI. `pyptine` carries those because Python users expect
one package to do everything; in Julia each is either someone else's package or
a one-liner, and every one would be a dependency that buys this package nothing.

Geometry needs **no extension and no geometry engine** after all. The original
plan was to put CAOP behind a package extension on ArchGDAL or GEOS; measuring
the data made that unnecessary, and the reasoning is under
[Weights without a geometry engine](#weights-without-a-geometry-engine).

## What layer 1 knows

Every INE indicator that varies by place carries a code whose **length** says
which level it describes, and the codes form a prefix hierarchy:

| length | level | example |
|---|---|---|
| 2 | country, or NUTS II | `PT`, `11` (Norte) |
| 1 | NUTS I | `1` (Continente) |
| 3 | NUTS III | `111` (Alto Minho), `11D` (Douro) |
| 7 | municipality | `1111601` (Arcos de Valdevez), `11D1819` (Tabuaco) |

```julia
using PortugalINE

geolevel("11D1819")     # MUNICIPALITY
nuts3("11D1819")        # "11D"   -- Douro
dico("11A0104")         # "0104"  -- Arouca
district("11A0104")     # 1       -- Aveiro
ismainland("3003106")   # false   -- Porto Moniz, Madeira
```

### Three things that are easy to get wrong

**A municipality code is not seven digits.** Its first three characters are the
NUTS III code, and 14 of the 26 NUTS III codes contain a letter: `11A` to
`11E`, `1A0`, `1B0`, `1C1` to `1D3`. Filtering municipalities with a seven-digit
pattern keeps **147 of the 308** and drops the rest in silence. The test suite
pins that number so the trap stays documented rather than merely fixed.

**The join key is the DICO, not the NUTS prefix.** The last four characters are
the official district-and-municipality code: numeric and unique for all 308.
The NUTS III prefix is neither a district nor unique to one. Arouca is
`11A0104` - the Porto metropolitan region, the Aveiro district - and nothing in
`11A` recovers `Aveiro`.

**The islands have no land neighbours.** 278 municipalities are on the mainland
and 30 are in Madeira and the Azores. In a contiguity `W` over all 308 the
island rows are entirely zero, and row-standardising divides by zero. Choose
mainland-only or a neighbour-count weighting deliberately; `ismainland` is there
so the choice is visible in the code.

## What layer 2 knows

```julia
using PortugalINE

cat = catalogue()                        # 326 indicators, one 500 kB request
count(ismunicipal, cat)                  # 115 reach municipal level or finer
search_catalogue(cat, "poder de compra"; municipal_only = true)

ind = indicator_metadata("0014580")      # dimensions, and every code they take
d   = indicator_data("0014580"; period = "2023")
m   = municipal_values(d)                # 308 rows, keyed and sorted by DICO
ine_citation(d)                           # the citation INE's terms require
```

`d.table` is a `NamedTuple` of equal-length vectors, which is already a valid
Tables.jl column table, so `DataFrame(d.table)` works without this package
depending on DataFrames or Tables. Responses are cached on disk by URL;
`cache_response!` seeds that cache from an archived body, which is how an
extract gets frozen so a published number can be regenerated without the API.

### Four things this API does that will catch you

**`valor` is a string, and it is not the one that is displayed.** A row reads
`{"geocod":"3003106","geodsg":"Porto Moniz","ind_string":"61,78","valor":"61.78"}`.
`valor` is the machine form with a decimal point; `ind_string` is the localised
form with a comma, which parses as `61` or fails depending on the locale.

**`Dados` is keyed by the period's label, but `Dim1` takes its code.** The 2022
annual slice of `0008074` is requested with `Dim1=S7A2022` and returned under
the key `"2022"`. Send the label and INE rejects it; look for the code as a key
and nothing is found. `period_code` converts, and `indicator_data` takes either.

**Failure arrives with HTTP 200.** An unknown indicator returns
`{"Sucesso":{"Falso":[{"Msg":"...","Cod":"1"}]}}` with status 200. Every entry
point checks `Sucesso` and throws INE's own message, so a typo is an error
rather than an empty table.

**The group catalogue ignores `lang` for titles.** `opc=3` localises `theme`
and `subtheme` and nothing else: fetching it with `lang=EN` and `lang=PT` gives
326 *identical* titles, all Portuguese, and 326 differing themes. That was
measured by fetching both. So search it in Portuguese, or on the theme; the
single-indicator call `opc=1` honours the language throughout, and is where an
English title comes from.

And one thing it does **not** do, despite a claim made while building this:
the responses are clean UTF-8, declared `charset=UTF-8`. Nothing needs
transcoding. A Windows console that renders `Tabuaço` as `Tabua?o` is the
console's encoding, not the payload's, and the suite asserts the fixtures are
valid UTF-8 carrying real diacritics so the difference stays visible.

## What layer 4 knows

```julia
b  = read_caop_geojson("caop_municipios.json")
pp = indicator_data("0014580"; period = "2023")
de = indicator_data("0013189"; period = "2023")

ds = join_municipal(b, :purchasing_power => pp, :density => de)
W  = spatial_weights(ds)                 # row-standardised, over these units
m  = model_matrix(ds, :purchasing_power, :density)
write_dataset("data", ds)                # CSV + GAL + centroids + provenance
```

### Why the key is the DICO, measured rather than argued

0014580 is published on NUTS 2024 and 0008074 on NUTS 2013. Both carry all 308
municipalities, so every shortfall below is the key failing, not missing data:

| key | matches |
|---|---|
| NUTS code (`geocod`) | **132 of 308** |
| name (`geodsg`) | 305 of 308 |
| DICO | **308 of 308** |

Lisboa is `1A01106` under NUTS 2024 and `1701106` under NUTS 2013, so joining
on the identifier INE returns first loses 57% of the country in silence. The
name is worse than its 305 suggests: the three mismatches are a disambiguating
suffix, and without it `Calheta` names **two** municipalities, 3101 in Madeira
and 4501 in the Azores. The DICO is the last four characters of either code and
is stable because it is the official district-and-municipality number rather
than a statistical grouping. The suite pins all three figures.

When two extracts disagree about a municipality's NUTS code, the dataset says
so and reports how many the alternative join would have matched, so a vintage
difference is a line of output rather than a discovery made later.

### Why the matrix is rebuilt and never sliced

Dropping a unit changes its neighbours' degrees, so a row-standardised `W` from
the full set is wrong for any subset of it. Everything here therefore carries
**binary** adjacency and standardises last: `spatial_weights` on the dataset,
and `model_matrix` again after dropping incomplete cases.

This is a quiet failure, not a loud one. Slicing a standardised matrix leaves
the untouched rows summing to one and breaks only the rows beside what was
dropped, so a "do the rows sum to one?" check passes on the wrong answer. The
suite asserts the rebuilt matrix *differs* from the sliced one, and names the
rows that differ. If dropping incomplete cases leaves a unit with no
neighbours, that is an error naming the unit rather than a division by zero.

### The islands, counted apart

The 30 island municipalities have data and no land neighbours, and CAOP serves
the mainland as its own collection, so the usual join settles on 278 units.
That is the right answer reached the wrong way, so every dropped unit is
recorded and the islands are counted separately from everything else -- the
second kind means the boundary vintage and the indicator's geography disagree
about what exists, and the first does not. Note that the island districts are
`31`, **`32`** (Porto Santo), and `41` to `49`; writing out "Madeira and the
Azores" by hand leaves out the second, which is why the suite pins the set.

## Weights without a geometry engine

Contiguity is computed by hashing vertices and edges rather than by
intersecting polygons, because CAOP is a **clean planar partition**: where two
municipalities share a border, both rings carry the same vertices to the bit.
That was measured, not assumed. Hashing exact `Float64` pairs and hashing
coordinates rounded to six decimals give the *identical* graph over the 278
mainland municipalities, so there is no tolerance to tune and no GEOS, ArchGDAL
or build chain to carry.

```julia
using PortugalINE

b  = read_caop_geojson("caop_municipios.json")   # 278 mainland municipalities
Wq = contiguity(b; criterion = :queen)           # 739 links
Wr = contiguity(b; criterion = :rook)            # 737 links
W  = contiguity(b; criterion = :queen, standardize = true)
C  = centroids(b)                                 # area-weighted, not vertex means
Wk = knn_contiguity(b, 5)                         # every unit gets neighbours
write_gal("portugal_queen.gal", b)                # GeoDa GAL, for SpatialEconometrics.jl
```

Measured on the mainland: mean degree 5.32, minimum 1 (Nazaré), maximum 10, no
isolated unit. **Queen and rook differ by exactly two pairs**, both meeting at a
single point: Mêda with Sernancelhe, and Lisboa with Vila Franca de Xira. The
queen/rook choice is usually presented as consequential; on these boundaries it
moves two links out of 739.

Three things the API refuses rather than guesses: `standardize = true` on a
matrix with an empty row throws and names the units, since an isolated unit
means either dirty topology or islands mixed into the mainland; a feature whose
`dtmn` is not four digits is rejected, because the DICO is the join key; and
`knn_contiguity` documents that it is **not symmetric**, which matters for
estimators that assume otherwise.

`centroids` uses the area-weighted polygon moment, not the mean of the
vertices, because vertices cluster where a border is intricate. The suite pins
Lisboa's centroid against the city's real coordinates, which is how a
factor-of-two error in the moment formula was caught: it had put every centroid
at exactly half its true position, a pair of numbers that still looks plausible
and would have fed a distance weighting without complaint.

## Geography and provenance

One request returns **every level at once** - 347 rows for 308 municipalities,
26 NUTS III, 9 NUTS II, 3 NUTS I and the country - so levels are filtered
client-side rather than requested. Note also that the geography dimension is
**`Dim2`**; `Dim1` is the reference period.

Municipal coverage is per indicator and must be checked, never assumed -- but
it need not be probed. The catalogue's `geo_lastlevel` states each indicator's
finest geography, so `ismunicipal` answers in one 500 kB request what would
otherwise take one data request per candidate. Of INE's 326 main-group
indicators, 98 reach `Município` and 17 reach `Freguesia`; the latter count
because a freguesia sits inside one municipality and so aggregates up, which
makes **115** usable for a municipal `W`. NUTS III does not aggregate down,
however it is spelled -- and INE spells it both `NUTS III` and `NUTS 3` in the
same document, which is why `ismunicipal` is a function and not a string
comparison at the call site.

Probing confirmed it where it was checked: of four indicators pulled on
2026-11-06, three carry all 308 municipalities (`0014580` per capita purchasing
power, `0014581` its national share, `0013189` population density) and one
stops at NUTS III (`0013351` ageing ratio, 39 rows).

Indicator metadata states the geometry edition the figures were built on -
"CAOP 2020 ... NUTS 2024" - so the boundary vintage is dictated by the data
rather than chosen.

## Licence and attribution

This package is MIT. **The data is not.**

INE data is open for reuse, commercial and non-commercial, under EU Directive
2019/1024. INE retains copyright: it is openly licensed, not public domain, and
reuse carries one condition - **cite the source**.

> Source: Statistics Portugal (INE), [indicator code], extracted [date].
> Geospatial data: Statistics Portugal (INE), Base Geografica de Referenciacao
> da Informacao (BGRI).

Boundaries come from **CAOP2025**, which Direcao-Geral do Territorio serves
through an OGC API and licenses **CC-BY-4.0** with public access unrestricted.
Its own download pages do not state this; the licence is in the SNIG catalogue
record the OGC API links as canonical, which gives `noLimitations` access and
requires this credit for any published use, adapted or not:

> Informacao geografica cedida pela Direcao-Geral do Territorio

`CAOP_ATTRIBUTION` holds that string, so it travels with the code rather than
sitting in a README nobody reads. INE's **BGRI** remains an alternative, covered
by INE's own terms, and is what layer 3 would read for sub-municipal work.

The anonymised **Public Use Files** are out of scope. They sit behind a separate
click-through agreement, and their spatial identifiers are aggregated upward,
which rules them out for municipal `W` anyway.

## Tests

The suite runs against a captured real INE response - the geography dimension of
indicator `0014580`, pulled 2026-11-06 - rather than hand-written examples.
Counts are pinned to the actual hierarchy (308, 147, 26, 14, 278, 30), so a
parser that handles the easy codes and drops the rest cannot pass.

Layer 2 is tested **offline**, against five response bodies captured from INE
on 2026-11-06 and seeded into a temporary cache with `cache_response!`. Because
that cache is keyed by the request URL, a seeded response is found only if the
code builds exactly the URL it would have fetched -- so the tests exercise the
public entry points end to end, URL construction included, rather than calling
the parsers and leaving the request side unchecked. One test seeds a
deliberately altered title and asserts the alteration comes back, which is the
proof that no request went out; without it a run on a networked machine could
pass by silently fetching the real thing. A live suite that checks the API has
not drifted is gated behind `PORTUGALINE_LIVE_TESTS=1` and is kept out of CI,
because INE resets connections often enough that a green suite would stop
meaning anything.

Layer 4 is tested against the alternatives, not only against itself. The claim
that the DICO is the right key is checked by joining two real extracts on all
three candidate keys and counting the matches, so the figures in the table
above are the figures the suite enforces. The rebuild-not-slice rule is checked
by asserting the two give *different* matrices, because a test that only
checked row sums would pass on either.

Layer 3 is tested twice over. A synthetic 3x3 lattice of unit squares pins the
algorithms against a closed form -- 12 rook links, 20 queen, degrees 2/3/4 and
3/5/8 -- so a wrong implementation cannot pass by agreeing with itself. Then six
real municipalities of the Lisboa district pin them against real topology, which
is the only place node matching either holds or does not. That fixture contains
Lisboa and Vila Franca de Xira precisely because they are one of the two
point-touching pairs in the country, so the queen/rook distinction is exercised
on data rather than on a constructed corner.

```
Test Summary: | Pass  Total
PortugalINE   |  403    403
```

Measured on Julia 1.13.3 and 1.10.13, both green.
