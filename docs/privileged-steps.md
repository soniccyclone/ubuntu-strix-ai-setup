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
