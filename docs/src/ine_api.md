# INE's API: verified behaviour

What Statistics Portugal's (INE) public API actually does, as opposed to what one would
expect. It is the one list kept for every client of the API: this package and
[pyptine](https://github.com/randsley/pyptine) (Python) both build on it, and a quirk found
by either is added here. Most of it is about INE, not about Julia.

Each entry was checked against the live API on the date given (2026-11-26/27 unless stated).
The weekly drift checks re-test what can be tested automatically: `tools/check_api.jl` here
and `tools/check_api.py` in pyptine. How each client handles an entry is described in that
client's own documentation.

## Services

No authentication.

| Service | URL |
|:--|:--|
| Metadata | `https://www.ine.pt/ine/json_indicador/pindicaMeta.jsp?varcd=<7 digits>&lang=EN` (or `PT`) |
| Data | `https://www.ine.pt/ine/json_indicador/pindica.jsp?op=2&varcd=...&lang=...&Dim1=<period code>&Dim<n>=<code>` |
| Catalogue | `https://www.ine.pt/ine/xml_indic.jsp?lang=...` with `opc=1&varcd=...` (one indicator), `opc=2` (all 13,290 indicators: 21 MB, about 1 MB gzipped on the wire, ~20 s) or `opc=3` (the main group, 309, ~500 kB) |

## Language

- **The English translations are inconsistent; Portuguese is the stable form.** Never decide
  anything (coverage, level, which dimension is geography) from English text alone: use
  codes, or the `lang=PT` record. English is fine for display.
- `opc=3` localises only `theme` and `subtheme`: titles, descriptions and keywords are
  Portuguese under either `lang`. `opc=1` and `opc=2` honour `lang`.
- Under `lang=EN`, `geo_lastlevel` is localised for some indicators only (0012600: `Parish`;
  0008234: `Freguesia`; 2,319 records say `Município`). INE spells NUTS III both `NUTS III`
  and `NUTS 3`.
- Under `lang=EN` the mainland (NUTS I `1`) stays "Continente", and residence abroad is
  labelled "Foreigner" (PT "Estrangeiro"), in births 0008234.

## Responses and refusals

- **A refusal arrives as HTTP 200**, with `{"Sucesso":{"Falso":[{"Msg":...,"Cod":...}]}}`:
  Cod 1 for an unknown indicator, Cod 4 for an invalid dimension code. Success is
  `Sucesso.Verdadeiro`. Check it on every response, and never cache a refusal.
- JSON responses are a **one-element array** around the object, in clean UTF-8 (a console
  showing `Tabua?o` or `Munic�pio` is the console's fault). So is the XML.
- **The catalogue answers a code it does not hold** (`opc=1`: 0004127, 9999999) with
  **HTTP 200 and a Java stack trace** instead of XML: `<pre>java.lang.NullPointerException`,
  6.6 kB, or a 63-byte form without the trace once the JVM omits it. Refuse it at once;
  retrying it as a malformed body only wastes time. Do not cache it.

## Load and throttling

- **INE answers HTTP 404 for valid codes when it throttles** a burst of requests. An unknown
  code is 200 + `Sucesso.Falso`, never 404, so a 404 is worth retrying (after a wait: 5, 20,
  60 s works).
- INE resets connections under load, and its gateway answers **504 after 120 s**. A client's
  read timeout must exceed 120 s, or it gives up before INE does.
- Some requests cannot be served within those 120 s at all: Census population **0012295**,
  even fully filtered. **0012276** (Dim3=T, Dim4=T) gives identical totals for all 2,882
  parishes.
- Under load the whole catalogue (`opc=2`) can answer **HTTP 200 with a truncated body**:
  about 1.1 MB of valid XML that stops mid-element, then a Java stack trace; the next request
  may get an nginx 502. Treat it as malformed (retry, keep it out of any cache), not as an
  unknown code.
- The weekly checks of the two clients run half an hour apart (Monday 06:30 and 07:00 UTC),
  so as not to make a burst.

## Data values

- `valor` is a string with a decimal point; `ind_string` is the localised display form
  (`10 599 117`, or a decimal comma). Parse `valor` only.
- Suppressed cells are `null` or absent, or markers: `-`, `x`, `//`, `...`.
- The data response has **no unit**: `UnidadeMedida` is in the metadata only.

## Periods

- `Dados` is keyed by the period **label** (`"2022"`; under `lang=EN` localised, such as
  `"1st Quarter 2026"`), but `Dim1` takes the period **code** (`S7A2022`). Sending the label
  is refused (Cod 4). Rows carry no period field: map the label to its code through the
  metadata's Dim1 (`categ_dsg` to `cat_id`, same language).
- Codes sort chronologically within an indicator (annual `S7A2022`, quarterly `S5A20261`,
  monthly `S3A202601`); labels do not ("4th Quarter 2019" sorts after "1st Quarter 2026").
- **An unfiltered data request returns only the latest period.** For several, send a
  comma-separated `Dim1` (`S7A2018,S7A2019`; `;` is refused). (`Dim1=T` also returns every
  period; undocumented.)
- **`start` and `count` are ignored**: the full body comes back every time. There is no row
  pagination; batch by periods instead.

## Dimensions and filters

- `Dim1` is always the period and `Dim2` the geography.
- A category has a `cat_id` and a `categ_cod`. Filters take the **`cat_id`**, and data rows
  echo it; the `categ_cod` is refused where the two differ (0012234 Dim3: `H1`, not `H.1`).
- Comma lists work on every dimension (0008273 `Dim3=1,2`), sent unescaped
  (`Dim1=S7A2021,S7A2022`) or as `%2C`: both are accepted.
- Extra dimensions appear in rows as `dim_<n>` (code) and `dim_<n>_t` (label). An unfiltered
  extra dimension gives several rows per geographic unit. Census 2021 indicators have a Sex
  dimension (`Dim3=T`: both sexes).
- In the metadata, `Categoria_Dim` keys are `Dim_Num<n>_<code>`.
- Dim2's `versao` (the geography's classification version) differs per indicator (03505,
  03513, 05431, 00879, ...), so it cannot serve as a list of known classifications.

## Geography

- **One data request returns every geographic level at once** (0008273, 2023: the country,
  3 NUTS I, 7 NUTS II, 25 NUTS III and 308 municipalities). Filter by level before adding up.
- **Code length gives the level**: 1 NUTS I, 2 NUTS II (`PT` is the country), 3 NUTS III,
  7 municipality (NUTS III + DICO), 9 parish (NUTS III + DICOFRE). Census 2021 indicators use
  **bare** codes: 4 for a DICO, 6 for a DICOFRE.
- **Districts instead of NUTS.** Some indicators code Dim2 by district (0004167, PT
  `Local de residência (Distrito/ Região)`: `PT`, `1`, `01`-`18`, `2`, `3`). There a
  two-digit code is a **district** (`11` Lisboa, `01` Aveiro), where under NUTS it is a NUTS II
  region (`11` Norte). A row's code cannot tell them apart; the dimension's full code list can:
  a district dimension holds `01`-`09`, and no NUTS II code starts with `0`.
- 14 of the 26 NUTS III codes contain a letter (`11A`-`11E`, `1A0`, `1B0`, `1C1`-`1D3`), so a
  pattern like `[0-9]{7}` finds only 147 of 308 municipalities.
- A DICOFRE is not always numeric: Barcelos (0302) coded its eight 2013 parish unions
  `0302FA`-`0302FH`.
- **Join on the DICO** (the last 4 characters of a municipality code), never on the NUTS code
  or the name: across NUTS 2013 and 2024 the NUTS code matches 132 of 308 municipalities, the
  name 305 (`Calheta` is two municipalities, 3101 and 4501), the DICO all 308.
- **Pseudo-units**, in births 0008234 at every level: abroad `0`, `00`, `000`, `0000000`,
  `000000000` or `YY` ("Estrangeiro"); unknown `9` ... `999999999`; total `T`. District `00`
  (abroad) and `99` (unknown) also occur inside municipality and parish codes.
- Islands are districts 31, **32** (Porto Santo) and 41-49: 278 mainland and 30 island
  municipalities. The mainland districts are 01-18.
- Municipality names sometimes have doubled interior spaces (`Calheta  (R.A.M.)`).
- **Two parish maps.** INE publishes parish figures on the 2013 map (3,092 parishes, 2,882 on
  the mainland) up to the 2024 reference period. Law 25-A/2025 restored 302 parishes, and
  CAOP2024.1 and CAOP2025 carry the new map (3,049 on the mainland). The area indicator
  0011866 lists both maps (3,184 mainland codes, no values for the restored parishes before
  2025).
- The metadata states the geometry edition its figures use ("CAOP 2020 ... NUTS 2024").
- Suppression varies by indicator: median net declared income 0012757 has 735 of the 2,882
  mainland parishes in 2024; mean gross declared income 0012748 has all of them.

## Metadata

- `pindicaMeta` sends only `IndicadorCod IndicadorNome Periodic PrimeiroPeriodo UltimoPeriodo
  UnidadeMedida Potencia10 PrecisaoDecimal Lingua DataUltimaAtualizacao DataExtracao Dimensoes
  Sucesso`. It never sends `Fonte Nota Descricao Tema Subtema GeoUltimoNivel UrlHtml UrlMeta
  UrlDados`: the description, theme, source, finest geographic level and URLs are in the
  catalogue's `opc=1` record.

## Catalogue

- The catalogue has **no `<unit>`**: the unit is in the metadata only.
- `<last_update>` is `DD-MM-YYYY`.
- `<keywords>` is a bare `INE`, then exactly 5 CDATA sections: three words cut from the title
  (punctuation kept: `Expenses,`, `2021)`), the theme and the subtheme (all 13,290 indicators,
  EN and PT). 2,642 have a **comma inside a CDATA section**, so split on CDATA boundaries,
  never on commas.
- `geo_lastlevel` gives an indicator's finest level; `Freguesia` counts as municipal (it
  aggregates up).
- **The main group is not all of INE**: `0014581` is published to Município and absent from
  `opc=3`, and indicators leave the group without being withdrawn (326 to 309 between
  2026-11-06 and 2026-11-26; resident population 0008273, ageing ratio 0008258 and parish
  live births 0008234 left, all still served). Use `opc=2` or `opc=1` for a given code.

## Provenance fields

- The data response sends `DataExtracao` (INE's extraction timestamp, UTC ISO with `Z`),
  `DataUltimoAtualizacao`, `MetaInfUrl` and `UltimoPref`. Use `DataExtracao` for provenance,
  not the local clock.
- The catalogue XML (`opc=1/2/3`) has a root `<extraction_date>` in one English form under
  either `lang`: `Friday, 27 November 2026, 04:17:58.067 PM`, with **no timezone**. It matched
  the UTC `DataExtracao` on 2026-11-27, but Lisbon is UTC+0 in winter: to be compared again
  in summer (after 2027-03-28).
- Reuse of INE's data is permitted, commercial use included, under EU Directive 2019/1024, on
  condition that the source is cited; INE retains copyright.
