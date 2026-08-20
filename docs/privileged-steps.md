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

## 3. Close the contract port to the LAN (PENDING)

**Why.** llama-swap must bind `0.0.0.0`. This is not a preference — it was
measured. Rootless podman containers cannot reach a loopback-bound host service:

    host service bound 127.0.0.1  ->  container gets 000
    host service bound 0.0.0.0    ->  container gets 200
    host.containers.internal      =   169.254.1.2 (pasta), not the host loopback

`pasta:--map-host-loopback` does reach a loopback-bound service, but pasta cannot
be combined with a bridge network, and the agents need an `--internal` bridge to
have no route off the box. So the contract binds `0.0.0.0` and the LAN is closed
at the firewall instead.

This host is on `192.168.1.22` (ethernet) and `192.168.1.76` (wifi), and there is
a second machine on that LAN. Without this rule, every local model on this box is
served to it.

```
sudo ufw --force enable
sudo ufw allow in on lo
sudo ufw deny in on enxd0c1b5239c45 to any port 8080 proto tcp
sudo ufw deny in on wlp193s0        to any port 8080 proto tcp
```

**Verify.** `make test-isolation` — the test `the contract is not reachable from
the LAN` dials every globally-scoped address this host owns and requires each to
refuse, while the same request from inside a test container must still succeed.
It is red until this is applied.

**Rollback.**

```
sudo ufw delete deny in on enxd0c1b5239c45 to any port 8080 proto tcp
sudo ufw delete deny in on wlp193s0        to any port 8080 proto tcp
sudo ufw disable        # only if ufw was inactive before; it was
```

**Note.** `ufw` was `inactive` before this change. Enabling it applies ufw's
default policy to everything else on this machine, not just port 8080. That is a
broader change than the one line implies, and it is the reason this step is
written down rather than folded into a setup script.
