#!/usr/bin/env bash
# Two questions the overlay design depends on:
#   1. Does the overlay's macro VALUE actually reach the launched process?
#   2. If the tracked file also defines that macro, does the overlay win,
#      or is a duplicate a fatal error?
#
# Falsifiable: if the log shows /default/models rather than /srv/overlay, the
# overlay does not override and the tracked file cannot carry a default.
set -u
BIN=/home/nathan/.local/opt/llama-swap/llama-swap
D=$(mktemp -d); trap 'rm -rf "$D"; kill ${P:-0} 2>/dev/null' EXIT

probe(){ # label, dir
  local label="$1" dir="$2"
  "$BIN" -config-dir "$dir" -listen 127.0.0.1:18097 >"$D/log" 2>&1 & P=$!
  for _ in $(seq 20); do curl -sf -m 1 http://127.0.0.1:18097/v1/models >/dev/null 2>&1 && break; sleep 0.25; done
  curl -sf -m 5 -H 'Content-Type: application/json' \
    -d '{"model":"probe","messages":[{"role":"user","content":"x"}],"max_tokens":1}' \
    http://127.0.0.1:18097/v1/chat/completions >/dev/null 2>&1
  sleep 1; kill $P 2>/dev/null; wait $P 2>/dev/null
  echo "--- $label ---"
  if grep -q 'error=' "$D/log"; then grep -o 'error=.*' "$D/log" | head -1
  else grep -oE '/(srv/overlay|default)/models/weights.gguf' "$D/log" | head -1 || echo "(no resolved path in log)"; fi
  echo
}

# Case 1: macro defined ONLY in the overlay
mkdir -p "$D/c1"
printf 'macros:\n  m: /srv/overlay/models\n' > "$D/c1/00-local.yaml"
printf 'models:\n  probe:\n    cmd: /bin/echo ${m}/weights.gguf --port ${PORT}\n' > "$D/c1/10-models.yaml"
probe "overlay only" "$D/c1"

# Case 2: tracked file defines a default, overlay sorts LATER and redefines it
mkdir -p "$D/c2"
printf 'macros:\n  m: /default/models\n' > "$D/c2/10-tracked.yaml"
printf 'models:\n  probe:\n    cmd: /bin/echo ${m}/weights.gguf --port ${PORT}\n' >> "$D/c2/10-tracked.yaml"
printf 'macros:\n  m: /srv/overlay/models\n' > "$D/c2/90-local.yaml"
probe "tracked default + later overlay" "$D/c2"

# Case 3: overlay sorts EARLIER than the tracked default
mkdir -p "$D/c3"
printf 'macros:\n  m: /srv/overlay/models\n' > "$D/c3/00-local.yaml"
printf 'macros:\n  m: /default/models\n' > "$D/c3/10-tracked.yaml"
printf 'models:\n  probe:\n    cmd: /bin/echo ${m}/weights.gguf --port ${PORT}\n' >> "$D/c3/10-tracked.yaml"
probe "overlay first + tracked default" "$D/c3"
