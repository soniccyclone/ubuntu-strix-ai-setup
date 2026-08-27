#!/usr/bin/env bash
# macro-in-macro.sh showed a tracked file may define `server` in terms of an
# overlay's `opt` -- but both files were in ONE -config-dir. The real unit uses
# -config for the tracked file and -config-dir for the overlay, and there it
# fails:  error="unknown macro '${opt}' found in fast.cmd"
#
# Which arrangement is at fault: composition across the two FLAGS, or
# composition at all? Falsifiable per row below.
set -u
BIN="${LLAMA_SWAP:-$HOME/.local/opt/llama-swap/llama-swap}"
D=$(mktemp -d); trap 'rm -rf "$D"; kill ${P:-0} 2>/dev/null' EXIT

mk(){ # dir
  mkdir -p "$1"
  printf 'macros:\n  opt: /srv/O\n' > "$1/00-local.yaml"
}
tracked_composed(){ cat > "$1" <<'YAML'
macros:
  server: ${opt}/build/llama-server
models:
  probe:
    cmd: ${server} --port ${PORT}
    proxy: "http://127.0.0.1:${PORT}"
YAML
}
tracked_inlined(){ cat > "$1" <<'YAML'
models:
  probe:
    cmd: ${opt}/build/llama-server --port ${PORT}
    proxy: "http://127.0.0.1:${PORT}"
YAML
}

try(){ # label, args...
  local label="$1"; shift
  "$BIN" "$@" -listen 127.0.0.1:18090 >"$D/log" 2>&1 & P=$!
  sleep 1.5
  local out; out=$(curl -sf -m 2 http://127.0.0.1:18090/v1/models 2>/dev/null)
  kill $P 2>/dev/null; wait $P 2>/dev/null
  printf '%-52s ' "$label"
  [ -n "$out" ] && echo "LOADS" || echo "FAILS  $(grep -o "unknown macro '[^']*'" "$D/log" | head -1)"
}

rm -rf "$D"/*; mk "$D/d1"; tracked_composed "$D/d1/10-tracked.yaml"
try "composed, both in one -config-dir" -config-dir "$D/d1"

rm -rf "$D"/*; mk "$D/d2"; tracked_composed "$D/tracked.yaml"
try "composed, -config tracked + -config-dir overlay" -config "$D/tracked.yaml" -config-dir "$D/d2"

rm -rf "$D"/*; mk "$D/d3"; tracked_inlined "$D/tracked.yaml"
try "inlined,  -config tracked + -config-dir overlay" -config "$D/tracked.yaml" -config-dir "$D/d3"

rm -rf "$D"/*; mkdir -p "$D/d4"; tracked_composed "$D/d4/10-tracked.yaml"
printf 'macros:\n  opt: /srv/O\n' > "$D/overlay.yaml"
try "composed, -config overlay + -config-dir tracked" -config "$D/overlay.yaml" -config-dir "$D/d4"
