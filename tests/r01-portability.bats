#!/usr/bin/env bats
# CUJ-01 — a stranger clones onto a machine laid out differently and reaches a
# working contract.
#
# The machine-specific paths live in a gitignored .env that setup writes once.
# llama-swap cannot read KEY=value (it treats ${...} as its own macro namespace
# and hard-errors on undeclared names), so setup derives a macro overlay from
# .env. See .necklace/2026-08-26-public-release/repl/.

SWAP="$HOME/.local/opt/llama-swap/llama-swap"

setup() {
  TMP=$(mktemp -d)
  export TMP
}

teardown() {
  [ -n "${SWAP_PID:-}" ] && kill "$SWAP_PID" 2>/dev/null
  rm -rf "$TMP"
}

@test "setup writes .env once and never overwrites an edit" {
  run scripts/env-init.sh "$TMP/.env"
  [ "$status" -eq 0 ]
  [ -f "$TMP/.env" ]
  grep -q '^MODELS=' "$TMP/.env"

  # A stranger edits it. The whole point of a file over an environment variable
  # is that the edit survives the next run.
  sed -i 's|^MODELS=.*|MODELS=/srv/sentinel-edited|' "$TMP/.env"
  run scripts/env-init.sh "$TMP/.env"
  [ "$status" -eq 0 ]
  grep -q '^MODELS=/srv/sentinel-edited$' "$TMP/.env"
}

@test "a models path set only in .env reaches the launched process" {
  [ -x "$SWAP" ] || skip "llama-swap not installed"
  printf 'MODELS=/srv/only-in-env\nOPT=/srv/opt\nREPO=%s\n' "$PWD" > "$TMP/.env"
  run scripts/env-overlay.sh "$TMP/.env" "$TMP/overlay"
  [ "$status" -eq 0 ]
  grep -q '/srv/only-in-env' "$TMP/overlay/00-paths.yaml"

  # Validation alone would prove nothing: assert the value reaches a real
  # process's argv, which is what repl/env-to-overlay.sh established.
  cat > "$TMP/overlay/99-probe.yaml" <<YAML
models:
  probe:
    cmd: /bin/sh -c 'echo "ARGV=\$0" >> $TMP/argv.txt; sleep 20' \${m}/w.gguf-\${PORT}
    proxy: "http://127.0.0.1:\${PORT}"
YAML
  "$SWAP" -config-dir "$TMP/overlay" -listen 127.0.0.1:18093 >"$TMP/swap.log" 2>&1 &
  SWAP_PID=$!
  for _ in $(seq 20); do
    curl -sf -m 1 http://127.0.0.1:18093/v1/models >/dev/null 2>&1 && break
    sleep 0.25
  done
  # This request only has to make llama-swap LAUNCH the model. The probe sleeps
  # rather than answering, so curl times out by design -- the assertion is on
  # what the launched process received, not on a reply.
  curl -s -m 6 -H 'Content-Type: application/json' \
    -d '{"model":"probe","messages":[{"role":"user","content":"x"}],"max_tokens":1}' \
    http://127.0.0.1:18093/v1/chat/completions >/dev/null 2>&1 || true
  sleep 1
  grep -q 'ARGV=/srv/only-in-env/w.gguf' "$TMP/argv.txt"
}

@test "no tracked file contains a literal home directory" {
  # %h (systemd) and $HOME / ${HOME} (shell, make) are portable and permitted.
  # A literal /home/<user> is not.
  #
  # Prose under .necklace/ is exempt: it is the development record, and several
  # findings ARE the path that was measured. Rewriting those would falsify the
  # record. Runnable files there are NOT exempt, so a probe script that hardcodes
  # a path still fails this.
  run bash -c "git ls-files -z \
    | grep -zv '^\.necklace/.*\.md$' \
    | xargs -0 grep -lI -E '/home/[a-z_][a-z0-9_-]*' 2>/dev/null || true"
  [ -z "$output" ]
}

@test ".env is ignored by git" {
  printf 'MODELS=/srv/sentinel\n' > .env
  run git check-ignore .env
  [ "$status" -eq 0 ]
  run bash -c "git status --porcelain | grep -F '.env' || true"
  [ -z "$output" ]
  rm -f .env
}
