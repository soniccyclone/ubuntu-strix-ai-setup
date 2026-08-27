#!/usr/bin/env bash
# The full chain Nathan's .env idea implies, end to end:
#   .env (gitignored, KEY=value)  ->  generated llama-swap macro overlay
#   ->  llama-swap loads tracked config + overlay  ->  process gets the path
#
# Also settles the precedence bug env-shared.sh exposed, by making .env the
# SOLE source rather than one of two that fight.
#
# Falsifiable at every stage: if the launched process does not receive the
# value written in .env, the chain is broken somewhere and the design fails.
set -u
BIN=/home/nathan/.local/opt/llama-swap/llama-swap
D=$(mktemp -d); trap 'rm -rf "$D"; kill ${P:-0} 2>/dev/null' EXIT
OUT="$D/argv.txt"

# --- the tracked config: references macros, defines none of them ------------
mkdir -p "$D/repo/config" "$D/conf"
cat > "$D/repo/config/contract.yaml" <<YAML
models:
  probe:
    cmd: /bin/sh -c 'echo "ARGV=\$0" >> $OUT; sleep 20' \${m}/weights.gguf-\${PORT}
    env:
      - "LD_LIBRARY_PATH=\${opt}/lib"
    proxy: "http://127.0.0.1:\${PORT}"
YAML

echo "=== does the tracked config load ALONE? (it must not) ==="
"$BIN" -config "$D/repo/config/contract.yaml" -listen 127.0.0.1:18094 >"$D/alone.log" 2>&1 &
P=$!; sleep 2; kill $P 2>/dev/null; wait $P 2>/dev/null
grep -o 'error=.*' "$D/alone.log" | head -1 || echo "  (loaded — that would be the silent-failure mode)"

# --- setup generates .env once, then never overwrites it -------------------
echo
echo "=== setup writes .env on first run, leaves it alone on the second ==="
gen_env(){
  if [ -f "$D/repo/.env" ]; then echo "  .env exists, left untouched"; return; fi
  cat > "$D/repo/.env" <<ENV
MODELS=$HOME/models
OPT=$HOME/.local/opt
ENV
  echo "  .env created with detected defaults"
}
gen_env
printf 'MODELS=/srv/user-edited-this\nOPT=/srv/user-opt\n' > "$D/repo/.env"   # user edits it
gen_env

# --- derive the macro overlay from .env ------------------------------------
echo
echo "=== derive the overlay from .env ==="
( set -a; . "$D/repo/.env"; set +a
  printf 'macros:\n  m: %s\n  opt: %s\n' "$MODELS" "$OPT" > "$D/conf/00-paths.yaml" )
cat "$D/conf/00-paths.yaml" | sed 's/^/  /'

# --- llama-swap loads tracked config + overlay -----------------------------
echo "=== launch with both, and read what the process actually got ==="
"$BIN" -config "$D/repo/config/contract.yaml" -config-dir "$D/conf" \
       -listen 127.0.0.1:18094 >"$D/log" 2>&1 & P=$!
for _ in $(seq 20); do curl -sf -m 1 http://127.0.0.1:18094/v1/models >/dev/null 2>&1 && break; sleep 0.25; done
curl -s -m 6 -H 'Content-Type: application/json' \
  -d '{"model":"probe","messages":[{"role":"user","content":"x"}],"max_tokens":1}' \
  http://127.0.0.1:18094/v1/chat/completions >/dev/null 2>&1
sleep 1; kill $P 2>/dev/null; wait $P 2>/dev/null
echo "  $(cat "$OUT" 2>/dev/null || echo '(nothing captured)')"

echo
echo "=== VERDICT ==="
if grep -q 'ARGV=/srv/user-edited-this/weights.gguf' "$OUT" 2>/dev/null; then
  echo "CHAIN INTACT: the value a user typed into .env reached the process"
else
  echo "CHAIN BROKEN"; cat "$D/log"
fi
