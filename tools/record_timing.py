#!/usr/bin/env python3
"""Append a row to the timing record.

Every column is mandatory on purpose. A bare duration is not reproducible: on
the image stage cold and warm differ by 3x, and on the mesh stage a smaller
face target is slower than a larger one. A row that omits residency or target
tells a later reader nothing they can act on.
"""
import argparse, pathlib, sys
REC = pathlib.Path("bench/media-timings.tsv")
ap = argparse.ArgumentParser()
for f in ("stage", "model", "precision", "resolution", "residency", "seconds"):
    ap.add_argument("--" + f, required=True)
ap.add_argument("--target-faces", default="-")
ap.add_argument("--notes", default="")
a = ap.parse_args()
if not REC.exists():
    sys.exit(f"{REC} missing")
row = "\t".join([a.stage, a.model, a.precision, a.resolution, a.residency,
                 a.target_faces, a.seconds, a.notes])
with REC.open("a") as fh:
    fh.write(row + "\n")
print(row)
