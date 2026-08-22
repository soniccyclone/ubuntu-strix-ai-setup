#!/usr/bin/env python3
"""Drive the TRELLIS.2 mesh engine: image in, GLB out, timing on stdout."""
import argparse, json, os, time, urllib.request, uuid

def generate(endpoint, image, out, seed=42, resolution=512, target_faces=None, timeout=4000):
    boundary = "----t2m" + uuid.uuid4().hex
    fields = {"seed": str(seed), "resolution": str(resolution)}
    if target_faces:
        fields["target_faces"] = str(target_faces)
    body = b""
    for k, v in fields.items():
        body += (f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n').encode()
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="image"; '
             f'filename="{os.path.basename(image)}"\r\nContent-Type: image/png\r\n\r\n').encode()
    body += open(image, "rb").read() + b"\r\n" + f"--{boundary}--\r\n".encode()
    req = urllib.request.Request(endpoint.rstrip("/") + "/generate", data=body, method="POST",
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        glb = r.read()
    dt = time.time() - t0
    open(out, "wb").write(glb)
    return dt, len(glb)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("image"); ap.add_argument("out")
    ap.add_argument("--endpoint", default="http://127.0.0.1:8189")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--resolution", type=int, default=1024)  # match the Makefile; 512 is what produced a garbled mesh
    ap.add_argument("--target-faces", type=int)
    ap.add_argument("--timeout", type=int, default=4000)
    a = ap.parse_args()
    dt, n = generate(a.endpoint, a.image, a.out, a.seed, a.resolution, a.target_faces, a.timeout)
    print(json.dumps({"seconds": round(dt, 1), "bytes": n, "resolution": a.resolution,
                      "target_faces": a.target_faces, "out": a.out}))
