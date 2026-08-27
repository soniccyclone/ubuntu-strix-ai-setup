#!/usr/bin/env bash
# Prove the overlay's macro value reaches the launched process, rather than
# merely passing config validation.
#
# Falsifiable: the launched command writes its own argv to a file. If that file
# contains the literal "${m}" or is absent, the value did not propagate.
set -u
BIN="${LLAMA_SWAP:-$HOME/.local/opt/llama-swap/llama-swap}"
D=$(mktemp -d); trap 'rm -rf "$D"; kill ${P:-0} 2>/dev/null' EXIT
OUT="$D/argv.txt"

mkdir -p "$D/conf"
printf 'macros:\n  m: /srv/overlay/models\n' > "$D/conf/00-local.yaml"
cat > "$D/conf/10-models.yaml" <<YAML
models:
  probe:
    cmd: /usr/bin/tee $OUT
    cmdStop: /bin/true
    proxy: "http://127.0.0.1:\${PORT}"
YAML
# tee needs the value as an argument, so pass it explicitly:
cat > "$D/conf/10-models.yaml" <<YAML
models:
  probe:
    cmd: /bin/sh -c 'echo ARGV=\$0 >> $OUT; sleep 20' \${m}/weights.gguf-\${PORT}
    proxy: "http://127.0.0.1:\${PORT}"
YAML

"$BIN" -config-dir "$D/conf" -listen 127.0.0.1:18096 >"$D/log" 2>&1 & P=$!
for _ in $(seq 20); do curl -sf -m 1 http://127.0.0.1:18096/v1/models >/dev/null 2>&1 && break; sleep 0.25; done
curl -s -m 6 -H 'Content-Type: application/json' \
  -d '{"model":"probe","messages":[{"role":"user","content":"x"}],"max_tokens":1}' \
  http://127.0.0.1:18096/v1/chat/completions >/dev/null 2>&1
sleep 1; kill $P 2>/dev/null; wait $P 2>/dev/null

echo "--- what the launched process actually received ---"
cat "$OUT" 2>/dev/null || echo "(file absent)"
echo
echo "--- VERDICT ---"
if grep -q '/srv/overlay/models/weights.gguf' "$OUT" 2>/dev/null; then
  echo "OVERLAY VALUE PROPAGATES: YES"
elif grep -q '\${m}' "$OUT" 2>/dev/null; then
  echo "OVERLAY VALUE PROPAGATES: NO (literal)"
else
  echo "INCONCLUSIVE"; echo "--- llama-swap log ---"; cat "$D/log"
fi
