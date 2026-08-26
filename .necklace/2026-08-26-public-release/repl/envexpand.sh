#!/usr/bin/env bash
# Does llama-swap v250 expand environment variables in its YAML?
#
# Falsifiable: if the started process receives the literal string
# "${NECKLACE_PROBE}", llama-swap does NOT expand env vars and the hardcoded
# paths cannot be fixed with ${HOME}. If it receives the sentinel value,
# it does.
#
# cmd is exec'd directly (no shell), so the shell cannot expand it for us
# and confound the result.
set -u
BIN=/home/nathan/.local/opt/llama-swap/llama-swap
PORT=18099
D=$(mktemp -d)
trap 'rm -rf "$D"; kill "${SWAP_PID:-0}" 2>/dev/null' EXIT

export NECKLACE_PROBE=SENTINEL_EXPANDED

cat > "$D/probe.yaml" <<YAML
models:
  probe:
    cmd: /bin/echo NECKLACE_RESULT=\${NECKLACE_PROBE} PORT=\${PORT}
    proxy: "http://127.0.0.1:\${PORT}"
YAML

echo "--- config under test ---"; cat "$D/probe.yaml"; echo

"$BIN" -config "$D/probe.yaml" -listen "127.0.0.1:$PORT" >"$D/swap.log" 2>&1 &
SWAP_PID=$!

for _ in $(seq 40); do
  curl -sf -m 1 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break
  sleep 0.25
done

curl -sf -m 10 -H 'Content-Type: application/json' \
  -d '{"model":"probe","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
  "http://127.0.0.1:$PORT/v1/chat/completions" >/dev/null 2>&1

sleep 1
echo "--- llama-swap log ---"
cat "$D/swap.log"
echo
echo "--- VERDICT ---"
if grep -q 'NECKLACE_RESULT=SENTINEL_EXPANDED' "$D/swap.log"; then
  echo "ENV EXPANSION: YES"
elif grep -q 'NECKLACE_RESULT=\${NECKLACE_PROBE}' "$D/swap.log"; then
  echo "ENV EXPANSION: NO (literal passed through)"
else
  echo "INCONCLUSIVE - inspect log above"
fi
