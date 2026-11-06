# PortugalINE.jl

A Julia client for **Statistics Portugal (INE)**, built for spatial work: the
geography codes, the indicator API, and weights matrices from INE's own
geometry.

> **Status: 0.1.0-DEV.** Layer 1 (geography codes) is implemented and tested.
> Layers 2 to 4 are not written yet.

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
| 3. Geometry | BGRI readers, `W` by contiguity and k-nearest | planned |
| 4. Join | indicators to geometry on DICO, island handling made explicit | planned |

Deliberately **out of scope**: plotting, descriptive analytics (year-on-year,
moving averages) and a CLI. `pyptine` carries those because Python users expect
one package to do everything; in Julia each is either someone else's package or
a one-liner, and every one would be a dependency that buys this package nothing.

Geometry will live in a **package extension**, so the client stays light for
anyone who only wants attributes.

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

Geometry comes from **BGRI**, which is INE's own and is covered by those terms.
CAOP, from Direcao-Geral do Territorio, is a different body under separate terms
that are not stated on its download page; it is therefore optional here rather
than load-bearing.

The anonymised **Public Use Files** are out of scope. They sit behind a separate
click-through agreement, and their spatial identifiers are aggregated upward,
which rules them out for municipal `W` anyway.

## Tests

The suite runs against a captured real INE response - the geography dimension of
indicator `0014580`, pulled 2026-11-06 - rather than hand-written examples.
Counts are pinned to the actual hierarchy (308, 147, 26, 14, 278, 30), so a
parser that handles the easy codes and drops the rest cannot pass.

```
Test Summary: | Pass  Total
PortugalINE   |   38     38
```
