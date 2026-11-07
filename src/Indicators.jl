"""
The INE indicator API: metadata, data, and the catalogue.

Three endpoints, all under `https://www.ine.pt`, all returning UTF-8:

| endpoint | what it gives | here |
|---|---|---|
| `json_indicador/pindicaMeta.jsp` | an indicator's dimensions and their codes | [`indicator_metadata`](@ref) |
| `json_indicador/pindica.jsp?op=2` | the observations | [`indicator_data`](@ref) |
| `xml_indic.jsp` | the catalogue, including each indicator's finest geography | [`catalogue`](@ref) |

## Why the catalogue is worth having

The catalogue carries `<geo_lastlevel>`, the finest geographic level an
indicator is published at. That answers "can I get this by municipality?"
without downloading the indicator and counting codes, which is how the question
otherwise has to be answered — one request of tens of kilobytes per candidate.
Of the 326 indicators in INE's main group, 98 reach `Município` and 17 reach
`Freguesia`; since a freguesia is *inside* a municipality, 115 are usable here.
[`ismunicipal`](@ref) applies that reasoning, and also absorbs INE's
inconsistent spelling of its own levels (both `NUTS III` and `NUTS 3` occur).

The main group is **not** all of INE: indicator `0014581` is published to
`Município` and does not appear in the group listing at all. So 115 is a floor
and not a census, [`catalogue`](@ref) is a cheap first pass rather than an
authority, and [`catalogue_entry`](@ref) is how a code the group omits gets
checked.

## The group catalogue ignores `lang` for titles

`xml_indic.jsp?opc=3` localises `theme` and `subtheme` and nothing else. All
326 titles come back identical under `lang=EN` and `lang=PT`, and all 326 are
Portuguese; all 326 themes differ between the two. That was measured by
fetching both and comparing, not inferred. So searching the group catalogue for
`"purchasing power"` finds nothing and `"poder de compra"` finds the indicator,
whatever `language` was passed.

The single-indicator call `opc=1` does honour `lang`: the same indicator's
title is `Per capita purchasing power` through [`catalogue_entry`](@ref) and
`Poder de compra per capita` through [`catalogue`](@ref). Search the group
catalogue in Portuguese, or on `theme`, which is localised; take an English
title from `catalogue_entry` once the code is known.

## Three things the API does that will catch you

**`valor` is a string.** A row reads
`{"geocod":"3003106","geodsg":"Porto Moniz","ind_string":"61,78","valor":"61.78"}`.
`valor` is the machine form with a decimal point, `ind_string` the localised
display form with a comma. This module parses `valor` and ignores `ind_string`;
reading the latter as a number silently loses the fractional part in any locale
that treats a comma as a separator.

**`Dados` is keyed by the period's label, but `Dim1` takes its code.** The 2022
annual slice of indicator 0008074 is requested with `Dim1=S7A2022` and comes
back under the key `"2022"`. Passing `"2022"` as the filter is rejected by INE
with "Code(s) in Dim1 not valid for the indicator"; passing `"S7A2022"` and
then looking for a `"S7A2022"` key finds nothing. [`period_code`](@ref)
converts a label to a code from the metadata, and [`indicator_data`](@ref)
accepts either.

**Failure arrives with HTTP 200.** An unknown indicator code returns
`{"Sucesso":{"Falso":[{"Msg":"...","Cod":"1"}]}}` and status 200. Every entry
point here checks `Sucesso` and throws INE's own message, so a typo surfaces as
an error rather than as an empty table.

## Caching

Responses are cached on disk, keyed by URL, because the API is slow and the
answers change a few times a year. See [`ine_cache_dir`](@ref) to find or
relocate the cache and [`clear_ine_cache!`](@ref) to drop it; pass
`cache = nothing` to any call to bypass it.
"""
module Indicators

using JSON3
using SHA: sha256
import Downloads

using ..Codes: ismunicipality, dico

export INE_ATTRIBUTION, DimensionCategory, Dimension, Indicator, IndicatorData,
       CatalogueEntry,
       indicator_metadata, indicator_data, catalogue, catalogue_entry,
       municipal_values, period_code, periods, ismunicipal, search_catalogue,
       ine_cache_dir, clear_ine_cache!, cache_response!, ine_citation,
       parse_value

const BASE = "https://www.ine.pt"

"""
    INE_ATTRIBUTION

The attribution INE's reuse terms require. Data from Statistics Portugal is
open for reuse, commercial use included, under EU Directive 2019/1024; INE
retains copyright and the single condition is that the source be cited.
[`ine_citation`](@ref) builds the sentence with the indicator codes and the
extraction date filled in, which is what the condition actually asks for.
"""
const INE_ATTRIBUTION = "Source: Statistics Portugal (INE)."

# The levels at which municipal data exists. A freguesia is inside a
# municipality, so an indicator published down to freguesia aggregates up.
# "Municipio" without the accent and both spellings of NUTS III are here
# because INE's own catalogue uses them interchangeably.
const MUNICIPAL_LEVELS = Set(["Município", "Municipio", "Freguesia"])

# ---------------------------------------------------------------------------
# types
# ---------------------------------------------------------------------------

"""
    DimensionCategory

One admissible value of a dimension: the `code` to send as a filter, the
`label` INE displays, and its depth in the dimension's own hierarchy
(`level` 1 is the root, so for geography level 1 is Portugal and level 5 is a
municipality).
"""
struct DimensionCategory
    code::String
    label::String
    level::Int
    order::Int
end

"""
    Dimension

One dimension of an indicator. `number` is the `Dim<n>` the API expects: 1 is
always the reference period and 2 is always geography. `categories` lists the
admissible codes.
"""
struct Dimension
    number::Int
    label::String
    version::String
    note::Union{String, Nothing}
    categories::Vector{DimensionCategory}
end

"""
    Indicator

An indicator's metadata, as returned by `pindicaMeta.jsp`. `dimensions` is
what makes a data request constructible: it names every filter the indicator
accepts and every code each filter will take.
"""
struct Indicator
    varcd::String
    name::String
    periodicity::String
    unit::String
    power10::Int
    decimals::Int
    first_period::String
    last_period::String
    note::Union{String, Nothing}
    last_update::String
    extracted::String
    language::String
    dimensions::Vector{Dimension}
end

"""
    IndicatorData

Observations, with the provenance needed to cite them. `table` is a
`NamedTuple` of equal-length vectors, which is already a valid Tables.jl
column table, so `DataFrame(d.table)` works without this package depending on
either DataFrames or Tables.

Columns are always `period`, `geocod`, `geodsg` and `value`, in that order.
`value` is `Union{Float64, Missing}`: INE suppresses some cells, and those
arrive as `missing` rather than as a sentinel number. There is no unit field,
because the data endpoint does not return one; the unit is
[`indicator_metadata`](@ref)'s `unit`. An indicator with
dimensions beyond period and geography adds `dim_<n>` and `dim_<n>_label` for
each.
"""
struct IndicatorData
    varcd::String
    name::String
    periods::Vector{String}
    last_update::String
    extracted::String
    table::NamedTuple
end

"""
    CatalogueEntry

One indicator as the catalogue describes it. `geo_lastlevel` is the field worth
the request: the finest geography the indicator is published at, which
[`ismunicipal`](@ref) reads.
"""
struct CatalogueEntry
    varcd::String
    title::String
    theme::String
    subtheme::String
    description::String
    geo_lastlevel::String
    source::String
    last_period::String
    last_update::String
    periodicity::String
    keywords::Vector{String}
end

Base.length(d::IndicatorData) = length(first(d.table))

function Base.show(io::IO, ind::Indicator)
    print(io, "Indicator(", ind.varcd, ", \"", ind.name, "\", ",
          length(ind.dimensions), " dimensions, ",
          ind.first_period, "-", ind.last_period, ")")
end

function Base.show(io::IO, d::IndicatorData)
    print(io, "IndicatorData(", d.varcd, ", ", length(d), " observations over ",
          length(d.periods), " period", length(d.periods) == 1 ? "" : "s", ")")
end

function Base.show(io::IO, e::CatalogueEntry)
    print(io, "CatalogueEntry(", e.varcd, ", \"", e.title, "\", to ",
          e.geo_lastlevel, ")")
end

# ---------------------------------------------------------------------------
# fetching and caching
# ---------------------------------------------------------------------------

"""
    ine_cache_dir() -> String

Where responses are cached. `ENV["PORTUGALINE_CACHE"]` overrides the default,
which is `portugalINE_cache` inside the first Julia depot. The directory is
created on first write, not here.
"""
ine_cache_dir() = get(ENV, "PORTUGALINE_CACHE",
                      joinpath(first(DEPOT_PATH), "portugalINE_cache"))

"""
    clear_ine_cache!(; dir = ine_cache_dir()) -> Int

Delete every cached response and return how many files went. Harmless if the
cache was never created.
"""
function clear_ine_cache!(; dir::AbstractString = ine_cache_dir())
    isdir(dir) || return 0
    n = 0
    for f in readdir(dir; join = true)
        isfile(f) && (rm(f); n += 1)
    end
    return n
end

# A cache filename that is stable, short, and legible enough to recognise in a
# directory listing: the endpoint, then a digest of the whole URL.
function _cache_file(url::AbstractString, dir::AbstractString)
    tag = occursin("pindicaMeta", url) ? "meta" :
          occursin("pindica", url)     ? "data" :
          occursin("xml_indic", url)   ? "cat"  : "other"
    return joinpath(dir, string(tag, "_", bytes2hex(sha256(url))[1:16]))
end

# One fetch, cached. Writes through a temporary file and renames, so an
# interrupted download cannot leave a truncated response behind to be trusted
# on the next call.
function _fetch(url::AbstractString; cache, timeout::Real)
    if cache !== nothing
        path = _cache_file(url, cache)
        isfile(path) && return read(path, String)
    end
    body = sprint() do io
        Downloads.download(url, io; timeout = float(timeout))
    end
    if cache !== nothing
        mkpath(cache)
        path = _cache_file(url, cache)
        tmp = path * ".part" * string(getpid())
        write(tmp, body)
        mv(tmp, path; force = true)
    end
    return body
end

# Percent-encode a query value. INE codes are alphanumeric in practice; this is
# here so that a caller passing something else gets a well-formed URL rather
# than a silently truncated one.
function _escape(s::AbstractString)
    out = IOBuffer()
    for b in codeunits(String(s))
        c = Char(b)
        if isletter(c) && isascii(c) || isdigit(c) || c in ('-', '_', '.', '~')
            write(out, c)
        else
            print(out, '%', uppercase(string(b, base = 16, pad = 2)))
        end
    end
    return String(take!(out))
end

# The three URLs, in one place, because both the fetchers and
# `cache_response!` have to agree on them to the character: the cache is keyed
# by URL, so a seeded response that differs by a parameter is a response that
# will never be found.
_meta_url(v, lang) =
    string(BASE, "/ine/json_indicador/pindicaMeta.jsp?varcd=", _escape(v),
           "&lang=", lang)

function _data_url(v, lang; period = nothing, dimensions = Dict{Int, String}())
    parts = String[string(BASE, "/ine/json_indicador/pindica.jsp?op=2&varcd=",
                          _escape(v), "&lang=", lang)]
    period === nothing || push!(parts, string("&Dim1=", _escape(String(period))))
    for n in sort(collect(keys(dimensions)))
        push!(parts, string("&Dim", n, "=", _escape(String(dimensions[n]))))
    end
    return join(parts)
end

_catalogue_url(lang; varcd = nothing) = varcd === nothing ?
    string(BASE, "/ine/xml_indic.jsp?opc=3&lang=", lang) :
    string(BASE, "/ine/xml_indic.jsp?opc=1&varcd=", _escape(varcd), "&lang=", lang)

"""
    cache_response!(path, kind, varcd = nothing; language = "EN", period = nothing,
                    dimensions = Dict(), dir = ine_cache_dir()) -> String

Put a saved INE response into the cache, as though it had just been fetched,
and return the cache file it was written to. `kind` is `:metadata`, `:data` or
`:catalogue`; `path` is the file holding the response body, or the body itself.

This is how an extract gets frozen. A result that has to be reproducible —
a paper's table, a dataset shipped with a package — depends on an API whose
answers are revised, so archive the response bodies, seed them here, and every
later call returns the archived figures with the network untouched. It is also
how this package's own tests run offline.

`period` must be the *code* (`"S7A2023"`), not the label, because that is what
goes in the URL the cache is keyed by.
"""
function cache_response!(path::AbstractString, kind::Symbol,
                         varcd = nothing; language = "EN", period = nothing,
                         dimensions::AbstractDict = Dict{Int, String}(),
                         dir::AbstractString = ine_cache_dir())
    lang = _check_language(language)
    url = if kind === :metadata
        _meta_url(_check_varcd(varcd), lang)
    elseif kind === :data
        _data_url(_check_varcd(varcd), lang; period, dimensions)
    elseif kind === :catalogue
        _catalogue_url(lang; varcd = varcd === nothing ? nothing : _check_varcd(varcd))
    else
        throw(ArgumentError("kind must be :metadata, :data or :catalogue, got " *
                            repr(kind) * "."))
    end
    body = isfile(path) ? read(path, String) : String(path)
    isempty(body) && throw(ArgumentError(
        "refusing to cache an empty response for $url. A zero-length body " *
        "would be returned as a parse failure on every later call."))
    mkpath(dir)
    out = _cache_file(url, dir)
    write(out, body)
    return out
end

_check_language(lang) = uppercase(String(lang)) in ("EN", "PT") ? uppercase(String(lang)) :
    throw(ArgumentError("language must be \"EN\" or \"PT\", got $(repr(lang)). " *
                        "INE serves these two and nothing else."))

function _check_varcd(varcd)
    s = String(varcd)
    occursin(r"^[0-9]{7}$", s) || throw(ArgumentError(
        "an indicator code is seven digits, got $(repr(s)). Leading zeros " *
        "matter: 0014580 is valid and 14580 is not, so pass it as a string."))
    return s
end

# INE answers a bad request with HTTP 200 and Sucesso.Falso. Surfacing its own
# message is more use than anything this package could invent.
function _check_success(obj, url::AbstractString)
    suc = get(obj, :Sucesso, nothing)
    suc === nothing && throw(ArgumentError(
        "INE's response carried no Sucesso field, so it is not the shape this " *
        "parser knows. URL: $url"))
    haskey(suc, :Verdadeiro) && return nothing
    if haskey(suc, :Falso)
        f = first(suc[:Falso])
        msg = get(f, :Msg, "(no message)")
        cod = get(f, :Cod, "?")
        throw(ArgumentError("INE refused the request (Cod $cod): $msg\nURL: $url"))
    end
    throw(ArgumentError("INE's Sucesso field held neither Verdadeiro nor Falso. " *
                        "URL: $url"))
end

# The single object INE wraps every JSON response in a one-element array around.
function _unwrap(body::AbstractString, url::AbstractString)
    parsed = JSON3.read(body)
    if parsed isa JSON3.Array
        isempty(parsed) && throw(ArgumentError(
            "INE returned an empty array. URL: $url"))
        return first(parsed)
    end
    return parsed
end

_str(x) = x === nothing ? nothing : String(x)
_int(x, default) = x === nothing ? default : (x isa Integer ? Int(x) : parse(Int, String(x)))

"""
    parse_value(x) -> Union{Float64, Missing}

Parse INE's `valor`, which arrives as a string with a decimal point, as `null`,
or absent. Anything unparseable becomes `missing` rather than an error: INE
suppresses cells for confidentiality and marks them in several ways, and a
suppressed cell is a fact about the data, not a malformed response.
"""
function parse_value(x)
    x === nothing && return missing
    x isa Real && return Float64(x)
    s = strip(String(x))
    (isempty(s) || s in ("-", "x", "//", "...")) && return missing
    v = tryparse(Float64, s)
    return v === nothing ? missing : v
end

# ---------------------------------------------------------------------------
# metadata
# ---------------------------------------------------------------------------

"""
    indicator_metadata(varcd; language = "EN", cache = ine_cache_dir(), timeout = 120)

Fetch an [`Indicator`](@ref): its dimensions, and the codes each dimension
accepts. Needed before a filtered data request, because the codes are not
guessable — the 2023 period of indicator 0014580 is `S7A2023`.

```julia
ind = indicator_metadata("0014580")
ind.dimensions[2].label              # "Geographic localization (NUTS - 2024)"
length(ind.dimensions[2].categories) # 347
```
"""
function indicator_metadata(varcd::AbstractString; language = "EN",
                            cache = ine_cache_dir(), timeout::Real = 120)
    v = _check_varcd(varcd)
    lang = _check_language(language)
    url = _meta_url(v, lang)
    obj = _unwrap(_fetch(url; cache, timeout), url)
    _check_success(obj, url)
    return _parse_metadata(obj, url)
end

function _parse_metadata(obj, url::AbstractString)
    dims = Dimension[]
    dz = get(obj, :Dimensoes, nothing)
    dz === nothing && throw(ArgumentError(
        "the metadata response had no Dimensoes block. URL: $url"))

    # Categoria_Dim is a one-element array holding a flat object whose keys are
    # "Dim_Num<n>_<code>". The nesting is not meaningful; the dim_num inside
    # each entry is, so group on that rather than on the key's spelling.
    cats = Dict{Int, Vector{DimensionCategory}}()
    cd = get(dz, :Categoria_Dim, nothing)
    if cd !== nothing
        blocks = cd isa JSON3.Array ? cd : (cd,)
        for blk in blocks, (_, entries) in pairs(blk)
            for e in (entries isa JSON3.Array ? entries : (entries,))
                n = _int(get(e, :dim_num, nothing), 0)
                push!(get!(cats, n, DimensionCategory[]),
                      DimensionCategory(String(get(e, :categ_cod, get(e, :cat_id, ""))),
                                        String(get(e, :categ_dsg, "")),
                                        _int(get(e, :categ_nivel, nothing), 0),
                                        _int(get(e, :categ_ord, nothing), 0)))
            end
        end
    end
    for v in values(cats)
        sort!(v; by = c -> c.order)
    end

    desc = get(dz, :Descricao_Dim, nothing)
    desc === nothing && throw(ArgumentError(
        "the metadata response had no Descricao_Dim block. URL: $url"))
    for d in desc
        n = _int(get(d, :dim_num, nothing), 0)
        push!(dims, Dimension(n, String(get(d, :abrv, "")),
                              String(get(d, :versao, "")),
                              _str(get(d, :nota_dsg, nothing)),
                              get(cats, n, DimensionCategory[])))
    end
    sort!(dims; by = d -> d.number)

    return Indicator(String(obj[:IndicadorCod]),
                     String(get(obj, :IndicadorNome, "")),
                     String(get(obj, :Periodic, "")),
                     String(get(obj, :UnidadeMedida, "")),
                     _int(get(obj, :Potencia10, nothing), 0),
                     _int(get(obj, :PrecisaoDecimal, nothing), 0),
                     String(get(obj, :PrimeiroPeriodo, "")),
                     String(get(obj, :UltimoPeriodo, "")),
                     _str(get(obj, :Nota, nothing)),
                     String(get(obj, :DataUltimaAtualizacao, "")),
                     String(get(obj, :DataExtracao, "")),
                     String(get(obj, :Lingua, "")),
                     dims)
end

"""
    period_code(ind::Indicator, period) -> String

Translate a period label into the code `Dim1` expects, which is the trap this
API sets most often: the metadata for an annual indicator lists its 2022 period
as code `S7A2022` with label `2022`, the filter must carry the code, and the
returned data is keyed by the label.

A value that is already a code passes through, so this is safe to apply twice.
Anything matching neither is refused with the admissible labels listed.
"""
function period_code(ind::Indicator, period::AbstractString)
    p = String(period)
    dim1 = findfirst(d -> d.number == 1, ind.dimensions)
    dim1 === nothing && throw(ArgumentError(
        "indicator $(ind.varcd) has no period dimension in its metadata."))
    cs = ind.dimensions[dim1].categories
    any(c -> c.code == p, cs) && return p
    i = findfirst(c -> c.label == p, cs)
    i === nothing && throw(ArgumentError(
        "$(repr(p)) is neither a period code nor a period label of indicator " *
        "$(ind.varcd). Labels available: " *
        join((c.label for c in cs), ", ") * "."))
    return cs[i].code
end

"""
    periods(ind::Indicator) -> Vector{String}

The period labels the indicator covers, oldest first.
"""
function periods(ind::Indicator)
    i = findfirst(d -> d.number == 1, ind.dimensions)
    i === nothing ? String[] : [c.label for c in ind.dimensions[i].categories]
end

# ---------------------------------------------------------------------------
# data
# ---------------------------------------------------------------------------

"""
    indicator_data(varcd; period = nothing, dimensions = Dict(),
                   language = "EN", cache = ine_cache_dir(), timeout = 300)

Fetch observations as an [`IndicatorData`](@ref).

`period` filters `Dim1` and may be a code (`"S7A2023"`) or a label (`"2023"`);
a label is translated, which costs one extra metadata request. `dimensions`
filters the rest, as `Dict(3 => "T")` for `Dim3=T`. Filtering matters: an
unfiltered multi-dimensional indicator is every period times every category,
which for some indicators is tens of megabytes.

```julia
d = indicator_data("0014580"; period = "2023")
length(d)                        # 347 geographic units
d.table.value[1]                 # 61.78
d = indicator_data("0008074"; period = "2022", dimensions = Dict(3 => "T"))
```

Omitting `period` returns every period the indicator has, with the `period`
column distinguishing them.
"""
function indicator_data(varcd::AbstractString; period = nothing,
                        dimensions::AbstractDict = Dict{Int, String}(),
                        language = "EN", cache = ine_cache_dir(),
                        timeout::Real = 300)
    v = _check_varcd(varcd)
    lang = _check_language(language)

    for n in keys(dimensions)
        n == 1 && throw(ArgumentError(
            "Dim1 is the reference period; pass it as `period = ...` so a " *
            "label can be translated to a code."))
        n == 2 && throw(ArgumentError(
            "Dim2 is geography, and this package returns every geographic " *
            "unit so that a weights matrix can be built over them. Filter the " *
            "returned table instead, or use `municipal_values`."))
    end

    p = nothing
    if period !== nothing
        p = String(period)
        # A label needs the metadata to become a code. A code is upper-case
        # alphanumeric and contains a letter; a bare "2023" is a label. Only
        # fetch the metadata when a translation can actually be needed, so the
        # common case stays one request.
        if !occursin(r"^[A-Z][A-Z0-9]*$", p)
            p = period_code(indicator_metadata(v; language = lang, cache, timeout), p)
        end
    end
    url = _data_url(v, lang; period = p, dimensions)

    obj = _unwrap(_fetch(url; cache, timeout), url)
    _check_success(obj, url)
    return _parse_data(obj, url)
end

function _parse_data(obj, url::AbstractString)
    dados = get(obj, :Dados, nothing)
    dados === nothing && throw(ArgumentError(
        "the response reported success but carried no Dados block. URL: $url"))

    # Collect first, so the extra-dimension columns can be discovered from the
    # rows rather than assumed from the metadata: a filtered request still
    # echoes the dimensions it was filtered on, and an unfiltered one does not
    # necessarily carry the same set.
    period_col = String[]; geocod = String[]; geodsg = String[]
    value = Union{Float64, Missing}[]
    extra = Dict{Symbol, Vector{String}}()
    order = Symbol[]
    periods_seen = String[]

    for (pkey, rows) in pairs(dados)
        plabel = String(pkey)
        push!(periods_seen, plabel)
        for r in rows
            push!(period_col, plabel)
            push!(geocod, String(get(r, :geocod, "")))
            push!(geodsg, _normalise_name(String(get(r, :geodsg, ""))))
            push!(value, parse_value(get(r, :valor, nothing)))
            for (k, x) in pairs(r)
                k in (:geocod, :geodsg, :valor, :ind_string) && continue
                col = get!(extra, k) do
                    push!(order, k)
                    # Backfill, so a key appearing only in later rows still
                    # lines up with the rows before it.
                    fill("", length(period_col) - 1)
                end
                push!(col, String(x))
            end
        end
        # Any extra column absent from this period's rows gets padded here, so
        # every vector stays the same length as `period_col`.
        for k in order
            v = extra[k]
            while length(v) < length(period_col)
                push!(v, "")
            end
        end
    end

    syms = Symbol[:period, :geocod, :geodsg, :value]
    cols = Any[period_col, geocod, geodsg, value]
    for k in order
        push!(syms, _rename_dim(k)); push!(cols, extra[k])
    end
    table = NamedTuple{Tuple(syms)}(Tuple(cols))

    sort!(periods_seen)
    return IndicatorData(String(get(obj, :IndicadorCod, "")),
                         String(get(obj, :IndicadorDsg, "")),
                         periods_seen,
                         String(get(obj, :DataUltimoAtualizacao, "")),
                         String(get(obj, :DataExtracao, "")),
                         table)
end

# INE names an extra dimension's code `dim_3` and its label `dim_3_t`. The
# suffix is not self-explanatory, so it becomes `dim_3_label`.
function _rename_dim(k::Symbol)
    s = String(k)
    m = match(r"^dim_([0-9]+)_t$", s)
    m === nothing && return k
    return Symbol("dim_", m.captures[1], "_label")
end

# Municipality names arrive with doubled interior spaces in a few cases
# ("Calheta  (R.A.M.)"), and two indicators disagreeing on the spacing breaks a
# join on name. Normalising here means the same unit has the same name across
# every indicator.
_normalise_name(s::AbstractString) = join(split(s), " ")

"""
    municipal_values(d::IndicatorData; period = nothing) -> NamedTuple

Reduce an [`IndicatorData`](@ref) to the municipal rows, keyed by DICO and
sorted by it, which is the ordering the weights files from
[`PortugalINE.Boundaries`](@ref) use. The result is a column table with `dico`,
`geocod`, `name` and `value`.

`geocod` is kept alongside the DICO because it carries the NUTS vintage the
figures were published on, and that is not cosmetic: the same municipality has
one NUTS code under NUTS 2024 and another under NUTS 2013. The DICO is stable
across both, which is why it is the key and the NUTS code is only a record of
where the figure came from.

Non-municipal rows are dropped: an INE geography response is a hierarchy, so
the 347 rows of indicator 0014580 are 308 municipalities plus country, NUTS I,
NUTS II and NUTS III aggregates, and summing the column would double-count
Portugal four times over. Suppressed cells stay as `missing` rather than being
dropped, so the length is the municipality count and a caller can see what is
absent.

With more than one period present, `period` is required.
"""
function municipal_values(d::IndicatorData; period = nothing)
    t = d.table
    if period === nothing
        length(d.periods) == 1 || throw(ArgumentError(
            "$(d.varcd) carries $(length(d.periods)) periods " *
            "($(join(d.periods, ", "))); pass `period = ` to choose one."))
        period = only(d.periods)
    end
    p = String(period)
    p in d.periods || throw(ArgumentError(
        "period $(repr(p)) is not in this data; it has " *
        join(d.periods, ", ") * "."))

    keep = findall(i -> t.period[i] == p && ismunicipality(t.geocod[i]),
                   eachindex(t.geocod))
    isempty(keep) && throw(ArgumentError(
        "no municipal rows in $(d.varcd) for period $(repr(p)). The indicator " *
        "may not be published below NUTS III; the catalogue's geo_lastlevel " *
        "says so without a download."))

    ds = [dico(t.geocod[i]) for i in keep]
    if length(unique(ds)) != length(ds)
        dup = sort(unique([x for x in ds if count(==(x), ds) > 1]))
        throw(ArgumentError(
            "DICO is not unique in this slice: " * join(dup, ", ") *
            ". That means more than one row per municipality, so a dimension " *
            "beyond period and geography is still unfiltered."))
    end

    perm = sortperm(ds)
    return (dico = ds[perm],
            geocod = [t.geocod[i] for i in keep][perm],
            name = [t.geodsg[i] for i in keep][perm],
            value = [t.value[i] for i in keep][perm])
end

"""
    ine_citation(d::IndicatorData...) -> String

The citation INE's reuse terms require, with the indicator codes, the reference
period and the extraction date filled in. Pass every extract that went into a
result and cite the sentence this returns.
"""
function ine_citation(ds::IndicatorData...)
    isempty(ds) && throw(ArgumentError("nothing to cite."))
    codes = sort(unique(d.varcd for d in ds))
    pers = sort(unique(p for d in ds for p in d.periods))
    date = first(sort([d.extracted for d in ds]))
    return string("Source: Statistics Portugal (INE), indicator",
                  length(codes) == 1 ? " " : "s ", join(codes, ", "),
                  ", reference period", length(pers) == 1 ? " " : "s ",
                  join(pers, ", "), ", extracted ", first(date, 10), ".")
end

# ---------------------------------------------------------------------------
# catalogue
# ---------------------------------------------------------------------------

"""
    catalogue(; language = "EN", cache = ine_cache_dir(), timeout = 300)

Every indicator in INE's main group, as [`CatalogueEntry`](@ref) values. One
request of roughly 500 kB, against one request per indicator for the same
information.

The group is not exhaustive -- `0014581` is a municipal indicator that is not
in it -- so a code absent from this listing is not an unpublished code. Look it
up with [`catalogue_entry`](@ref) before concluding anything.

`language` affects `theme` and `subtheme` only. Titles, descriptions and
keywords arrive in Portuguese whatever is passed, which is INE's behaviour and
not a choice made here -- see the note in this module's documentation. Search
accordingly, and use [`catalogue_entry`](@ref) for an English title.

```julia
cat = catalogue()
length(cat)                                  # 326
count(ismunicipal, cat)                      # 115
search_catalogue(cat, "poder de compra"; municipal_only = true)
catalogue_entry("0014580").title             # "Per capita purchasing power"
```
"""
function catalogue(; language = "EN", cache = ine_cache_dir(), timeout::Real = 300)
    lang = _check_language(language)
    url = _catalogue_url(lang)
    return _parse_catalogue(_fetch(url; cache, timeout), url)
end

"""
    catalogue_entry(varcd; language = "EN", cache = ine_cache_dir(), timeout = 120)

The catalogue record for one indicator, including indicators outside the main
group that [`catalogue`](@ref) does not list.

Unlike [`catalogue`](@ref), this endpoint honours `language` throughout, so it
is where an English title comes from.
"""
function catalogue_entry(varcd::AbstractString; language = "EN",
                         cache = ine_cache_dir(), timeout::Real = 120)
    v = _check_varcd(varcd)
    lang = _check_language(language)
    url = _catalogue_url(lang; varcd = v)
    es = _parse_catalogue(_fetch(url; cache, timeout), url)
    length(es) == 1 || throw(ArgumentError(
        "expected one catalogue entry for $v, parsed $(length(es)). URL: $url"))
    return only(es)
end

# The catalogue is flat, CDATA-wrapped XML with no attributes beyond the
# indicator id and no nesting that matters. A regex extractor is enough for
# that shape, and it keeps libxml2 and its build chain out of the dependency
# tree for a package whose other 400 lines parse JSON and hash tuples. It is
# written to fail loudly: a document that is not this shape raises rather than
# yielding an empty list, which is the failure mode that would otherwise look
# like "INE published nothing today".
function _parse_catalogue(body::AbstractString, url::AbstractString)
    occursin("<catalog", body) || throw(ArgumentError(
        "this is not an INE catalogue document: no <catalog> element. " *
        "URL: $url\nFirst 200 characters: " * first(strip(body), 200)))

    entries = CatalogueEntry[]
    for m in eachmatch(r"<indicator\s+id=\"([^\"]*)\"\s*>(.*?)</indicator>"s, body)
        id = m.captures[1]
        blk = m.captures[2]
        varcd = _xml_text(blk, "varcd")
        isempty(varcd) && (varcd = id)
        isempty(varcd) && throw(ArgumentError(
            "a catalogue entry had neither an id attribute nor a <varcd> " *
            "element. URL: $url"))
        dates = _xml_block(blk, "dates")
        push!(entries, CatalogueEntry(varcd,
                                      _xml_text(blk, "title"),
                                      _xml_text(blk, "theme"),
                                      _xml_text(blk, "subtheme"),
                                      _xml_text(blk, "description"),
                                      _xml_text(blk, "geo_lastlevel"),
                                      _xml_text(blk, "source"),
                                      _xml_text(dates, "last_period_available"),
                                      _xml_text(dates, "last_update"),
                                      _xml_text(blk, "periodicity"),
                                      _xml_keywords(blk)))
    end
    isempty(entries) && throw(ArgumentError(
        "the document had a <catalog> element but no <indicator> entries. " *
        "URL: $url"))
    return entries
end

function _xml_block(xml::AbstractString, tag::AbstractString)
    m = match(Regex("<" * tag * "\\s*>(.*?)</" * tag * ">", "s"), xml)
    return m === nothing ? "" : m.captures[1]
end

function _xml_text(xml::AbstractString, tag::AbstractString)
    return _clean(_xml_block(xml, tag))
end

# Strip the CDATA wrappers INE puts around nearly every value, unescape the
# entities it uses outside them, and collapse the whitespace it indents with.
function _clean(s::AbstractString)
    t = replace(String(s), r"<!\[CDATA\[(.*?)\]\]>"s => s"\1")
    t = replace(t, "&amp;" => "&", "&lt;" => "<", "&gt;" => ">",
                   "&quot;" => "\"", "&apos;" => "'")
    return join(split(t), " ")
end

# Keywords are a comma-separated list in which the individual items are
# CDATA-wrapped, so splitting has to happen after unwrapping.
function _xml_keywords(blk::AbstractString)
    raw = _clean(_xml_block(blk, "keywords"))
    return [k for k in strip.(split(raw, ',')) if !isempty(k)]
end

"""
    ismunicipal(e::CatalogueEntry) -> Bool

Whether the indicator is published at municipal level or finer, which is the
condition for building a municipal weights matrix over it.

`geo_lastlevel` names the *finest* level available, so `Freguesia` counts: a
freguesia is inside exactly one municipality, so the data aggregates up.
Levels coarser than a municipality do not, whatever they are called — and INE
calls NUTS III both `NUTS III` and `NUTS 3` in the same document, which is why
this is a function rather than a string comparison at the call site.
"""
ismunicipal(e::CatalogueEntry) = e.geo_lastlevel in MUNICIPAL_LEVELS

"""
    search_catalogue(entries, text; municipal_only = false) -> Vector{CatalogueEntry}

Catalogue entries whose title, theme, subtheme, description or keywords contain
`text`, ignoring case and accents, so `"municipio"` finds `"Município"`. With
`municipal_only`, restrict to indicators [`ismunicipal`](@ref) accepts.

Searching a [`catalogue`](@ref) listing means searching Portuguese titles,
because that endpoint returns Portuguese titles under either language. `theme`
and `subtheme` are localised and are searched too, so an English theme name
works on an English listing.
"""
function search_catalogue(entries::AbstractVector{CatalogueEntry},
                          text::AbstractString; municipal_only::Bool = false)
    needle = _fold(text)
    isempty(needle) && throw(ArgumentError("nothing to search for."))
    out = CatalogueEntry[]
    for e in entries
        municipal_only && !ismunicipal(e) && continue
        hay = _fold(string(e.title, " ", e.theme, " ", e.subtheme, " ",
                           e.description, " ", join(e.keywords, " ")))
        occursin(needle, hay) && push!(out, e)
    end
    return out
end

# Case- and accent-insensitive comparison, without a Unicode dependency: the
# accented characters that occur in Portuguese place and theme names, mapped to
# their unaccented forms.
const _FOLD = Dict('á' => 'a', 'à' => 'a', 'â' => 'a', 'ã' => 'a', 'ä' => 'a',
                   'é' => 'e', 'è' => 'e', 'ê' => 'e', 'ë' => 'e',
                   'í' => 'i', 'ì' => 'i', 'î' => 'i', 'ï' => 'i',
                   'ó' => 'o', 'ò' => 'o', 'ô' => 'o', 'õ' => 'o', 'ö' => 'o',
                   'ú' => 'u', 'ù' => 'u', 'û' => 'u', 'ü' => 'u',
                   'ç' => 'c', 'ñ' => 'n')

_fold(s::AbstractString) = map(c -> get(_FOLD, c, c), lowercase(String(s)))

end # module
