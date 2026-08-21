#!/usr/bin/env python3
"""Check a rigged GLB has a coherent skeleton, not just a valid file.

The glTF validator accepts a rig with duplicate bone names and only one side of
the body. Observed on a generated orc:

    legs   mixamorig:LeftUpLeg x2, LeftLeg x2   -- no Right leg at all
    arms   mixamorig:RightArm x2, RightShoulder x2  -- no Left arm at all

Both limb pairs were sided wrongly, in opposite directions. Upstream's own
guard is `if not left or not right: raise`, which counts Left and Right across
the WHOLE body -- so lefts from the legs and rights from the arms satisfy it
while every pair is broken. The visible symptom is a missing walk clip, because
the clip builder requires RightUpLeg and RightLeg and quietly returns None.

An engine keying animation by bone name gets two bones called
mixamorig:LeftUpLeg and no right leg. That is worth failing on.
"""
import json, struct, sys, argparse
from collections import Counter

PAIRS = [("LeftUpLeg","RightUpLeg"), ("LeftLeg","RightLeg"),
         ("LeftFoot","RightFoot"), ("LeftArm","RightArm"),
         ("LeftForeArm","RightForeArm"), ("LeftShoulder","RightShoulder")]

def load(path):
    d = open(path, "rb").read()
    if d[:4] != b"glTF":
        raise SystemExit(f"{path}: not a GLB")
    n = struct.unpack("<I", d[12:16])[0]
    return json.loads(d[20:20+n])

def check(path, want_clips):
    j = load(path)
    problems = []
    if not j.get("skins"):
        return [f"{path}: no skin, so nothing is rigged"]
    names = [j["nodes"][x].get("name", "") for x in j["skins"][0]["joints"]]

    dupes = {n: c for n, c in Counter(names).items() if c > 1 and n}
    if dupes:
        problems.append("duplicate joint names (an engine cannot address these): "
                        + ", ".join(f"{n} x{c}" for n, c in sorted(dupes.items())))

    present = set(names)
    for left, right in PAIRS:
        l, r = f"mixamorig:{left}" in present, f"mixamorig:{right}" in present
        if l != r:
            problems.append(f"one-sided limb: {left if l else right} present, "
                            f"{right if l else left} missing")

    clips = [a.get("name") for a in j.get("animations", [])]
    for c in want_clips:
        if c not in clips:
            problems.append(f"missing clip '{c}' (have: {clips or 'none'})")
    return problems

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("glb")
    ap.add_argument("--clips", default="idle,walk")
    a = ap.parse_args()
    probs = check(a.glb, [c for c in a.clips.split(",") if c])
    if probs:
        print(f"REJECT {a.glb}", file=sys.stderr)
        for p in probs:
            print("  - " + p, file=sys.stderr)
        raise SystemExit(4)
    j = load(a.glb)
    print(f"ok: {len(j['skins'][0]['joints'])} joints, clips "
          f"{[x.get('name') for x in j.get('animations',[])]}, no duplicate names")
