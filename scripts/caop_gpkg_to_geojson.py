"""Convert one layer of a CAOP GeoPackage to the GeoJSON `read_caop_geojson` reads.

    python scripts/caop_gpkg_to_geojson.py Continente_CAOP2024.gpkg cont_freguesias out.json

DGT publishes each CAOP vintage as a GeoPackage, and only the current vintage
through its OGC API. A parish dataset needs an *older* vintage, the one whose
parish map matches INE's (see build_parish_dataset.jl), so it has to come from
the GeoPackage. A GeoPackage is a SQLite database whose geometry column holds a
short header followed by standard WKB, so the Python standard library reads it:
no GDAL, and nothing to install. Coordinates are copied as stored, bit for bit
(CAOP's are EPSG:3763, metres), because contiguity is found by matching shared
vertices exactly and any reprojection would round them.

Only Polygon and MultiPolygon are decoded; anything else is an error, not a
skipped feature.
"""
import json
import sqlite3
import struct
import sys


def _envelope_bytes(flags):
    code = (flags >> 1) & 0x07
    sizes = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}
    if code not in sizes:
        raise ValueError(f"invalid GeoPackage envelope code {code}")
    return sizes[code]


def _rings(buf, off, order, n):
    rings = []
    for _ in range(n):
        (npts,) = struct.unpack_from(order + "I", buf, off)
        off += 4
        pts = struct.unpack_from(order + "%dd" % (2 * npts), buf, off)
        off += 16 * npts
        rings.append([[pts[2 * i], pts[2 * i + 1]] for i in range(npts)])
    return rings, off


def _wkb(buf, off):
    order = "<" if buf[off] == 1 else ">"
    (gtype,) = struct.unpack_from(order + "I", buf, off + 1)
    off += 5
    if gtype == 3:  # Polygon
        (nr,) = struct.unpack_from(order + "I", buf, off)
        rings, off = _rings(buf, off + 4, order, nr)
        return {"type": "Polygon", "coordinates": rings}, off
    if gtype == 6:  # MultiPolygon
        (np_,) = struct.unpack_from(order + "I", buf, off)
        off += 4
        polys = []
        for _ in range(np_):
            g, off = _wkb(buf, off)
            if g["type"] != "Polygon":
                raise ValueError("a MultiPolygon member is not a Polygon")
            polys.append(g["coordinates"])
        return {"type": "MultiPolygon", "coordinates": polys}, off
    raise ValueError(f"WKB geometry type {gtype} is not Polygon (3) or MultiPolygon (6)")


def gpkg_geometry(blob):
    if blob[:2] != b"GP":
        raise ValueError("not a GeoPackage geometry blob (no 'GP' magic)")
    flags = blob[3]
    if flags & 0x10:
        raise ValueError("empty geometry")
    start = 8 + _envelope_bytes(flags)
    geom, _ = _wkb(blob, start)
    return geom


def main(path, layer, out):
    # Closed on every path: on Windows an open connection keeps the file locked.
    con = sqlite3.connect(path)
    try:
        fc, srs = _layer(con, path, layer)
    finally:
        con.close()
    with open(out, "w", encoding="utf-8") as f:
        json.dump(fc, f, ensure_ascii=False)
    print(f"wrote {len(fc['features'])} features from {layer} (EPSG:{srs}) to {out}")


def _layer(con, path, layer):
    tables = [r[0] for r in con.execute("select table_name from gpkg_contents")]
    if layer not in tables:
        raise SystemExit(f"no layer {layer!r} in {path}; it has {tables}")
    gcol, srs = con.execute(
        "select column_name, srs_id from gpkg_geometry_columns where table_name = ?",
        (layer,)).fetchone()
    cols = [r[1] for r in con.execute(f'pragma table_info("{layer}")')]
    props = [c for c in cols if c not in (gcol, "fid")]
    feats = []
    for row in con.execute(f'select "{gcol}", ' + ", ".join(f'"{c}"' for c in props) + f' from "{layer}"'):
        feats.append({"type": "Feature",
                      "properties": dict(zip(props, row[1:])),
                      "geometry": gpkg_geometry(row[0])})
    fc = {"type": "FeatureCollection",
          "crs": {"type": "name", "properties": {"name": f"urn:ogc:def:crs:EPSG::{srs}"}},
          "features": feats}
    return fc, srs


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
