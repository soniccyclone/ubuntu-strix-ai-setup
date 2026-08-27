#!/usr/bin/env bash
# llama-swap.yaml defines `server: <opt>/llama.cpp-vulkan/llama-b10502/llama-server`.
# If the overlay supplies `opt`, can the TRACKED file still define `server` in
# terms of it? That keeps the pinned build number where it belongs (with the
# config) instead of leaking into the machine-local overlay.
#
# Falsifiable: if llama-swap reports an unknown macro or passes the literal
# ${opt} through, macros do not compose and the whole path must come from the
# overlay.
set -u
BIN="${LLAMA_SWAP:-$HOME/.local/opt/llama-swap/llama-swap}"
D=$(mktemp -d); trap 'rm -rf "$D"; kill ${P:-0} 2>/dev/null' EXIT
OUT="$D/argv.txt"
mkdir -p "$D/conf"

printf 'macros:\n  opt: /srv/overlay-opt\n' > "$D/conf/00-local.yaml"
cat > "$D/conf/10-tracked.yaml" <<YAML
macros:
  server: \${opt}/llama.cpp-vulkan/llama-b10502/llama-server
models:
  probe:
    cmd: /bin/sh -c 'echo "ARGV=\$0" >> $OUT; sleep 20' \${server}-\${PORT}
    proxy: "http://127.0.0.1:\${PORT}"
YAML

"$BIN" -config-dir "$D/conf" -listen 127.0.0.1:18092 >"$D/log" 2>&1 & P=$!
for _ in $(seq 20); do curl -sf -m 1 http://127.0.0.1:18092/v1/models >/dev/null 2>&1 && break; sleep 0.25; done
curl -s -m 6 -H 'Content-Type: application/json' \
  -d '{"model":"probe","messages":[{"role":"user","content":"x"}],"max_tokens":1}' \
  http://127.0.0.1:18092/v1/chat/completions >/dev/null 2>&1
sleep 1; kill $P 2>/dev/null; wait $P 2>/dev/null

echo "--- process argv ---"; cat "$OUT" 2>/dev/null || echo "(nothing)"
echo "--- log ---"; grep -o 'error=.*' "$D/log" | head -1 || echo "(no error)"
echo "--- VERDICT ---"
if grep -q 'ARGV=/srv/overlay-opt/llama.cpp-vulkan/llama-b10502/llama-server' "$OUT" 2>/dev/null; then
  echo "MACROS COMPOSE: YES - tracked file may keep the pinned build number"
else
  echo "MACROS COMPOSE: NO - the whole path must come from the overlay"
fi
