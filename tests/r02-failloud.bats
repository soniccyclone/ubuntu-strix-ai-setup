#!/usr/bin/env bats
# CUJ-02 — a stranger runs a tracked config without its overlay and is told
# exactly what is missing.
#
# These run against the REAL config/ files, in the SAME flag arrangement the
# systemd units use. That matters: an earlier probe using a synthetic config in
# a different arrangement reported a composition as safe when it was not.
# See .necklace/2026-08-26-public-release/repl/macro-compose-order.sh.

SWAP="$HOME/.local/opt/llama-swap/llama-swap"
CONFIGS=(config/llama-swap.yaml config/llama-swap-kairic.yaml)

setup() { TMP=$(mktemp -d); export TMP; }
teardown() {
  [ -n "${SWAP_PID:-}" ] && kill "$SWAP_PID" 2>/dev/null || true
  rm -rf "$TMP"
}

overlay() {
  printf 'MODELS=/srv/t-models\nOPT=/srv/t-opt\n' > "$TMP/.env"
  REPO="$PWD" ./scripts/env-overlay.sh "$TMP/.env" "$TMP/overlay" >/dev/null
}

@test "the tracked contract refuses to load without the machine overlay" {
  [ -x "$SWAP" ] || skip "llama-swap not installed"
  for cfg in "${CONFIGS[@]}"; do
    "$SWAP" -config "$cfg" -listen 127.0.0.1:18089 >"$TMP/log" 2>&1 &
    SWAP_PID=$!
    sleep 1.5
    run curl -sf -m 1 http://127.0.0.1:18089/v1/models
    kill "$SWAP_PID" 2>/dev/null || true; wait "$SWAP_PID" 2>/dev/null || true; SWAP_PID=
    # No model list served: it refused rather than starting something.
    [ "$status" -ne 0 ]
    grep -q 'failed to load config' "$TMP/log"
  done
}

@test "the refusal names the missing value" {
  [ -x "$SWAP" ] || skip "llama-swap not installed"
  for cfg in "${CONFIGS[@]}"; do
    "$SWAP" -config "$cfg" -listen 127.0.0.1:18089 >"$TMP/log" 2>&1 &
    SWAP_PID=$!
    sleep 1.5
    kill "$SWAP_PID" 2>/dev/null || true; wait "$SWAP_PID" 2>/dev/null || true; SWAP_PID=
    # "invalid config" would be useless. It has to name the macro, so a
    # stranger knows which value they have not supplied.
    grep -q "unknown macro" "$TMP/log"
    grep -qE "unknown macro '\\\$\{(m|opt|repo)\}'" "$TMP/log"
  done
}

@test "the same config loads once the overlay is present" {
  [ -x "$SWAP" ] || skip "llama-swap not installed"
  overlay
  for cfg in "${CONFIGS[@]}"; do
    "$SWAP" -config "$cfg" -config-dir "$TMP/overlay" -listen 127.0.0.1:18089 >"$TMP/log" 2>&1 &
    SWAP_PID=$!
    for _ in $(seq 24); do
      curl -sf -m 1 http://127.0.0.1:18089/v1/models >/dev/null 2>&1 && break
      sleep 0.25
    done
    run curl -sf -m 2 http://127.0.0.1:18089/v1/models
    kill "$SWAP_PID" 2>/dev/null || true; wait "$SWAP_PID" 2>/dev/null || true; SWAP_PID=
    [ "$status" -eq 0 ]
    # Every role the contract promises must be listed, not merely some of them.
    case "$cfg" in
      *kairic*) expect="code compact" ;;
      *)        expect="fast fast-text deep" ;;
    esac
    for role in $expect; do
      echo "$output" | jq -e --arg r "$role" '.data[]|select(.id==$r)' >/dev/null
    done
  done
}
