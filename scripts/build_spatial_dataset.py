#!/usr/bin/env python3
"""Build the static Portuguese municipal dataset for SpatialEconometrics.jl.

This is the *interim* producer. PortugalINE.jl layers 2 and 3 are not written
yet, so the extract is pulled with `pyptine`, the Python INE client, which
already works. When the Julia layers land this script is replaced by a Julia
equivalent and the output must not change.

Why a static extract at all: SpatialEconometrics.jl must never depend on a
network client. Its suite runs on five Julia configurations and its docs build
on every push, and none of that can be contingent on INE being reachable. So
the data flows one way -- pulled once here, committed there.

Indicators are all two-dimensional (period x geography), so no dimension
flattening is needed, and all carry every one of the 308 municipalities for
2023.

Note on vintages: indicator 0008258 is also "Ageing ratio" with identical
values, but on the **NUTS 2013** geography (344 codes, not 347). Joining it to
the NUTS 2024 indicators would misalign silently. 0012909 is the NUTS 2024
series and is the one used here. Always check the geography vintage named in
an indicator's title before joining.

Licence: INE data is open for reuse, commercially and otherwise, under EU
Directive 2019/1024. INE retains copyright and reuse is conditional on citing
the source, which is why this script writes a provenance file next to the data
recording the indicators and the extraction date.
"""
from __future__ import annotations

import csv
import datetime as dt
import io
import pathlib
import sys

from pyptine import INE

PERIOD = "S7A2023"

# varcd -> (column name, unit)
INDICATORS = {
    "0014580": ("purchasing_power", "index, Portugal = 100"),
    "0014581": ("pp_share_national", "% of national total"),
    "0014582": ("pp_dynamism", "relative factor"),
    "0013189": ("density", "inhabitants / km2"),
    "0012909": ("ageing_ratio", "persons 65+ per 100 aged 0-14"),
}

DISTRICTS = {
    1: "Aveiro", 2: "Beja", 3: "Braga", 4: "Braganca", 5: "Castelo Branco",
    6: "Coimbra", 7: "Evora", 8: "Faro", 9: "Guarda", 10: "Leiria",
    11: "Lisboa", 12: "Portalegre", 13: "Porto", 14: "Santarem",
    15: "Setubal", 16: "Viana do Castelo", 17: "Vila Real", 18: "Viseu",
    31: "Madeira", 32: "Madeira", 41: "Azores", 42: "Azores", 43: "Azores",
    44: "Azores", 45: "Azores", 46: "Azores", 47: "Azores", 48: "Azores",
    49: "Azores",
}


def municipal_rows(ine, varcd):
    """DICO -> (name, value) for the 308 municipalities of one indicator.

    A municipality code is seven *characters*, not seven digits: the NUTS III
    prefix may contain a letter, so `11D1819` (Tabuaco) is a municipality just
    as `1111601` is. Filtering on digits keeps 147 of the 308.
    """
    df = ine.get_data(varcd, dimensions={"Dim1": PERIOD}).to_dataframe()
    out = {}
    for r in df.itertuples():
        code = str(r.geocod)
        if len(code) != 7:
            continue
        dico = code[-4:]
        if not dico.isdigit():
            raise SystemExit(f"{varcd}: code {code!r} has a non-numeric DICO")
        if dico in out:
            raise SystemExit(f"{varcd}: duplicate DICO {dico}")
        # INE's own name strings are not consistent across indicators: DICO
        # 3101 is "Calheta  (R.A.M.)" in 0013189 and "Calheta (R.A.M.)" in
        # 0014580, differing by one space. Collapse internal whitespace so the
        # cross-indicator name check below tests the name and not the spacing.
        # Note also that two distinct municipalities are called Calheta, 3101
        # in Madeira and 4802 in the Azores, which is a second reason the name
        # can never be the join key and the DICO always can.
        name = " ".join(str(r.geodsg).split())
        out[dico] = (name, float(r.value))
    if len(out) != 308:
        raise SystemExit(f"{varcd}: expected 308 municipalities, got {len(out)}")
    return out


def main(outdir):
    ine = INE(language="EN")
    pulled = {}
    titles = {}
    for varcd in INDICATORS:
        titles[varcd] = ine.get_metadata(varcd).title
        pulled[varcd] = municipal_rows(ine, varcd)
        print(f"  {varcd}  {INDICATORS[varcd][0]:<18} 308 municipalities")

    # Names must agree across indicators, or the DICO join is not what it seems.
    base = pulled["0014580"]
    for varcd, rows in pulled.items():
        if set(rows) != set(base):
            raise SystemExit(f"{varcd}: DICO set differs from 0014580")
        for dico, (name, _) in rows.items():
            if name != base[dico][0]:
                raise SystemExit(
                    f"{varcd}: DICO {dico} is {name!r} here but "
                    f"{base[dico][0]!r} in 0014580")

    cols = ["dico", "name", "district", "district_name", "mainland"]
    cols += [INDICATORS[v][0] for v in INDICATORS]

    outdir.mkdir(parents=True, exist_ok=True)
    csv_path = outdir / "portugal_municipalities.csv"
    with io.open(csv_path, "w", encoding="utf-8", newline="\n") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(cols)
        for dico in sorted(base):
            dist = int(dico[:2])
            row = [dico, base[dico][0], dist, DISTRICTS[dist],
                   "true" if dist <= 18 else "false"]
            row += [f"{pulled[v][dico][1]:g}" for v in INDICATORS]
            w.writerow(row)

    n_main = sum(1 for d in base if int(d[:2]) <= 18)
    n_isl = len(base) - n_main
    today = dt.date.today().isoformat()
    prov = outdir / "portugal_municipalities_PROVENANCE.md"
    lines = [
        "# Portuguese municipalities: provenance and attribution",
        "",
        "> Source: Statistics Portugal (INE). Indicators "
        + ", ".join(INDICATORS) + f", reference period {PERIOD} (2023),",
        f"> extracted {today}.",
        "",
        "INE data is open for reuse, commercial and non-commercial, under EU",
        "Directive 2019/1024. INE retains copyright: the data is openly",
        "licensed, not public domain, and reuse is conditional on citing the",
        "source. The quoted block above is that citation; keep it with any",
        "published result built on these figures.",
        "",
        "## Contents",
        "",
        f"`portugal_municipalities.csv`: {len(base)} municipalities "
        f"({n_main} mainland, {n_isl} island), one row each.",
        "",
        "| column | indicator | unit |",
        "|---|---|---|",
        "| `dico` | official district-and-municipality code | 4 digits |",
        "| `name` | municipality name | |",
        "| `district`, `district_name` | district, from the first two DICO digits | 1-18 mainland |",
        "| `mainland` | whether district <= 18 | |",
    ]
    for v, (col, unit) in INDICATORS.items():
        lines.append(f"| `{col}` | {v} | {unit} |")
    lines += ["", "Full indicator titles, as INE states them:", ""]
    for v in INDICATORS:
        lines.append(f"- **{v}** - {titles[v]}")
    lines += [
        "",
        "## Two things to know before modelling",
        "",
        f"**The islands have no land neighbours.** Of the {len(base)} "
        f"municipalities, {n_isl} are in Madeira and the Azores. In a",
        "contiguity weights matrix over all of them those rows are entirely",
        "zero, and row-standardising divides by zero. Filter on `mainland` for",
        f"the {n_main}-municipality contiguous set, or use a k-nearest or",
        "distance-based weighting that gives every unit neighbours. The column",
        "is here so the choice is explicit rather than discovered in a singular",
        "matrix.",
        "",
        "**`purchasing_power`, `pp_share_national` and `pp_dynamism` come from",
        "the same INE study** and are not independent of one another. Use one as",
        "a dependent variable; do not put two of them on opposite sides of a",
        "regression and read the fit as a finding.",
        "",
        "## No weights matrix yet",
        "",
        "This extract is attributes only. A contiguity `W` needs boundaries,",
        "which come from INE's BGRI, and BGRI is not served by the indicator",
        "API -- it is a separate download from INE's geospatial portal. Until",
        "`PortugalINE.jl` layer 3 reads it, build `W` from coordinates or",
        "supply your own.",
        "",
        "## How this was produced",
        "",
        "`scripts/build_spatial_dataset.py` in `PortugalINE.jl`, which pulls",
        "through `pyptine`. Each indicator is two-dimensional (period x",
        "geography), so no dimension flattening is involved, and the script",
        "fails rather than writes if any indicator returns other than",
        f"{len(base)} municipalities, if any DICO is non-numeric or duplicated,",
        "or if the municipality names disagree across indicators.",
        "",
        "Indicator `0008258` is also \"Ageing ratio\" with identical values, but",
        "on the **NUTS 2013** geography (344 codes against 347). Joining it to",
        "the NUTS 2024 indicators would misalign silently, so `0012909`, the",
        "NUTS 2024 series, is used instead. Check the geography vintage named",
        "in an indicator's title before joining it to anything.",
        "",
    ]
    io.open(prov, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
    print(f"\nwrote {csv_path}")
    print(f"wrote {prov}")
    print(f"{len(base)} municipalities, {n_main} mainland, {n_isl} island")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: build_spatial_dataset.py <output-dir>")
    main(pathlib.Path(sys.argv[1]))
