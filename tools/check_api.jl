#!/usr/bin/env julia
#
# Check that INE's API still returns what PortugalINE.jl reads.
#
#     julia --project=. tools/check_api.jl                    # check
#     julia --project=. tools/check_api.jl --update-baseline  # accept changes
#
# INE publishes no machine-readable spec, so this checks live responses
# against the fields the parsers in `src/Indicators.jl` read, with the types
# they expect. It reads the raw JSON and XML, not the package's parsed
# structs, so a failure names the field that moved, not the parser that
# tripped over it.
#
# 1. Shape: each endpoint's response holds every field the client reads
#    (`READ_*` below; keep them in step with `src/Indicators.jl`).
# 2. Behaviour: the traps documented in CLAUDE.md and the README still hold
#    (Dados keyed by label, failure as HTTP 200, both code forms, `opc=1`
#    honouring `lang`, 308 municipalities).
# 3. Drift: keys and catalogue values compared with `tools/api_baseline.json`.
#    A key INE adds, the catalogue's size, and a new `geo_lastlevel`
#    spelling are warnings; a new spelling that names a municipal or parish
#    level is an error, because `ismunicipal` would silently reject it.
#
# Exit status 1 if anything the client relies on is missing or has changed
# meaning. Runs weekly in GitHub Actions (.github/workflows/api-check.yml),
# where problems also appear as annotations.

using PortugalINE
using PortugalINE.Indicators: _fetch, _meta_url, _data_url, _catalogue_url,
                              _parse_catalogue, MUNICIPAL_LEVELS
using JSON3

const BASELINE = joinpath(@__DIR__, "api_baseline.json")
const IN_ACTIONS = get(ENV, "GITHUB_ACTIONS", "") == "true"

const errors = String[]
const warnings = String[]

err(msg)  = (push!(errors, msg);   println(IN_ACTIONS ? "::error::$msg" : "ERROR    $msg"))
warn(msg) = (push!(warnings, msg); println(IN_ACTIONS ? "::warning::$msg" : "WARNING  $msg"))
ok(msg)   = println("ok       ", msg)

# One live request, through the package's fetch: no cache, retried on a reset
# connection or a 5xx, and `identity` as the parse so the raw body comes back.
fetch(url) = _fetch(identity, url; cache = nothing, timeout = 600)

# What the parsers read. A type of :str accepts a JSON string; :strint a
# string or an integer (INE sends numbers as strings, and a change to real
# numbers is survivable by `_int` but worth seeing); :opt marks a field that
# may be absent.
const READ_META = [:IndicadorCod => :str, :IndicadorNome => :str, :Periodic => :str,
                   :UnidadeMedida => :str, :Potencia10 => :strint,
                   :PrecisaoDecimal => :strint, :PrimeiroPeriodo => :str,
                   :UltimoPeriodo => :str, :DataUltimaAtualizacao => :str,
                   :DataExtracao => :str, :Lingua => :str, :Dimensoes => :obj,
                   :Sucesso => :obj]
const READ_DESC = [:dim_num => :strint, :abrv => :str, :versao => :str]
const READ_CATEG = [:dim_num => :strint, :categ_cod => :str, :categ_dsg => :str,
                    :categ_nivel => :strint, :categ_ord => :strint]
const READ_DATA = [:IndicadorCod => :str, :IndicadorDsg => :str, :DataExtracao => :str,
                   :DataUltimoAtualizacao => :str, :Dados => :obj, :Sucesso => :obj]
const READ_ROW = [:geocod => :str, :geodsg => :str, :valor => :valor]
const READ_FAIL = [:Msg => :str, :Cod => :strint]
const READ_CAT = ["varcd", "title", "theme", "subtheme", "description", "geo_lastlevel",
                  "source", "periodicity", "keywords", "dates", "last_period_available",
                  "last_update"]

istype(x, t) = t === :str    ? x isa AbstractString :
               t === :strint ? (x isa AbstractString && !isnothing(tryparse(Int, x))) || x isa Integer :
               t === :obj    ? x isa JSON3.Object :
               t === :valor  ? x === nothing || x isa AbstractString || x isa Real :
               error("unknown type $t")

function check_fields(where, obj, fields)
    bad = String[]
    for (k, t) in fields
        if !haskey(obj, k)
            push!(bad, "$k missing")
        elseif !istype(obj[k], t)
            push!(bad, "$k is $(repr(obj[k])), expected $t")
        end
    end
    isempty(bad) ? ok("$where: all $(length(fields)) fields the client reads") :
                   err("$where: " * join(bad, "; "))
    return isempty(bad)
end

unwrap(body) = (p = JSON3.read(body); p isa JSON3.Array ? first(p) : p)
keyset(obj) = sort!([String(k) for k in keys(obj)])

# Keys seen, for the baseline: added keys are worth a warning, never fatal.
const seen = Dict{String, Any}()

# ---------------------------------------------------------------------------
# 1 and 2: shape and behaviour, endpoint by endpoint
# ---------------------------------------------------------------------------

function check_metadata()
    url = _meta_url("0014580", "EN")
    m = unwrap(fetch(url))
    check_fields("metadata 0014580", m, READ_META) || return nothing
    haskey(m.Sucesso, :Verdadeiro) || err("metadata 0014580: Sucesso holds no Verdadeiro")
    seen["metadata"] = keyset(m)
    dz = m.Dimensoes
    for k in (:Descricao_Dim, :Categoria_Dim)
        haskey(dz, k) || (err("metadata 0014580: Dimensoes.$k missing"); return nothing)
    end
    foreach(d -> check_fields("metadata Descricao_Dim[$(d.dim_num)]", d, READ_DESC),
            dz.Descricao_Dim)
    nums = sort([parse(Int, string(d.dim_num)) for d in dz.Descricao_Dim])
    nums == [1, 2] ? ok("metadata 0014580: dimensions are 1 (period) and 2 (geography)") :
                     err("metadata 0014580: dimensions are $nums, expected [1, 2]")
    # Categoria_Dim: an array of objects whose values are arrays of categories.
    cats = [c for blk in dz.Categoria_Dim for (_, es) in pairs(blk) for c in es]
    isempty(cats) && (err("metadata 0014580: no categories in Categoria_Dim"); return nothing)
    bad = count(c -> !all(((k, t),) -> haskey(c, k) && istype(c[k], t), READ_CATEG), cats)
    bad == 0 ? ok("metadata 0014580: all $(length(cats)) categories carry the fields read") :
               err("metadata 0014580: $bad of $(length(cats)) categories lack a field in " *
                   join(first.(READ_CATEG), ", "))
    seen["metadata_category"] = keyset(cats[1])
    # Dim2 is geography: judged by its codes, not its label, which INE
    # translates inconsistently.
    any(c -> string(c.dim_num) == "2" && c.categ_cod == "PT", cats) &&
        count(c -> string(c.dim_num) == "2" && ismunicipality(String(c.categ_cod)), cats) == 308 ?
        ok("metadata 0014580: Dim2 holds PT and the 308 municipalities") :
        err("metadata 0014580: Dim2 no longer holds the geography codes (PT and 308 municipalities)")
    pers = [c for c in cats if string(c.dim_num) == "1"]
    isempty(pers) && (err("metadata 0014580: no period categories"); return nothing)
    last = pers[argmax([parse(Int, string(c.categ_ord)) for c in pers])]
    return (code = String(last.categ_cod), label = String(last.categ_dsg))
end

function check_data(period)
    url = _data_url("0014580", "EN"; period = period.code)
    d = unwrap(fetch(url))
    check_fields("data 0014580", d, READ_DATA) || return
    seen["data"] = keyset(d)
    # The trap: filtered by the code, keyed by the label.
    ks = String.(collect(keys(d.Dados)))
    if ks == [period.label] && period.code != period.label
        ok("data 0014580: filtered by $(period.code), keyed by $(period.label)")
    else
        err("data 0014580: Dados keys are $ks for Dim1=$(period.code); expected [$(period.label)]. " *
            "`indicator_data` and `_unit_values` rely on the label key.")
    end
    rows = d.Dados[Symbol(first(ks))]
    bad = count(r -> !all(((k, t),) -> haskey(r, k) && istype(r[k], t), READ_ROW), rows)
    bad == 0 ? ok("data 0014580: all $(length(rows)) rows carry geocod, geodsg, valor") :
               err("data 0014580: $bad of $(length(rows)) rows lack geocod, geodsg or valor")
    seen["data_row"] = keyset(rows[1])
    # valor is the machine form with a decimal point.
    v = [r.valor for r in rows if r.valor isa AbstractString]
    any(s -> occursin(',', s), v) && err("data 0014580: valor carries a decimal comma")
    nmun = count(r -> ismunicipality(String(r.geocod)), rows)
    nmun == 308 ? ok("data 0014580: 308 municipalities, all levels in one response ($(length(rows)) rows)") :
                  err("data 0014580: $nmun municipalities, expected 308")
end

function check_extra_dimension()
    url = _data_url("0008074", "EN"; period = "S7A2022", dimensions = Dict(3 => "T"))
    d = unwrap(fetch(url))
    rows = [r for (_, rs) in pairs(d.Dados) for r in rs]
    if !isempty(rows) && all(r -> haskey(r, :dim_3) && haskey(r, :dim_3_t), rows)
        ok("data 0008074 Dim3=T: rows carry dim_3 and dim_3_t")
    else
        err("data 0008074 Dim3=T: rows no longer carry dim_3 and dim_3_t, which " *
            "`_parse_data` turns into dim_3 and dim_3_label")
    end
end

function check_bare_codes()
    # The Census 2021 form: bare 4-character DICOs and 6-character DICOFREs.
    url = _data_url("0012328", "EN"; period = "S7A2021", dimensions = Dict(3 => "T"))
    d = unwrap(fetch(url))
    codes = [String(r.geocod) for (_, rs) in pairs(d.Dados) for r in rs]
    n4 = count(c -> length(c) == 4, codes); n6 = count(c -> length(c) == 6, codes)
    n7 = count(c -> length(c) in (7, 9), codes)
    if n4 == 308 && n6 == 3092 && n7 == 0
        ok("data 0012328: bare codes, 308 of 4 characters and 3,092 of 6")
    else
        err("data 0012328: $n4 four-character, $n6 six-character and $n7 prefixed codes; " *
            "expected 308, 3,092 and 0. The bare-code handling in `Codes` may need revisiting.")
    end
end

function check_failure()
    url = _meta_url("9999999", "EN")
    body = try
        fetch(url)
    catch e
        err("metadata 9999999: the request itself failed ($(sprint(showerror, e))); " *
            "INE used to answer an unknown code with HTTP 200")
        return
    end
    f = unwrap(body)
    if haskey(f, :Sucesso) && haskey(f.Sucesso, :Falso) && !isempty(f.Sucesso.Falso)
        check_fields("failure for 9999999 (HTTP 200)", first(f.Sucesso.Falso), READ_FAIL)
    else
        err("metadata 9999999: no Sucesso.Falso; `_check_success` reports INE's refusals from it")
    end
end

function check_catalogue_entry()
    body = fetch(_catalogue_url("EN"; varcd = "0014580"))
    occursin("<catalog", body) || (err("catalogue opc=1: no <catalog> element"); return)
    missing_tags = [t for t in READ_CAT if !occursin("<$t", body)]
    isempty(missing_tags) ? ok("catalogue opc=1: all $(length(READ_CAT)) tags the client reads") :
                            err("catalogue opc=1: missing tag(s) " * join(missing_tags, ", "))
    e = only(_parse_catalogue(body, "opc=1"))
    # Informational only: nothing in the package depends on an English title.
    e.title == "Per capita purchasing power" ? ok("catalogue opc=1: English title unchanged") :
        warn("catalogue opc=1: English title is now $(repr(e.title))")
    # opc=1 localises geo_lastlevel for some indicators only (0012600 gives
    # "Parish" under EN, 0008234 "Freguesia"). Whatever it says now, it must be
    # a spelling `ismunicipal` accepts.
    # Both languages: the Portuguese is the stable one, the English is what a
    # caller gets by default.
    for v in ("0012600", "0008234"), lang in ("PT", "EN")
        l = only(_parse_catalogue(fetch(_catalogue_url(lang; varcd = v)), "opc=1")).geo_lastlevel
        l in MUNICIPAL_LEVELS ? ok("catalogue opc=1 $v $lang: geo_lastlevel $(repr(l)) is accepted") :
            err("catalogue opc=1 $v $lang: geo_lastlevel $(repr(l)) is a parish indicator's " *
                "level that `ismunicipal` rejects; add it to MUNICIPAL_LEVELS")
    end
end

function check_catalogue_group()
    es = _parse_catalogue(fetch(_catalogue_url("EN")), "opc=3")
    ok("catalogue opc=3: $(length(es)) indicators")
    seen["catalogue_size"] = length(es)
    levels = sort(unique(e.geo_lastlevel for e in es))
    seen["geo_lastlevel"] = levels
    # A spelling `ismunicipal` does not know, for a level it should accept,
    # is a silent loss of indicators: an error, not a warning.
    fold(s) = lowercase(replace(s, 'í' => 'i'))
    for l in levels
        if !(l in MUNICIPAL_LEVELS) &&
           any(w -> occursin(w, fold(l)), ("munic", "fregues", "parish"))
            err("catalogue opc=3: geo_lastlevel $(repr(l)) looks municipal or parish " *
                "but `ismunicipal` rejects it; add it to MUNICIPAL_LEVELS")
        end
    end
    any(e -> e.varcd == "0014581", es) &&
        warn("catalogue opc=3: 0014581 is now in the main group (it was absent; the docs say so)")
    # The codes in the group, for the baseline: indicators leave it without
    # being withdrawn (28 left between 2026-11-06 and 2026-11-26, resident
    # population 0008273 among them, all still served by opc=1).
    seen["catalogue_codes"] = sort([e.varcd for e in es])
    seen["catalogue_municipal"] = count(e -> e.geo_lastlevel in MUNICIPAL_LEVELS, es)
end

# ---------------------------------------------------------------------------
# 3: drift against the baseline
# ---------------------------------------------------------------------------

function compare_baseline(update::Bool)
    if update
        open(BASELINE, "w") do io
            JSON3.pretty(io, JSON3.write(seen)); println(io)
        end
        println("baseline updated: ", BASELINE)
        return
    end
    isfile(BASELINE) || (warn("no baseline at $(basename(BASELINE)); create one with --update-baseline"); return)
    base = JSON3.read(read(BASELINE, String))
    for (k, now) in seen
        haskey(base, Symbol(k)) || (warn("baseline has no entry for $k"); continue)
        was = base[Symbol(k)]
        if now isa AbstractVector
            added = setdiff(now, String.(was)); removed = setdiff(String.(was), now)
            isempty(added) || warn("$k: new value(s) " * join(added, ", "))
            isempty(removed) || warn("$k: value(s) gone " * join(removed, ", "))
        elseif now != was
            warn("$k changed: $was -> $now")
        end
    end
end

function main(args)
    update = "--update-baseline" in args
    for f in (() -> (p = check_metadata(); p === nothing || check_data(p)),
              check_extra_dimension, check_bare_codes, check_failure,
              check_catalogue_entry, check_catalogue_group)
        try
            f()
        catch e
            err("unexpected failure: " * sprint(showerror, e))
        end
    end
    compare_baseline(update)
    println()
    println(length(errors), " error(s), ", length(warnings), " warning(s)")
    exit(isempty(errors) ? 0 : 1)
end

main(ARGS)
