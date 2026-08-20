# GTT ceiling change — exact commands, verification, rollback

Machine: HP ZBook Ultra G1a 14, BIOS X89 Ver. 01.05.07 (05/05/2026),
kernel 7.0.0-29-generic, Ubuntu 26.04, GRUB.

State before the change, measured 2026-08-20:

    /sys/class/drm/card1/device/mem_info_vram_total   536870912     (512 MiB)
    /sys/class/drm/card1/device/mem_info_gtt_total  65937801216     (61.41 GiB)
    /sys/module/ttm/parameters/pages_limit             16098096     (61.41 GiB)
    MemTotal                                                        122.82 GiB
    /proc/cmdline   BOOT_IMAGE=/boot/vmlinuz-7.0.0-29-generic
                    root=UUID=6c8b1d1b-b37c-454a-8719-f4e0fe9019ff ro quiet splash
                    crashkernel=2G-4G:320M,4G-32G:512M,32G-64G:1024M,64G-128G:2048M,128G-:4096M
    /etc/default/grub line 10
                    GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
    id -nG          nathan adm cdrom sudo dip plugdev users lpadmin lxd
                    (in neither render nor video)

## BIOS

**Do not change it.** The UMA carve-out is already at the 512 MiB minimum, which
is what Linux wants: GTT is a ceiling on borrowing, not a reservation, so a
large carve-out only locks memory away from the OS and gains the GPU nothing.

Check, rather than trust:

    cat /sys/class/drm/card1/device/mem_info_vram_total    # want 536870912

Only if that grows: F10 at the HP splash -> Advanced -> Built-in Device Options
-> the graphics memory entry (HP labels it "Video Memory Size", "UMA Frame
Buffer Size", "Dedicated Graphics Memory" or "GPU Memory Allocation" depending
on firmware revision; X89 01.05.07's exact string is unconfirmed). Set the
smallest option, or Auto.

## The change

Target 110 GiB. `amdgpu.gttsize` is in MiB (confirmed from `modinfo -p amdgpu`:
"Size of the GTT userspace domain in megabytes"); `ttm.pages_limit` is in 4 KiB
pages. The two must agree or the lower one wins silently.

    110 * 1024                  = 112640     amdgpu.gttsize
    110 * 1073741824 / 4096     = 28835840   ttm.pages_limit

Commands, in order:

    sudo cp /etc/default/grub /etc/default/grub.bak
    sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"$/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.gttsize=112640 ttm.pages_limit=28835840"/' /etc/default/grub
    sudo usermod -aG render,video nathan
    sudo update-grub

`usermod` rides this reboot because `render` membership blocks three separate
things — the ROCm leg, the ComfyUI container, and the SkinTokens rig service —
and needs a re-login regardless.

### Verify BEFORE rebooting

Do not reboot on the strength of `sed` having exited zero.

    grep -n GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
    # expect: quiet splash amdgpu.gttsize=112640 ttm.pages_limit=28835840

    sudo grep -c "amdgpu.gttsize=112640" /boot/grub/grub.cfg
    # expect: a count >= 1. Zero means update-grub did not regenerate; fix
    # before rebooting, not after.

Then:

    sudo reboot

### Verify AFTER rebooting

    cat /sys/class/drm/card1/device/mem_info_gtt_total   # expect ~118111600640
    cat /sys/module/ttm/parameters/pages_limit           # expect 28835840
    cat /proc/cmdline                                    # both args present
    id -nG | tr ' ' '\n' | grep -E 'render|video'        # expect both
    ~/.local/opt/llama.cpp-vulkan/llama-b10502/llama-bench --list-devices
    # RADV reported 63395 MiB before; expect roughly 110 GiB now

## ROLLBACK

### If the machine boots but something is wrong

    sudo cp /etc/default/grub.bak /etc/default/grub
    sudo update-grub
    sudo reboot

Group membership, if it needs undoing:

    sudo gpasswd -d nathan render
    sudo gpasswd -d nathan video

### If the machine does NOT boot

The boot arguments are not persisted in firmware; GRUB applies them per boot and
they can be edited at the menu without a live USB.

1. Power on and hold **Shift**, or tap **Esc**, to force the GRUB menu.
   `GRUB_TIMEOUT=0` and `GRUB_TIMEOUT_STYLE=hidden` here, so the menu will not
   appear on its own — hold the key from power-on.
2. Highlight the Ubuntu entry and press **e** to edit it.
3. Find the line starting `linux /boot/vmlinuz-...` and delete
   `amdgpu.gttsize=112640 ttm.pages_limit=28835840` from the end of it.
4. **Ctrl-X** (or F10) to boot once with the edit. This changes nothing on disk.
5. Once up, restore permanently:

       sudo cp /etc/default/grub.bak /etc/default/grub
       sudo update-grub

If GRUB itself will not come up, the previous kernel under **Advanced options
for Ubuntu** boots with the same arguments, so it is not an escape — edit the
command line as above instead.

### Why a bad value cannot brick the firmware

`amdgpu.gttsize` and `ttm.pages_limit` are module parameters read at driver
init. Nothing is written to NVRAM or the BIOS. The worst realistic outcome is a
kernel that boots to a black screen or OOMs early, and step 3 above removes the
cause without touching disk. The BIOS is not being modified at all in this
procedure.

## Deliberately NOT included

`amd_iommu=off`, which the Zypher Systems guide recommends for latency. The
Gentoo wiki page for this exact laptop notes that suspend and the IOMMU interact
here — Pluton must be enabled in UEFI to suspend with the IOMMU on. Two
variables in one reboot means an unexplained suspend regression. Land GTT
first, confirm it, then try that separately if wanted.
