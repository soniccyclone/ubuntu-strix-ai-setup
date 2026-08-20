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

@test "opencode reaches the contract and completes one tool call" {
  vol="oc-$$"
  podman volume create --label suite-test "$vol" >/dev/null

  # opencode will not treat a bare directory as a project root; without a git
  # repo it resolves paths against / and its own permission layer refuses the
  # read. Seed a real repo, which is what a project actually looks like.
  podman run --rm --network=suite-net -v "${vol}:/work" -w /work localhost/suite-opencode \
    sh -c 'git init -q && git config user.email t@t && git config user.name t &&
           echo "the secret word is XYLOPHONE" > notes.txt &&
           git add -A && git commit -qm init' >/dev/null

  run timeout 900 podman run --rm --network=suite-net -v "${vol}:/work" -w /work \
      localhost/suite-opencode \
      opencode run --model contract/fast \
      "Use the read tool on the relative path notes.txt (do not use an absolute path) and tell me the secret word."

  podman volume rm -f "$vol" >/dev/null
  [ "$status" -eq 0 ]
  # The prompt names the relative path explicitly, and it has to. With the
  # obvious wording ("Read notes.txt and tell me the secret word") this model
  # emits an ABSOLUTE path -- /notes.txt -- roughly half the time, which
  # opencode's permission layer correctly refuses as outside the project.
  # Measured: 3 of 6 with the vague prompt, 6 of 6 with this one. That is a
  # prompt-sensitivity characteristic of the model, not a defect in the
  # plumbing, and this test exists to prove the plumbing.
  #
  # XYLOPHONE exists only inside notes.txt and cannot be guessed, so its
  # presence proves a tool call read the file. Deliberately NOT asserting on
  # opencode's "Read notes.txt" line: that is a rendering detail and the model
  # is sampled, so which tools it narrates varies between runs.
  [[ "$output" == *"XYLOPHONE"* ]]
}
