#!/usr/bin/env python3
"""Report a GLB's structure from its JSON chunk. Stdlib only."""
import json, struct, sys
d = open(sys.argv[1], "rb").read()
assert d[:4] == b"glTF", "not a GLB"
n = struct.unpack("<I", d[12:16])[0]
j = json.loads(d[20:20+n])
prims = [p for m in j.get("meshes", []) for p in m["primitives"]]
tri = 0
for p in prims:
    if "indices" in p:
        tri += j["accessors"][p["indices"]]["count"] // 3
print(json.dumps({
    "triangles": tri,
    "meshes": len(j.get("meshes", [])),
    "textures": len(j.get("textures", [])),
    "skins": len(j.get("skins", [])),
    "joints": len(j["skins"][0]["joints"]) if j.get("skins") else 0,
    "animations": [a.get("name") for a in j.get("animations", [])],
    "has_joints_attr": any("JOINTS_0" in p["attributes"] for p in prims),
    "joint_names": [j["nodes"][x].get("name","") for x in (j["skins"][0]["joints"][:3] if j.get("skins") else [])],
}))
