#!/usr/bin/env python3
"""Generate a character reference sheet for 3D reconstruction.

The prompt that produced repl/warrior-1024.png does three separable jobs, and
keeping them separate is what makes it reusable:

    subject   what the character is                -- you change this
    pose      how the body is arranged             -- reconstruction needs this
    plate     what surrounds it                    -- the mesh stage cuts against this

Only the subject should normally change. The pose exists because reconstruction
needs limbs clear of the torso and a front-on view; the plate exists because the
mesh stage needs a clean field to cut against.

The seed here is authoritative. tools/imgbench.py deliberately rewrites seeds so
warm runs cannot hit ComfyUI's result cache, which makes a seed written in a
graph advisory rather than real -- the seed recorded for the warrior image was
wrong for exactly that reason. This queues directly so what you pass is what runs.
"""
import argparse, json, os, subprocess, time, urllib.request, uuid

POSE  = ("full body, standing straight, arms slightly away from body, "
         "T-pose, front view")

# NOT "game character reference sheet". That phrase invites the conventions of
# a reference sheet -- callout busts, multiple views, prop breakouts -- and an
# orc shaman prompt produced a floating head vignette in the corner alongside
# the figure. TRELLIS reconstructs ONE volume from ONE image, so every extra
# disconnected subject corrupts the mesh, and the rig then reports
# NOT_A_CHARACTER because the result is not a standing figure.
PLATE = ("single figure alone, centred, isolated on a plain white background, "
         "no text, no logo, no additional views, no inset portraits")

def graph(prompt, seed, width, height, steps, cfg, prefix):
    return {
      "1": {"class_type":"UNETLoader","inputs":{"unet_name":"flux-2-klein-4b.safetensors","weight_dtype":"default"}},
      "2": {"class_type":"CLIPLoader","inputs":{"clip_name":"qwen_3_4b.safetensors","type":"flux2"}},
      "3": {"class_type":"VAELoader","inputs":{"vae_name":"flux2-vae.safetensors"}},
      "4": {"class_type":"CLIPTextEncode","inputs":{"text":prompt,"clip":["2",0]}},
      "5": {"class_type":"CLIPTextEncode","inputs":{"text":"","clip":["2",0]}},
      "6": {"class_type":"EmptyFlux2LatentImage","inputs":{"width":width,"height":height,"batch_size":1}},
      "7": {"class_type":"KSampler","inputs":{"model":["1",0],"seed":seed,"steps":steps,"cfg":cfg,
            "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],
            "latent_image":["6",0],"denoise":1.0}},
      "8": {"class_type":"VAEDecode","inputs":{"samples":["7",0],"vae":["3",0]}},
      "9": {"class_type":"SaveImage","inputs":{"images":["8",0],"filename_prefix":prefix}},
    }

def run(host, g):
    cid = str(uuid.uuid4()); t0 = time.time()
    req = urllib.request.Request(f"http://{host}/prompt",
            data=json.dumps({"prompt": g, "client_id": cid}).encode(),
            headers={"Content-Type": "application/json"})
    try:
        pid = json.loads(urllib.request.urlopen(req).read())["prompt_id"]
    except urllib.error.HTTPError as exc:
        raise SystemExit("service rejected the graph: " + exc.read().decode("utf-8","replace")[:300])
    while True:
        h = json.loads(urllib.request.urlopen(f"http://{host}/history/{pid}").read())
        if pid in h:
            st = h[pid].get("status", {})
            if st.get("completed") or st.get("status_str") == "success":
                return time.time() - t0
            if st.get("status_str") == "error":
                raise SystemExit("generation failed: " + json.dumps(st)[:300])
        time.sleep(1)

def fetch(prefix, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    src = subprocess.run(["podman","exec","media-comfy","bash","-lc",
            f"ls -t /opt/ComfyUI/output/{prefix}*.png 2>/dev/null | head -1"],
            capture_output=True, text=True).stdout.strip()
    if not src:
        return None
    dst = os.path.join(out_dir, prefix + ".png")
    subprocess.run(["podman","cp",f"media-comfy:{src}",dst], capture_output=True)
    return dst

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--subject", required=True, help="what the character IS")
    ap.add_argument("--pose", default=POSE, help="override the reconstruction pose")
    ap.add_argument("--plate", default=PLATE, help="override the background plate")
    ap.add_argument("--seed", type=int, default=100000)
    ap.add_argument("--size", type=int, default=1024)
    ap.add_argument("--steps", type=int, default=4)
    ap.add_argument("--cfg", type=float, default=1.0)
    ap.add_argument("--out", default=os.path.expanduser("~/t2m-out/characters"))
    ap.add_argument("--host", default="127.0.0.1:8188")
    ap.add_argument("--name", help="output basename (default: derived from subject)")
    ap.add_argument("--print-prompt", action="store_true", help="show the prompt and exit")
    a = ap.parse_args()

    prompt = ", ".join(p for p in (a.subject, a.pose, a.plate) if p)
    if a.print_prompt:
        print(prompt); raise SystemExit(0)

    name = a.name or "".join(c if c.isalnum() else "-" for c in a.subject.lower())[:40].strip("-")
    prefix = f"char-{name}-s{a.seed}"
    dt = run(a.host, graph(prompt, a.seed, a.size, a.size, a.steps, a.cfg, prefix))
    path = fetch(prefix, a.out)

    # Keep the inputs beside the artefact. A picture without its prompt is a
    # souvenir, not a result.
    if path:
        with open(os.path.splitext(path)[0] + ".json", "w") as fh:
            json.dump({"subject": a.subject, "pose": a.pose, "plate": a.plate,
                       "prompt": prompt, "seed": a.seed, "size": a.size,
                       "steps": a.steps, "cfg": a.cfg,
                       "model": "flux-2-klein-4b.safetensors",
                       "seconds": round(dt, 1)}, fh, indent=2)
    print(json.dumps({"seconds": round(dt,1), "image": path, "seed": a.seed, "prompt": prompt}))
