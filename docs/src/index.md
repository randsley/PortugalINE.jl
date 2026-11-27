# PortugalINE.jl

A client for Statistics Portugal (INE), built for spatial work: the
geography codes, the indicator API, CAOP boundaries, contiguity weights, and
the join between them.

The [README](https://github.com/randsley/PortugalINE.jl#readme) records,
with measurements, the traps this package exists to avoid: codes that are
not seven digits, NUTS codes that change between vintages, two parish maps,
pseudo-units in the data, and an API that answers failure with HTTP 200.

```@docs
PortugalINE
```

## Layers

| layer | page | what it does |
|---|---|---|
| 1 | [Geography codes](@ref) | code length gives the level; DICO, DICOFRE, NUTS III, district |
| 2 | [Indicators](@ref) | metadata, data, the catalogue, a disk cache, citations |
| 3 | [Boundaries and weights](@ref) | CAOP GeoJSON, queen and rook contiguity, centroids, GAL files |
| 4 | [Joining](@ref) | indicators to boundaries on DICO or DICOFRE, with provenance |
| 5 | [Panels](@ref) | the same units over several periods, with one `W` |
| 6 | [Web maps](@ref) | TopoJSON with shared borders, values and links, for browser maps |

## Licences

INE's data is open for reuse under EU Directive 2019/1024; the one condition
is that the source be cited ([`ine_citation`](@ref)). CAOP is published by
the Direção-Geral do Território under CC-BY-4.0 ([`CAOP_ATTRIBUTION`](@ref)).
Every file this package writes carries both.
