#!/usr/bin/env bats
# CUJ-01 — a coding task at the terminal on a local model.
# Mechanical only: does the contract answer, does an agent reach it.
# Whether the model is any good is UAT and is not tested here.

CONTRACT="${CONTRACT:-http://127.0.0.1:8080}"

# No skip-if-unreachable guard on purpose: a contract that is not running is a
# failure, not a reason to report success.

@test "contract answers both API shapes on one port" {
  run curl -sf -m 600 "$CONTRACT/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{"model":"fast","max_tokens":800,
           "messages":[{"role":"user","content":"Reply with exactly: CONTRACT OK"}]}'
  [ "$status" -eq 0 ]
  openai_text=$(jq -r '.choices[0].message.content' <<<"$output")
  [[ "$openai_text" == *"CONTRACT OK"* ]]

  run curl -sf -m 600 "$CONTRACT/v1/messages" \
      -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"fast","max_tokens":800,
           "messages":[{"role":"user","content":"Reply with exactly: ANTHROPIC OK"}]}'
  [ "$status" -eq 0 ]
  # Qwen3.6 is a thinking model: content is [thinking, text], not [text].
  anthropic_text=$(jq -r '[.content[]|select(.type=="text")|.text]|join("")' <<<"$output")
  [[ "$anthropic_text" == *"ANTHROPIC OK"* ]]
}

@test "every advertised role is addressable" {
  run curl -sf -m 5 "$CONTRACT/v1/models"
  [ "$status" -eq 0 ]
  for role in fast fast-text deep; do
    jq -e --arg r "$role" '.data[]|select(.id==$r)' <<<"$output" >/dev/null
  done
}
