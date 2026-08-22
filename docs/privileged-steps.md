# Steps that needed root

Every command here was **handed to Nathan and run by him**. No agent session in
this project can escalate — `sudo -n` fails — so this is enforced rather than
promised.

Each entry states why root was needed, how to verify it took, and how to undo it.

---

## 1. Raise the GTT ceiling (done, 2026-08-20)

**Why.** The amdgpu driver defaults GTT to half of RAM. Measured before: 61.41 GiB
of 122.82 GiB installed, with the BIOS UMA carve-out already at its 512 MiB
minimum. The 122B model needs 69.10 GiB and could not be loaded at all.

Full procedure, measurements and rollback:
`.necklace/2026-08-19-local-claude-suite/repl/gtt-change.md`

```
sudo cp /etc/default/grub /etc/default/grub.bak
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"$/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.gttsize=112640 ttm.pages_limit=28835840"/' /etc/default/grub
sudo update-grub
```

**Verify.** `cat /sys/class/drm/card1/device/mem_info_gtt_total` → `118111600640`.

**Rollback.** `sudo cp /etc/default/grub.bak /etc/default/grub && sudo update-grub && sudo reboot`.
If it will not boot: hold Shift from power-on, `e` on the Ubuntu entry, delete the
two arguments from the `linux` line, Ctrl-X. Nothing is written to firmware.

---

## 2. Group membership for the render node (done, 2026-08-20)

**Why.** `/dev/kfd` is `root render` and Nathan was in neither `render` nor
`video`. This blocked the ROCm path, the ComfyUI container in the media cycle,
and the SkinTokens rig service.

```
sudo usermod -aG render,video nathan
```

**Verify.** `id -nG | tr ' ' '\n' | grep -E 'render|video'` → both.

**Rollback.** `sudo gpasswd -d nathan render && sudo gpasswd -d nathan video`.

---

## 3. Close the contract to the LAN — NOT NEEDED, no root required

**Superseded.** An earlier version of this document asked for four `ufw`
commands enabling a machine-wide firewall to protect one port. That was a
band-aid over a design I had given up on too early, and it is not needed.

The contract binds `127.0.0.1` and nothing else:

```
$ ss -ltn 'sport = :8080'
LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:*
```

A socket bound to loopback cannot receive a packet addressed to a routable
interface. That is the kernel's behaviour, not a filter, so there is no rule to
forget and no policy to enable.

Containers still reach it because the path does not use the network stack at
all: a host `socat` bridges `127.0.0.1:8080` to a unix socket at
`$XDG_RUNTIME_DIR/contract.sock` (mode `0600`, inside a `0700` directory), and
`contract-proxy` — which runs `socat`, is not an agent, and never sees a model
or a prompt — has that one socket bind-mounted. Agents get no mount but their
own work volume.

Verified by `make test-isolation`, which asserts the binding directly rather
than inferring it from a connection refusal, because a refusal could come from
a firewall someone later disables.

**If the ufw commands were already run**, undo them:

```
sudo ufw disable
```

`ufw` was inactive before any of this, so disabling returns the machine to where
it started.

---

## 4. Vulkan/shader build dependencies (done, 2026-08-22)

**Why.** Needed to compile the ROCmFPX engine's Vulkan shaders. `build-essential`,
`git` and `mesa-vulkan-drivers` were already present.

```
sudo apt install -y cmake glslc libvulkan-dev spirv-headers
```

**Verify.** `command -v cmake glslc` returns both.

**Rollback.** `sudo apt remove --purge cmake glslc libvulkan-dev spirv-headers && sudo apt autoremove`
Harmless to keep; these are ordinary build tools.

---

## 5. Distro ROCm 7.1 runtime (done, 2026-08-22)

**Why.** To test whether Ubuntu 26.04's own ROCm packaging supports gfx1151.
It does — `rocminfo` enumerates `gfx1151`, and rocBLAS ships
`TensileLibrary_*_fallback_gfx1151.hsaco`. 105 packages.

```
sudo apt install -y rocm-dev hipcc rocm-smi libamdhip64-dev libhipblas-dev
```

**Verify.** `rocminfo | grep gfx1151` prints the target.

**What it does NOT give you.** A working HIP *compiler*. Ubuntu's clang-21 has no
ROCm device-math implementation, so compiling HIP source fails with 308 errors —
unresolved `fabsf`, `fmaxf`, `powf`, `max`, `min`. The runtime works; the
toolchain does not.

**Rollback.**
```
sudo apt remove --purge rocm-dev hipcc rocm-smi libamdhip64-dev libhipblas-dev && sudo apt autoremove
```
Safe to keep either way — it is a working runtime and touches nothing else.

---

## 6. AMD ROCm apt repository — ADDED, THEN NOT USED (2026-08-22)

**Why it was added.** To get `rocm-llvm` / `amdclang++`, the compiler the distro
packages lack.

```
wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/rocm.gpg
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2.2 noble main' | sudo tee /etc/apt/sources.list.d/rocm.list
sudo apt update
sudo apt install -y rocm-hip-sdk rocwmma-dev        # <-- FAILED, installed nothing
```

**The install failed and nothing from AMD's repo is on the system.** Ubuntu
numbers `rocm-cmake` 7.1.1 while AMD numbers it 0.14.0, so apt prefers the
distro's and AMD's exact-version dependencies cannot resolve — 24 packages
unsatisfied at once.

**A pin was proposed and NOT run.** Priority 1001 to force downgrades across the
overlapping set. Nathan stopped it, correctly: it would have downgraded ~24
system packages to satisfy a build requirement, and it was unnecessary — the
build belongs in a container where AMD's repo is a first-class target.

**Rollback — run this if the container path works:**
```
sudo rm -f /etc/apt/sources.list.d/rocm.list /usr/share/keyrings/rocm.gpg
sudo apt update
```
Nothing else to undo; no AMD package was installed. Check with
`apt list --installed 2>/dev/null | grep 70202` — empty means clean.

**Also never run:** the libxml2 and libicu74 shims that copy noble `.so` files
into `/opt/rocm-7.2.2/lib`. They were quoted from a community setup guide but
never executed, and `/opt/rocm-7.2.2` does not exist on this machine.
