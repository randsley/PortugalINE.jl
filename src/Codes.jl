"""
Geography codes as Statistics Portugal issues them.

Every INE indicator that varies by place carries a code in dimension **2**
(dimension 1 is the reference period). The codes form a prefix hierarchy, and
their lengths are the only thing that says which level a row describes:

| length | level | example |
|---|---|---|
| 2 | country, or NUTS II | `PT`, `11` (Norte) |
| 1 | NUTS I | `1` (Continente) |
| 3 | NUTS III | `111` (Alto Minho), `11D` (Douro) |
| 7 | municipality | `1111601` (Arcos de Valdevez), `11D1819` (Tabuaço) |
| 9 | parish (freguesia) | `11C130741` (Vila Boa de Quires e Maureles) |
| 4 | municipality, bare DICO | `1307` (Census 2021 indicators) |
| 6 | parish, bare DICOFRE | `130741` (Census 2021 indicators) |

**INE uses two forms.** Most indicators prefix the NUTS III code (7 and 9
characters). The Census 2021 indicators give the bare official code instead:
the 4-digit DICO for a municipality and the 6-digit DICOFRE for a parish.
Measured on 2026-11-25: indicators 0012328 and 0012273 (unemployment and
illiteracy, Census 2021) carry 308 four-character and 3,092 six-character
codes and no seven- or nine-character ones. Before the bare forms were
recognised, `municipal_values` found no municipal rows in them and said the
indicator stopped at NUTS III, which was false.

**A municipality code is not seven digits.** Its first three characters are the
NUTS III code, which may contain a letter: 14 of the 26 NUTS III codes do, among
them `11A` to `11E`, `1A0`, `1B0` and `1C1` to `1D3`. Matching municipalities
with a seven-digit pattern such as `r"[0-9]{7}"` keeps 147 of the 308 and drops the rest without complaint,
which is the mistake this module exists to make impossible.

The **last four characters are the DICO**, the official municipality code
(district and municipality within it). It is numeric for all 308 municipalities
and unique across them, so it is the key to join INE indicators to a geometry.
The NUTS III prefix is not: NUTS III regions and districts cross-cut each other.
Arouca is `11A0104`, a municipality of Aveiro district (DICO `01` + `04`) in the
Porto metropolitan NUTS III region, and nothing in the first three characters
recovers its district.
"""
module Codes

export GeoLevel, COUNTRY, NUTS1, NUTS2, NUTS3, MUNICIPALITY, PARISH,
       geolevel, isnuts3, ismunicipality, isparish, dico, dicofre, nuts3, district,
       ismainland, isisland, DISTRICT_NAMES

"""
    GeoLevel

Which level of the hierarchy a geography code describes. `geolevel` returns one.
"""
@enum GeoLevel COUNTRY NUTS1 NUTS2 NUTS3 MUNICIPALITY PARISH

"""
    geolevel(code) -> GeoLevel

The level `code` describes, from its length. Throws `ArgumentError` on a length
INE does not use, rather than guessing: an unexpected length means the code came
from somewhere this parser does not model, and silently treating it as the
nearest level is how a whole geographic tier goes missing from an analysis.

```jldoctest
julia> geolevel("1111601")
MUNICIPALITY::GeoLevel = 4

julia> geolevel("11D")
NUTS3::GeoLevel = 3
```
"""
function geolevel(code::AbstractString)
    n = length(code)
    n == 7 && return MUNICIPALITY
    n == 9 && return PARISH
    n == 3 && return NUTS3
    if n == 4
        all(isdigit, code) || throw(ArgumentError(
            "not a geography code INE issues: $(repr(code)) has length 4, and a " *
            "4-character code is a bare DICO, which is numeric"))
        return MUNICIPALITY
    end
    if n == 6
        _isdicofre(code) || throw(ArgumentError(
            "not a geography code INE issues: $(repr(code)) has length 6, and a " *
            "6-character code is a bare DICOFRE: four digits, then two digits " *
            "or capital letters"))
        return PARISH
    end
    n == 1 && return NUTS1
    if n == 2
        # "PT" is the country; a two-character numeric code is NUTS II.
        return code == "PT" ? COUNTRY : NUTS2
    end
    throw(ArgumentError(
        "not a geography code INE issues: $(repr(code)) has length $n, " *
        "and INE uses 1, 2, 3, 4, 6, 7 and 9"))
end

"""
    ismunicipality(code) -> Bool

Whether `code` names one of the 308 municipalities: a 7-character code
(letters in the NUTS III prefix included), or a bare 4-digit DICO.
"""
ismunicipality(code::AbstractString) =
    length(code) == 7 || (length(code) == 4 && all(isdigit, code))

# A DICOFRE is the DICO and two more characters. Those are digits for every
# parish but the eight unions of the 2013 reform in Barcelos (DICO 0302), which
# had more than 99 parishes and coded the unions 0302FA to 0302FH. CAOP's
# `dtmnfr` uses the same codes, so they join.
_isdicofre(s::AbstractString) =
    length(s) == 6 && all(isdigit, s[1:4]) &&
    all(c -> isdigit(c) || 'A' <= c <= 'Z', s[5:6])

"""
    isparish(code) -> Bool

Whether `code` names a parish (freguesia): a 9-character code (NUTS III prefix
plus DICOFRE) or a bare 6-character DICOFRE.
"""
isparish(code::AbstractString) =
    length(code) == 9 || (length(code) == 6 && _isdicofre(code))

"""
    isnuts3(code) -> Bool

Whether `code` names one of the 26 NUTS III regions.
"""
isnuts3(code::AbstractString) = length(code) == 3

"""
    dico(code) -> String

The DICO of a municipality code: its last four characters, the official
district-and-municipality number. This is the key to join INE indicators to a
geometry, because it is numeric and unique across all 308 while the NUTS III
prefix is neither a district nor unique to one.

```jldoctest
julia> dico("11A0104")   # Arouca
"0104"
```
"""
function dico(code::AbstractString)
    ismunicipality(code) || throw(ArgumentError(
        "DICO is defined for a municipality code (7 characters, or a bare 4-digit " *
        "DICO); got $(repr(code)), which is $(geolevel(code))"))
    d = code[(end - 3):end]
    all(isdigit, d) || throw(ArgumentError(
        "the last four characters of $(repr(code)) are $(repr(d)), which are " *
        "not all digits; a DICO is numeric for every INE municipality"))
    return d
end

"""
    dicofre(code) -> String

The DICOFRE of a parish code: its last six characters, the official
district, municipality and parish number. It is the parish key, as the DICO is
the municipal one, and CAOP's `dtmnfr` property carries the same code. Its
first four digits are the parish's DICO.

**A DICOFRE is not always numeric.** Its last two characters are digits for
every parish except the eight 2013 unions of Barcelos (DICO 0302), coded
`0302FA` to `0302FH` because the municipality had more than 99 parishes.
Checking for six digits would drop those eight. That was the first version of
this function, and the real data stopped it.

```jldoctest
julia> dicofre("11C130741")
"130741"

julia> dicofre("130741")   # the bare form of the Census 2021 indicators
"130741"
```
"""
function dicofre(code::AbstractString)
    isparish(code) || throw(ArgumentError(
        "DICOFRE is defined for a parish code (9 characters, or a bare " *
        "6-character DICOFRE); got $(repr(code)), which is $(geolevel(code))"))
    d = code[(end - 5):end]
    _isdicofre(d) || throw(ArgumentError(
        "the last six characters of $(repr(code)) are $(repr(d)), which is not " *
        "a DICOFRE: four digits, then two digits or capital letters"))
    return d
end

"""
    nuts3(code) -> String

The NUTS III code a municipality belongs to: the first three characters, which
may contain a letter.
"""
function nuts3(code::AbstractString)
    (length(code) == 7 || length(code) == 9) || throw(ArgumentError(
        "a NUTS III prefix is defined for a 7-character municipality code or a " *
        "9-character parish code; got $(repr(code)), which is $(geolevel(code))" *
        (length(code) in (4, 6) ? ", a bare code with no NUTS prefix" : "")))
    return code[1:3]
end

"""
    district(code) -> Int

The district number of a municipality or parish, the first two digits of its
DICO (or DICOFRE). 1 to 18 are mainland districts, 31 and 32 the Madeira
districts, 41 to 49 the Azores.
"""
district(code::AbstractString) =
    parse(Int, (isparish(code) ? dicofre(code) : dico(code))[1:2])

"""
    ismainland(code) -> Bool
    isisland(code) -> Bool

Whether a municipality or parish is on the mainland or in the autonomous
regions, by district number. This distinction is not cosmetic: the 30 island municipalities
share no land border with anything, so in a contiguity weights matrix over all
308 they are isolated vertices whose rows are entirely zero. Row-standardising
such a matrix divides by zero. Decide between the 278 mainland municipalities
and a distance- or neighbour-count-based weighting before building `W`, rather
than discovering it in a singular matrix.
"""
ismainland(code::AbstractString) = district(code) <= 18
isisland(code::AbstractString) = !ismainland(code)

"""
    DISTRICT_NAMES

The 20 districts and autonomous-region groupings by number, as the first two
digits of a DICO encode them.
"""
const DISTRICT_NAMES = Dict{Int, String}(
    1 => "Aveiro", 2 => "Beja", 3 => "Braga", 4 => "Bragança",
    5 => "Castelo Branco", 6 => "Coimbra", 7 => "Évora", 8 => "Faro",
    9 => "Guarda", 10 => "Leiria", 11 => "Lisboa", 12 => "Portalegre",
    13 => "Porto", 14 => "Santarém", 15 => "Setúbal",
    16 => "Viana do Castelo", 17 => "Vila Real", 18 => "Viseu",
    31 => "Madeira", 32 => "Madeira", 41 => "Azores", 42 => "Azores",
    43 => "Azores", 44 => "Azores", 45 => "Azores", 46 => "Azores",
    47 => "Azores", 48 => "Azores", 49 => "Azores",
)

end # module
