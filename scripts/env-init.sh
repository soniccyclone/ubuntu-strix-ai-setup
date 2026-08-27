#!/usr/bin/env bash
# Write the machine-local .env once, with detected defaults, and never again.
#
# This file is the ONLY place a path is configured. There is deliberately no
# environment-variable override beside it: sourcing a file assigns
# unconditionally, so `MODELS=/x ./setup.sh` would be silently overridden by
# the file it reads. Two mechanisms, and the quieter one wins. See
# .necklace/2026-08-26-public-release/repl/env-shared.sh.
set -euo pipefail

ENVFILE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env}"

if [ -f "$ENVFILE" ]; then
  echo "  [+] $ENVFILE exists, left untouched"
  exit 0
fi

mkdir -p "$(dirname "$ENVFILE")"
cat > "$ENVFILE" <<EOF
# Machine-local paths. Gitignored; edit freely, nothing regenerates this.
#
# MODELS  where GGUF weights and sidecars live. ~35 GiB for the Kairic
#         contract, ~90 GiB if you also run the 122B roster.
# OPT     user-level install prefix for llama-swap and llama.cpp builds.
#
# After editing, run 'make env' to regenerate the serving overlay.

MODELS=$HOME/models
OPT=$HOME/.local/opt
EOF
echo "  [+] wrote $ENVFILE with detected defaults"
