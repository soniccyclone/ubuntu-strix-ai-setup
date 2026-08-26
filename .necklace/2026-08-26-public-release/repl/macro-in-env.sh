#!/usr/bin/env bash
# llama-swap.yaml puts an absolute path in a model's `env:` list
# (LD_LIBRARY_PATH), not only in `cmd`. Does macro substitution reach there?
#
# Falsifiable: the launched process prints its own LD_LIBRARY_PATH. If it shows
# the literal "${opt}", macros do NOT expand in env: and that path cannot be
# de-personalised the same way.
set -u
BIN=/home/nathan/.local/opt/llama-swap/llama-swap
D=$(mktemp -d); trap 'rm -rf "$D"; kill ${P:-0} 2>/dev/null' EXIT
OUT="$D/env.txt"

mkdir -p "$D/conf"
printf 'macros:\n  opt: /srv/overlay/opt\n' > "$D/conf/00-local.yaml"
cat > "$D/conf/10-models.yaml" <<YAML
models:
  probe:
    cmd: /bin/sh -c 'echo "SEEN=\$LD_LIBRARY_PATH" >> $OUT; sleep 20' x-\${PORT}
    env:
      - "LD_LIBRARY_PATH=\${opt}/llama.cpp/lib"
    proxy: "http://127.0.0.1:\${PORT}"
YAML

"$BIN" -config-dir "$D/conf" -listen 127.0.0.1:18095 >"$D/log" 2>&1 & P=$!
for _ in $(seq 20); do curl -sf -m 1 http://127.0.0.1:18095/v1/models >/dev/null 2>&1 && break; sleep 0.25; done
curl -s -m 6 -H 'Content-Type: application/json' \
  -d '{"model":"probe","messages":[{"role":"user","content":"x"}],"max_tokens":1}' \
  http://127.0.0.1:18095/v1/chat/completions >/dev/null 2>&1
sleep 1; kill $P 2>/dev/null; wait $P 2>/dev/null

echo "--- LD_LIBRARY_PATH as the process saw it ---"
cat "$OUT" 2>/dev/null || { echo "(nothing captured)"; cat "$D/log"; }
echo
echo "--- VERDICT ---"
if grep -q 'SEEN=/srv/overlay/opt/llama.cpp/lib' "$OUT" 2>/dev/null; then
  echo "MACROS EXPAND IN env:  YES"
elif grep -q '\${opt}' "$OUT" 2>/dev/null; then
  echo "MACROS EXPAND IN env:  NO (literal)"
else
  echo "INCONCLUSIVE"
fi
