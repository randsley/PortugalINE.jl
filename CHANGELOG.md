# Changelog

All notable changes to PortugalINE.jl. The package is unreleased; the version
is `0.1.0-DEV`. Dates are those of the commits.

## Unreleased

### Added
- **INE's API: verified behaviour**, a manual page (`docs/src/ine_api.md`): the one
  list of what INE's API does that a client must know (refusals as HTTP 200,
  period labels and codes, throttling 404s, geographic levels and districts,
  catalogue quirks), shared with pyptine, the Python client. (2026-11-27)
- **Web map layers** (layer 6): `write_webmap` writes TopoJSON in longitude and
  latitude, with each shared border one arc simplified once (so neighbours
  stay flush), plus values and the weights' links. `ptm06_to_wgs84` is pure
  Julia and agrees with PROJ to 1e-9 degrees. On the 2,882 parishes,
  topojson-client recovers the exact rook graph from the shared arcs. The
  panel build writes the layer, for SpatialAtlas.jl. (2026-11-27)
- **Panels** (layer 5): `join_panel`, `panel_matrices` (stacked period by
  period, `W` rebuilt over the units kept) and `write_panel` (long CSV, GAL,
  centroids, provenance). `scripts/build_parish_panel.jl` builds the 2,882
  mainland parishes over 2018-2023. (2026-11-26)
- `indicator_data(...; period)` takes a vector of labels or codes, sent as
  one comma-separated `Dim1`, or `:all`. (2026-11-26)
- `ispseudo`: INE's rows that are not places (abroad, unknown residence, the
  total), at every level. (2026-11-26)
- `cache_max_age` and `max_age` on every fetching function, from
  `PORTUGALINE_CACHE_MAX_AGE`; a stale response that cannot be refreshed is
  returned with a warning. The default stays "never expire". (2026-11-26)
- `dropped(ds).empty` in `join_municipal`: units listed with no value and no
  boundary (another parish map), as `join_panel` already had. (2026-11-26)
- A weekly API-drift check, `tools/check_api.jl`, with a baseline; weekly live
  tests in CI. (2026-11-26)
- Provenance: per column the indicator, period, dimension filter, language and
  extraction date; for the boundaries the file, its SHA-256 and the stated
  CAOP edition. (2026-11-26)
- Tests for `scripts/caop_gpkg_to_geojson.py` (`test/python`, standard
  library), run in CI on Linux and Windows. (2026-11-26)
- A documentation build (Documenter) that runs the doctests. (2026-11-26)
- Parishes: DICOFRE codes in both INE forms, `parish_values`, parish
  boundaries and join, the CAOP GeoPackage converter, and the 2,882-parish
  build on CAOP2024. (2026-11-25)
- Layers 1-4, the notebook-dataset script, and a check against the extract
  the Python route produced. (2026-11-06 to 2026-11-07)

### Changed
- Decisions (coverage, level, which dimension is geography) are made from
  codes or the Portuguese record, never from INE's English text alone; English
  stays the default `language`. (2026-11-26)
- Dimension filters use `cat_id`, not `categ_cod` (INE refuses the latter
  where they differ). (2026-11-26)
- Whole numbers are written as INE publishes them (`26`, not `26.0`).
  (2026-11-26)
- A transfer may be silent for 120 s, INE's own gateway limit, before it is
  abandoned; it was curl's 20 s. (2026-11-26)
- `build_parish_dataset.jl` joins through `join_municipal`, fetches each
  indicator once for all its periods, and takes the Census population from
  0012276 (identical totals for all 2,882 parishes) instead of 0012295, which
  INE cannot serve within its gateway's 120 s. Its data files are unchanged,
  byte for byte. (2026-11-26)
- Compat entries for every dependency, the standard libraries included.
  (2026-11-26)

### Fixed
- `_WEBMAP.md` printed DGT's credit twice: `write_webmap` appended it to a
  citation that already ends with it. (2026-11-28)
- `ine_citation` refuses, naming the column or indicator, when an extract has
  no extraction date. Before, the panel's citation silently left the date out
  and the others printed "extracted ." (2026-11-28)
- `ine_citation(panel)` threw a MethodError: Panel defined a function of its
  own instead of extending the exported one. (2026-11-27)
- A failed or malformed response was cached and served again; a body is now
  cached only once it parses. (2026-11-26)
- Retries live in the library: a reset connection, HTTP 429/5xx, a malformed
  body, and the 404s INE answers for valid codes when throttling. (2026-11-26)
- An extra dimension's values could land on the wrong rows. (2026-11-26)
- `write_gal` wrote names GAL cannot hold (whitespace, repeats); it refuses
  them. (2026-11-26)
- Residence abroad (`000000000`) and unknown residence (`999999999`) were
  taken for mainland parishes. (2026-11-26)
- `indicator_data`'s docstring said an unfiltered request returns every period;
  it returns the latest. (2026-11-26)
- The GeoPackage converter left its SQLite connection open, which on Windows
  keeps the file locked. (2026-11-26)
