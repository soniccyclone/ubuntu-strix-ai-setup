#!/usr/bin/env bash
# Bring a fresh Ubuntu 26.04 Strix Halo box to a working Kairic Edge contract.
#
# Idempotent and resumable: every step checks before doing, so re-running after
# an interrupted 30 GiB download costs nothing. Nothing here uses sudo. The two
# steps that genuinely need root are detected and printed for you to run, not
# attempted -- see docs/privileged-steps.md.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Machine-local paths come from .env and nowhere else. Deliberately no
# environment-variable override: sourcing assigns unconditionally, so
# `MODELS=/x setup-kairic.sh` would be silently overridden by the file it
# reads. One mechanism, no precedence to reason about.
"$REPO/scripts/env-init.sh" "$REPO/.env"
set -a; . "$REPO/.env"; set +a
: "${MODELS:?MODELS missing from .env}"
: "${OPT:?OPT missing from .env}"
LLAMA_SWAP_VER="${LLAMA_SWAP_VER:-v250}"
IMAGE="localhost/kairic:v1.1"

ok(){    printf '  [+] %s\n' "$*"; }
warn(){  printf '  [!] %s\n' "$*"; }
die(){   printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }
step(){  printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- prerequisites
step "Checking prerequisites"

for c in podman git curl sha256sum systemctl; do
  command -v "$c" >/dev/null || die "$c not installed. sudo apt install -y podman git curl systemd"
done
ok "podman $(podman --version | awk '{print $3}'), git $(git --version | awk '{print $3}')"

# GTT ceiling. The amdgpu driver defaults GTT to half of RAM, which is not
# enough to hold 27 GiB of weights plus a 262144 KV cache plus the prompt cache.
# This is a kernel command line change and needs a reboot; it cannot be scripted
# from userspace.
GTT_FILE=$(ls /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1)
[ -n "$GTT_FILE" ] || die "No amdgpu GTT node found. Is this an AMD APU with the amdgpu driver loaded?"
GTT=$(cat "$GTT_FILE")
GTT_GIB=$(( GTT / 1073741824 ))
RAM_GIB=$(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo)
if [ "$GTT_GIB" -lt 90 ]; then
  cat <<EOF

[BLOCKED] GTT is ${GTT_GIB} GiB of ${RAM_GIB} GiB RAM. The 27B needs ~48 GiB of
GTT on its own, and this setup runs a second model beside it.

Run these, then REBOOT, then re-run this script:

  sudo cp /etc/default/grub /etc/default/grub.bak
  sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\$/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.gttsize=112640 ttm.pages_limit=28835840"/' /etc/default/grub
  sudo update-grub

gttsize is MiB, ttm.pages_limit is 4 KiB pages, and they must agree. The values
above are sized for a 128 GB machine; scale both if yours differs.
Rollback and recovery: docs/privileged-steps.md
EOF
  exit 1
fi
ok "GTT ${GTT_GIB} GiB of ${RAM_GIB} GiB RAM"

# Render node access. Rootless podman passes /dev/kfd through with
# --group-add keep-groups, but the invoking user must actually be in the group.
if ! id -nG | tr ' ' '\n' | grep -qx render; then
  cat <<EOF

[BLOCKED] Not in the 'render' group, so /dev/kfd is unreachable.

  sudo usermod -aG render,video \$USER

Then log out and back in (or 'newgrp render') and re-run.
EOF
  exit 1
fi
ok "render group present"

# ------------------------------------------------------------------ llama-swap
step "llama-swap"
if [ -x "$OPT/llama-swap/llama-swap" ]; then
  ok "already installed: $("$OPT/llama-swap/llama-swap" --version 2>&1 | head -1)"
else
  mkdir -p "$OPT/llama-swap"
  URL="https://github.com/mostlygeek/llama-swap/releases/download/${LLAMA_SWAP_VER}/llama-swap_${LLAMA_SWAP_VER#v}_linux_amd64.tar.gz"
  ok "downloading $LLAMA_SWAP_VER"
  curl -fsSL "$URL" | tar -xz -C "$OPT/llama-swap" \
    || die "llama-swap download failed. Check the asset name at https://github.com/mostlygeek/llama-swap/releases"
  chmod +x "$OPT/llama-swap/llama-swap"
  ok "installed $("$OPT/llama-swap/llama-swap" --version 2>&1 | head -1)"
fi

# --------------------------------------------------------------- engine image
step "Kairic engine image"
if podman image exists "$IMAGE" 2>/dev/null; then
  ok "$IMAGE already built"
else
  ok "building (ROCm 7.2.2 + patched Composable Kernel; 15-30 min, ~10 GiB)"
  podman build -t "$IMAGE" -f "$REPO/harness/Containerfile.kairic" "$REPO/harness" \
    || die "image build failed"
  ok "built $IMAGE"
fi

# -------------------------------------------------------------------- weights
step "Model artifacts"
mkdir -p "$MODELS/qwen3.8-kairic" "$MODELS/qwen3.8-4b"

fetch(){ # url dest sha256
  local url="$1" dest="$2" want="$3" name; name=$(basename "$dest")
  if [ -f "$dest" ]; then
    printf '      verifying %s ... ' "$name"
    if [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$want" ]; then echo "ok"; return 0; fi
    echo "MISMATCH, refetching"
  fi
  ok "downloading $name"
  curl -fL --retry 3 -C - "$url" -o "$dest" || die "download failed: $name"
  [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$want" ] \
    || die "checksum mismatch after download: $name"
  ok "$name verified"
}

K="https://huggingface.co/jcbtc/Qwen3.8-27B-IU4-Kairic-Edge/resolve/main"
fetch "$K/Qwen3.8-27B-IU4-Kairic-Edge.gguf"      "$MODELS/qwen3.8-kairic/Qwen3.8-27B-IU4-Kairic-Edge.gguf"      360caf7381907c3eca7ac0afd1228efc016af747f3f38637fb1c7f94daabac2a
fetch "$K/Qwen3.8-27B-Kairic-IU4-FFN.pfs"        "$MODELS/qwen3.8-kairic/Qwen3.8-27B-Kairic-IU4-FFN.pfs"        adcbb90a7b429a30a2a39043366d68320d72e8b4816a0f498e882b2f80a2ba2b
fetch "$K/Qwen3.8-27B-Kairic-IU4-GDN.pfs"        "$MODELS/qwen3.8-kairic/Qwen3.8-27B-Kairic-IU4-GDN.pfs"        82f931316f1c895da104915dec4697163808d06f0e6b2dc027cee7aa3afc0f0e
fetch "$K/Qwen3.8-27B-Kairic-IU4-GDN-Output.pfs" "$MODELS/qwen3.8-kairic/Qwen3.8-27B-Kairic-IU4-GDN-Output.pfs" 3b07e7b176559e4402924ba0c368532fa6f02118a33c71e70974c809bf6208a3

# Compaction model: abliterated Qwen3.8-4B-Distill, same qwen35 hybrid family as
# the 27B, so its 262144 window is cheap. Abliterated so the whole contract is
# uncensored; Q8_0 because repl/measure-quant showed Q4 drops rejected
# alternatives from summaries.
C="https://huggingface.co/mradermacher/Qwen3.5-4B-EmperoAI-Qwen3.8-Distill-Heretic-Abliterated-GGUF/resolve/main"
SRC="Qwen3.5-4B-EmperoAI-Qwen3.8-Distill-Heretic-Abliterated.Q8_0.gguf"
fetch "$C/$SRC" "$MODELS/qwen3.8-4b/Qwen3.8-4B-Distill-abliterated-Q8_0.gguf" \
  987703a1aca82f0641f8fbcfbe7d6a8e483f713d4a793553ccac55cf9da2ba0c
ok "compaction model present"

# ---------------------------------------------------------------- wiring
step "Service and client wiring"
mkdir -p ~/.config/systemd/user ~/.config/opencode

# The tracked configs in config/ name macros they do not define, so they cannot
# load alone -- llama-swap fails by name rather than serving the wrong weights.
# This writes the machine half.
REPO="$REPO" "$REPO/scripts/env-overlay.sh" "$REPO/.env" "$HOME/.config/llama-swap"
sed "s|%h/code-stuff/ubuntu-strix-ai-setup|$REPO|g" \
  "$REPO/systemd/llama-swap-kairic.service" > ~/.config/systemd/user/llama-swap-kairic.service
systemctl --user daemon-reload
ok "systemd unit installed"

if [ -e ~/.config/opencode/opencode.jsonc ] && [ ! -L ~/.config/opencode/opencode.jsonc ]; then
  cp ~/.config/opencode/opencode.jsonc ~/.config/opencode/opencode.jsonc.bak
  warn "existing opencode.jsonc backed up to opencode.jsonc.bak"
fi
ln -sfn "$REPO/config/opencode-kairic.jsonc" ~/.config/opencode/opencode.jsonc
ok "opencode config linked"

command -v opencode >/dev/null && ok "opencode $(opencode --version 2>&1|head -1)" \
  || warn "opencode not installed. npm i -g opencode-ai  (no sudo needed under nvm)"

cat <<EOF

[DONE] Start it with:

    make kairic-up

Then run 'opencode'. The contract answers on http://127.0.0.1:8080 with roles
'code' and 'compact'. First request loads the 27B and takes 60-90 s.

    make kairic-down     stop, and prove the memory came back
    make status          what is running and what it costs
EOF
