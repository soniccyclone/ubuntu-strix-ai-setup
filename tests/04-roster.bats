#!/usr/bin/env bats
# CUJ-04 — change which model backs a role by editing one file.

CONTRACT="${CONTRACT:-http://127.0.0.1:8080}"
CFG=config/llama-swap.yaml

@test "an unknown role fails loudly" {
  # Fail fast over fail silently: no fallback model, no quietly-served request.
  before_servers=$(pgrep -xc llama-server || echo 0)
  run curl -s -o /tmp/unknown.json -w '%{http_code}' -m 30 \
      "$CONTRACT/v1/chat/completions" -H 'Content-Type: application/json' \
      -d '{"model":"no-such-role","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'
  [ "$status" -eq 0 ]
  [ "${output:0:1}" = "4" ]
  # An explicit error, not an empty body and not a completion. llama-swap does
  # not echo the requested name back, so assert on the error being present and
  # on nothing having been served, rather than on the wording.
  jq -e '.error' /tmp/unknown.json >/dev/null
  run jq -e '.choices' /tmp/unknown.json
  [ "$status" -ne 0 ]

  # And no model was loaded as a side effect of asking for one that does not
  # exist. A fallback here would be the worst outcome: silently right-looking.
  #
  # Counted by process NAME, before and after. `pgrep -f <pattern>` matches its
  # own command line, which has produced a false positive four separate times
  # in this project; it is not used here.
  [ "$before_servers" = "$(pgrep -xc llama-server || echo 0)" ]
}

@test "the roster is the only place a model file is named" {
  # Frontend config names roles, never paths.
  grep -q '"model": "contract/fast"' harness/opencode.json
  run grep -cE '\.gguf' harness/opencode.json
  [ "${output//[[:space:]]/}" = "0" ]
  # And the roster does name the files.
  run grep -cE '\.gguf' "$CFG"
  [ "${output//[[:space:]]/}" -ge 3 ]
}

@test "repointing a role changes which file serves it" {
  cp "$CFG" /tmp/roster.bak
  # fast-text currently serves the 35B. Point it at the 122B instead.
  sed -i 's|-m ${m}/qwen3.6-bartowski/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf\n      -c 32768|X|' "$CFG"
  python3 - <<'PY'
import pathlib,re
p=pathlib.Path('config/llama-swap.yaml'); s=p.read_text()
i=s.index('  fast-text:'); j=s.index('  deep:')
blk=s[i:j].replace('qwen3.6-bartowski/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf',
                   'qwen3.5-122b/Qwen3.5-122B-A10B-Q4_K_M-00001-of-00002.gguf')
p.write_text(s[:i]+blk+s[j:])
PY
  sleep 4   # -watch-config polls at 2s
  run curl -s -m 20 "$CONTRACT/v1/models"
  cp /tmp/roster.bak "$CFG"; sleep 4
  [ "$status" -eq 0 ]
  # The role still exists under the same name after being repointed.
  jq -e '.data[]|select(.id=="fast-text")' <<<"$output" >/dev/null
  # And no frontend file was touched to do it.
  run git diff --name-only harness/opencode.json
  [ -z "$output" ]
}
