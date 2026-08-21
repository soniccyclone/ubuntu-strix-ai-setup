# Local patches to upstream projects

Each entry says what was changed, why, and **how to tell when it stops being
needed**. A patch working around a missing wheel expires when the wheel ships;
a patch working around a design decision does not. Recording only the first
half turns a temporary workaround into permanent folklore.

Nothing here is a fork. The upstream checkouts are unmodified except as listed.

---

## 1. `hec-ovi/text-to-3D-skill` — rig layer built against the wrong base

**Upstream:** `layers/rig/docker/Dockerfile`, `FROM comfyui-strix-halo:latest`.

**Why:** That is the sibling `comfyui-strix-docker` image, which is Debian-based
with `uv` and a venv at `/app/.venv`. This project uses
`docker.io/kyuz0/amd-strix-halo-comfyui` instead, because that image's numbers
were calibrated against a published reference on identical work
(77.7 s against 75.4 s for Qwen-Image 4-step). It is Fedora, with `dnf`, no
`uv`, and a venv at `/opt/venv`.

**Patched:** `apt-get` to `dnf` with Fedora package names
(`mesa-libGL glib2 libgomp`); `/app/.venv/bin/python` to `/opt/venv/bin/python`;
`uv pip install --python X` to `python -m pip install`; explicit interpreter in
the ENTRYPOINT.

**Expires when:** this project adopts the sibling image, or upstream supports a
Fedora base. Neither is likely; treat as permanent for as long as the base
choice stands.

---

## 2. `hec-ovi/text-to-3D-skill` — `open3d` dropped from the rig image

**Upstream:** same Dockerfile installs `open3d`.

**Why:** open3d publishes no wheel for **Python 3.13**, which the calibrated
base ships. It is imported lazily inside exactly two SkinTokens functions:

    src/rig_package/parser/bpy.py:175      import open3d as o3d
    src/rig_package/info/asset.py:595      import open3d as o3d

Neither is on this pipeline's path, because the toolkit feeds meshes through
the npz loader rather than the bpy parser — the same reason it needs no Blender.
Rigging runs correctly without it, verified across four tests.

**Expires when:** open3d ships a cp313 wheel, or the base moves to 3.12. Check
with `pip index versions open3d`. If a future code path does reach it, the
ImportError names the file, which is a better failure than not building.

---

## 3. `hec-ovi/text-to-3D-skill` — services run unprivileged

**Upstream:** `docker-compose.yml` sets `privileged: true` on the rig service.

**Why:** not needed on rootless podman here. `--device=/dev/kfd
--device=/dev/dri --group-add keep-groups` is sufficient; `keep-groups` carries
the `render` membership through the user namespace. Verified: ROCm enumerates
`gfx1151` and the rig service loads its model and answers.

This is a reduction in privilege relative to upstream, not a workaround, and
`tests/m09-services.bats` fails if any service regains it.

**Expires when:** never. If it breaks, something else changed and the test says
so.

---

## 4. Sprite transparency is constructed, not generated

**Upstream:** `Limbicnation/pixel-art-lora` model card claims
"**512x512 RGBA** output with transparent backgrounds".

**Why:** it does not. Every sprite is PNG colour type 2 — no alpha. The model
paints a checkerboard, which is how transparency is *displayed* in its training
data, and is visually identical to real transparency in any viewer. The Flux
VAE returns three channels, so no standard workflow can emit alpha at all.

**Worked around by:** prompting for a plain solid magenta field and keying it
with `tools/key_bg.py` — edge flood fill with tolerance, stdlib only.

**Expires when:** a generator on this stack emits colour type 6 directly.
`tests/m01-sprite.bats` asserts the raw output is type 2 and will fail if that
day comes, which is the intended way to find out.
