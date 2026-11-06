# PortugalINE.jl

A Julia client for **Statistics Portugal (INE)**, built for spatial work: the
geography codes, the indicator API, and weights matrices from INE's own
geometry.

> **Status: 0.1.0-DEV.** Layers 1 (geography codes) and 3 (boundaries and
> weights) are implemented and tested. Layer 2, the indicator API, is not
> written yet -- until it is, pull attributes with
> [`pyptine`](https://github.com/randsley/pyptine) and see
> `scripts/build_spatial_dataset.py`.

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
| 2. API | catalogue (`xml_indic.jsp`), indicators (`pindica.jsp`), disk cache | planned |
| 3. Geometry | CAOP reader, `W` by queen/rook contiguity and k-nearest, GAL output | done |
| 4. Join | indicators to geometry on DICO, island handling made explicit | planned |

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

Municipal coverage is per indicator and must be checked, never assumed. Of four
indicators probed on 2026-11-06, three carry all 308 municipalities (`0014580`
per capita purchasing power, `0014581` its national share, `0013189` population
density) and one stops at NUTS III (`0013351` ageing ratio, 39 rows).

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
PortugalINE   |  114    114
```
