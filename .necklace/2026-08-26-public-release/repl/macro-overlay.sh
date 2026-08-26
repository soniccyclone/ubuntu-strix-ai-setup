#!/usr/bin/env bash
# Can machine-local paths live in a SEPARATE file that llama-swap merges,
# leaving the tracked config untouched?
#
# Falsifiable: if llama-swap errors "unknown macro '${m}'" when the macro is
# defined in a sibling file, macros do NOT merge across -config-dir and the
# overlay design is dead. If it loads and serves /v1/models, it works.
set -u
BIN=/home/nathan/.local/opt/llama-swap/llama-swap
D=$(mktemp -d); trap 'rm -rf "$D"; kill ${P:-0} 2>/dev/null' EXIT

mkdir -p "$D/conf"
cat > "$D/conf/00-paths.yaml" <<'YAML'
macros:
  m: /srv/machine-local-models
YAML
cat > "$D/conf/10-models.yaml" <<'YAML'
models:
  probe:
    cmd: /bin/echo ${m}/weights.gguf --port ${PORT}
    proxy: "http://127.0.0.1:${PORT}"
YAML

run(){ # label, args...
  local label="$1"; shift
  "$BIN" "$@" -listen 127.0.0.1:18098 >"$D/log" 2>&1 & P=$!
  sleep 2
  local out; out=$(curl -sf -m 2 http://127.0.0.1:18098/v1/models 2>/dev/null)
  kill $P 2>/dev/null; wait $P 2>/dev/null
  printf '%-34s ' "$label"
  if [ -n "$out" ]; then echo "LOADED  models=$(echo "$out" | grep -o '"id"' | wc -l)"
  else echo "FAILED  $(grep -o 'error=.*' "$D/log" | head -1)"; fi
}

echo "=== A: split across two files in -config-dir ==="
run "-config-dir only" -config-dir "$D/conf"

echo
echo "=== B: single combined file (control) ==="
cat "$D/conf/00-paths.yaml" "$D/conf/10-models.yaml" > "$D/combined.yaml"
run "-config combined" -config "$D/combined.yaml"

echo
echo "=== C: -config paths + -config-dir models ==="
mkdir -p "$D/only-models"; cp "$D/conf/10-models.yaml" "$D/only-models/"
run "-config paths -config-dir models" -config "$D/conf/00-paths.yaml" -config-dir "$D/only-models"
