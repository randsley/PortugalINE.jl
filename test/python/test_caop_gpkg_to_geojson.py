"""Tests for scripts/caop_gpkg_to_geojson.py, standard library only.

    python -m unittest discover -s test/python

Each test writes a small GeoPackage with sqlite3: the GeoPackage tables the
converter reads (gpkg_contents, gpkg_geometry_columns) and a layer whose
geometry blobs are built here byte by byte, so the encoding under test is
explicit rather than whatever a GIS library happens to write.
"""
import importlib.util
import json
import os
import sqlite3
import struct
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "scripts", "caop_gpkg_to_geojson.py")
_spec = importlib.util.spec_from_file_location("caop_gpkg_to_geojson", SCRIPT)
conv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(conv)

# Coordinates no decimal round trip preserves by accident: the converter must
# copy the stored doubles bit for bit, because contiguity matches vertices
# exactly.
X0, Y0 = -87654.32109876543, 0.1 + 0.2
SQUARE = [[X0, Y0], [X0 + 100.0, Y0], [X0 + 100.0, Y0 + 100.0], [X0, Y0 + 100.0], [X0, Y0]]
HOLE = [[X0 + 10.0, Y0 + 10.0], [X0 + 10.0, Y0 + 20.0], [X0 + 20.0, Y0 + 20.0], [X0 + 10.0, Y0 + 10.0]]
OTHER = [[X0 + 200.0, Y0], [X0 + 300.0, Y0], [X0 + 300.0, Y0 + 50.0], [X0 + 200.0, Y0]]


def wkb_polygon(rings, order="<"):
    out = struct.pack(order + "BII", 1 if order == "<" else 0, 3, len(rings))
    for r in rings:
        out += struct.pack(order + "I", len(r))
        out += struct.pack(order + "%dd" % (2 * len(r)), *[c for p in r for c in p])
    return out


def wkb_multipolygon(polys, order="<"):
    out = struct.pack(order + "BII", 1 if order == "<" else 0, 6, len(polys))
    for rings in polys:
        out += wkb_polygon(rings, order)
    return out


def gpkg_blob(wkb, envelope=1, empty=False, srs=3763, magic=b"GP"):
    # Header: magic, version 0, flags (bit 0 little-endian header, bits 1-3 the
    # envelope code, bit 4 empty), srs_id, envelope doubles, then the WKB.
    flags = 0x01 | (envelope << 1) | (0x10 if empty else 0)
    n = {0: 0, 1: 4, 2: 6, 3: 6, 4: 8}.get(envelope, 0)
    return magic + bytes([0, flags]) + struct.pack("<i", srs) + struct.pack("<%dd" % n, *([0.0] * n)) + wkb


def write_gpkg(path, rows, layer="cont_freguesias", srs=3763):
    con = sqlite3.connect(path)
    con.execute("create table gpkg_contents (table_name text primary key, data_type text)")
    con.execute("create table gpkg_geometry_columns (table_name text, column_name text, srs_id integer)")
    con.execute("insert into gpkg_contents values (?, 'features')", (layer,))
    con.execute("insert into gpkg_geometry_columns values (?, 'geom', ?)", (layer, srs))
    con.execute(f'create table "{layer}" (fid integer primary key, geom blob, dtmnfr text, freguesia text)')
    con.executemany(f'insert into "{layer}" (geom, dtmnfr, freguesia) values (?, ?, ?)', rows)
    con.commit()
    con.close()


class GeometryBlobs(unittest.TestCase):
    def test_polygon_with_a_hole_little_endian(self):
        g = conv.gpkg_geometry(gpkg_blob(wkb_polygon([SQUARE, HOLE])))
        self.assertEqual(g, {"type": "Polygon", "coordinates": [SQUARE, HOLE]})

    def test_big_endian_wkb(self):
        g = conv.gpkg_geometry(gpkg_blob(wkb_polygon([SQUARE], order=">")))
        self.assertEqual(g["coordinates"], [SQUARE])

    def test_multipolygon(self):
        g = conv.gpkg_geometry(gpkg_blob(wkb_multipolygon([[SQUARE, HOLE], [OTHER]])))
        self.assertEqual(g, {"type": "MultiPolygon", "coordinates": [[SQUARE, HOLE], [OTHER]]})

    def test_every_envelope_size_is_skipped(self):
        for code in (0, 1, 2, 3, 4):
            with self.subTest(envelope=code):
                g = conv.gpkg_geometry(gpkg_blob(wkb_polygon([SQUARE]), envelope=code))
                self.assertEqual(g["coordinates"], [SQUARE])

    def test_coordinates_are_copied_bit_for_bit(self):
        g = conv.gpkg_geometry(gpkg_blob(wkb_polygon([SQUARE])))
        x, y = g["coordinates"][0][0]
        self.assertEqual(struct.pack("<dd", x, y), struct.pack("<dd", X0, Y0))
        # And through JSON, as the converter writes them.
        x2, y2 = json.loads(json.dumps(g))["coordinates"][0][0]
        self.assertEqual(struct.pack("<dd", x2, y2), struct.pack("<dd", X0, Y0))

    def test_refusals(self):
        point = struct.pack("<BIdd", 1, 1, X0, Y0)
        cases = {
            "not GP": gpkg_blob(wkb_polygon([SQUARE]), magic=b"XX"),
            "empty": gpkg_blob(wkb_polygon([SQUARE]), empty=True),
            "a point": gpkg_blob(point),
            "envelope code 5": gpkg_blob(wkb_polygon([SQUARE]), envelope=5),
        }
        for why, blob in cases.items():
            with self.subTest(why), self.assertRaises(ValueError):
                conv.gpkg_geometry(blob)


class Layers(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.gpkg = os.path.join(self.dir.name, "t.gpkg")
        self.out = os.path.join(self.dir.name, "t.json")

    def tearDown(self):
        self.dir.cleanup()

    def test_a_layer_to_geojson(self):
        write_gpkg(self.gpkg, [
            (gpkg_blob(wkb_polygon([SQUARE])), "030201", "Abade de Neiva"),
            (gpkg_blob(wkb_multipolygon([[OTHER]])), "0302FA", "União das freguesias de Alheira e Igreja Nova"),
        ])
        conv.main(self.gpkg, "cont_freguesias", self.out)
        with open(self.out, encoding="utf-8") as f:
            fc = json.load(f)
        self.assertEqual(fc["crs"]["properties"]["name"], "urn:ogc:def:crs:EPSG::3763")
        self.assertEqual(len(fc["features"]), 2)
        # The fid and the geometry column are not properties; the rest are,
        # as text (a DICOFRE can hold letters, and leading zeros matter).
        self.assertEqual(fc["features"][1]["properties"],
                         {"dtmnfr": "0302FA", "freguesia": "União das freguesias de Alheira e Igreja Nova"})
        self.assertEqual(fc["features"][0]["geometry"]["coordinates"], [SQUARE])
        # Written as UTF-8, not escaped.
        with open(self.out, encoding="utf-8") as f:
            self.assertIn("União", f.read())

    def test_unknown_layer_is_refused(self):
        write_gpkg(self.gpkg, [(gpkg_blob(wkb_polygon([SQUARE])), "030201", "x")])
        with self.assertRaises(SystemExit) as e:
            conv.main(self.gpkg, "cont_municipios", self.out)
        self.assertIn("cont_freguesias", str(e.exception))
        self.assertFalse(os.path.exists(self.out))

    def test_a_bad_feature_fails_the_layer(self):
        # Not skipped: a parish silently missing would change the weights.
        write_gpkg(self.gpkg, [
            (gpkg_blob(wkb_polygon([SQUARE])), "030201", "x"),
            (gpkg_blob(struct.pack("<BIdd", 1, 1, X0, Y0)), "030202", "y"),
        ])
        with self.assertRaises(ValueError):
            conv.main(self.gpkg, "cont_freguesias", self.out)
        self.assertFalse(os.path.exists(self.out))


if __name__ == "__main__":
    unittest.main()
