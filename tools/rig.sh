#!/usr/bin/env bash
# Rig a static GLB via the SkinTokens service. Thin wrapper over the toolkit
# driver at layers/rig/src/rig.py, which is stdlib-only and does the GLB
# surgery: skeleton, weights, joint naming, clips.
set -euo pipefail
: "${T2M_RIG_DRIVER:?set T2M_RIG_DRIVER to the rig driver path}"
exec python3 "$T2M_RIG_DRIVER" --endpoint "${T2M_RIG:-http://127.0.0.1:8191}" "$@"
