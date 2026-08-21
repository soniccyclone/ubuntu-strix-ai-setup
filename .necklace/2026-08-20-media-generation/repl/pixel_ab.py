#!/usr/bin/env python3
"""Generate the same pixel-art subject set on either track, for human eval.

The A/B method is Nathan's, from 08-pixel-art-plan: identical subjects, identical
post-processing, and the eye decides. This only produces the matched pairs.
"""
import json, sys, time, urllib.request, uuid, argparse

SUBJECTS = {
    "knight": "a brave knight in shining armor holding a sword",
    "archer": "an elven archer with bow and quiver wearing a green hood",
    "orc":    "a fierce orc warrior with a battle axe and tusks",
    "chest":  "a wooden treasure chest with iron bands, closed",
}

def klein(subject, seed):
    return {
      "1":{"class_type":"UNETLoader","inputs":{"unet_name":"flux-2-klein-4b.safetensors","weight_dtype":"default"}},
      "10":{"class_type":"LoraLoaderModelOnly","inputs":{"model":["1",0],"lora_name":"pixel-art-klein.safetensors","strength_model":1.0}},
      "2":{"class_type":"CLIPLoader","inputs":{"clip_name":"qwen_3_4b.safetensors","type":"flux2"}},
      "3":{"class_type":"VAELoader","inputs":{"vae_name":"flux2-vae.safetensors"}},
      "4":{"class_type":"CLIPTextEncode","inputs":{"text":f"pixel art sprite, {subject}, game asset, transparent background, 16-bit pixel art","clip":["2",0]}},
      "5":{"class_type":"CLIPTextEncode","inputs":{"text":"","clip":["2",0]}},
      "6":{"class_type":"EmptyFlux2LatentImage","inputs":{"width":512,"height":512,"batch_size":1}},
      "7":{"class_type":"KSampler","inputs":{"model":["10",0],"seed":seed,"steps":4,"cfg":1.0,
           "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],"latent_image":["6",0],"denoise":1.0}},
      "8":{"class_type":"VAEDecode","inputs":{"samples":["7",0],"vae":["3",0]}},
      "9":{"class_type":"SaveImage","inputs":{"images":["8",0],"filename_prefix":f"AB-klein-{subject_key}"}},
    }

def sdxl(subject, seed):
    return {
      "1":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"sd_xl_base_1.0.safetensors"}},
      "10":{"class_type":"LoraLoaderModelOnly","inputs":{"model":["1",0],"lora_name":"pixel-art-xl.safetensors","strength_model":1.0}},
      "4":{"class_type":"CLIPTextEncode","inputs":{"text":f"pixel art, {subject}, game asset sprite","clip":["1",1]}},
      "5":{"class_type":"CLIPTextEncode","inputs":{"text":"blurry, photorealistic, 3d render","clip":["1",1]}},
      "6":{"class_type":"EmptyLatentImage","inputs":{"width":1024,"height":1024,"batch_size":1}},
      "7":{"class_type":"KSampler","inputs":{"model":["10",0],"seed":seed,"steps":8,"cfg":2.0,
           "sampler_name":"euler_ancestral","scheduler":"normal","positive":["4",0],"negative":["5",0],"latent_image":["6",0],"denoise":1.0}},
      "8":{"class_type":"VAEDecode","inputs":{"samples":["7",0],"vae":["1",2]}},
      "9":{"class_type":"SaveImage","inputs":{"images":["8",0],"filename_prefix":f"AB-sdxl-{subject_key}"}},
    }

def run(host, graph):
    cid=str(uuid.uuid4()); t0=time.time()
    r=urllib.request.Request(f"http://{host}/prompt",
        data=json.dumps({"prompt":graph,"client_id":cid}).encode(),
        headers={"Content-Type":"application/json"})
    pid=json.loads(urllib.request.urlopen(r).read())["prompt_id"]
    while True:
        h=json.loads(urllib.request.urlopen(f"http://{host}/history/{pid}").read())
        if pid in h:
            st=h[pid].get("status",{})
            if st.get("completed") or st.get("status_str")=="success": return time.time()-t0,None
            if st.get("status_str")=="error": return time.time()-t0, json.dumps(st)[:300]
        time.sleep(1)

ap=argparse.ArgumentParser(); ap.add_argument("track",choices=["klein","sdxl"])
ap.add_argument("--host",default="127.0.0.1:8188"); ap.add_argument("--seed",type=int,default=424242)
a=ap.parse_args()
build = klein if a.track=="klein" else sdxl
for subject_key, subject in SUBJECTS.items():
    globals()["subject_key"]=subject_key
    dt,err=run(a.host, build(subject,a.seed))
    print(f"{a.track:<6} {subject_key:<8} {dt:7.1f} s" + (f"  ERROR {err}" if err else ""), flush=True)
