# Operating the Kairic contract

Everything needed to run, tune and repair this stack without having watched it
being built. Setup is in [../README.md](../README.md); this is what comes after.

## What runs where

```
opencode  ->  llama-swap :8080  ->  podman: kairic-serve   (27B, slots 0 and 1)
                                 ->  podman: compact-serve (4B, compaction)
```

llama-swap owns model lifecycle and presents one port. Both models stay resident
together (`swap: false` in `config/llama-swap-kairic.yaml`) so compaction never
evicts the model you are talking to.

The engine inside both containers is `llama-server` from a llama.cpp source
snapshot. The API is plain OpenAI-compatible: `/v1/chat/completions`,
`/v1/models`, `/health`, plus llama-swap's `/upstream/<role>/props`.

## Two roles

| role | model | serves |
| --- | --- | --- |
| `code` | Qwen3.8-27B IU4 Kairic Edge | your actual work |
| `compact` | Qwen3.8-4B Q8_0 | compaction, titles, summaries |

They are separate models, not two views of one. Nothing is shared between them —
a KV cache entry is the projection *specific weights* produced, so the 27B's
cache is meaningless to the 4B and the shapes do not even match.

The 4B exists because compaction re-reads the transcript from scratch no matter
which model does it. opencode flattens the conversation into a single text blob
with its own prompt (`compaction.ts`), so the token sequence diverges from the
live session at position zero and the prompt cache cannot help. Given a
re-read is unavoidable, it should happen on the model that reads fastest:

    27B   19,625 tokens in 86.0 s    228 tok/s
    4B    19,625 tokens in 19.1 s   1025 tok/s   4.49x

That is what its ~14 GiB buys: roughly 15 minutes down to 3 on a large
compaction. Delete `agent.compaction.model` from the opencode config to give the
memory back and fall through to `code`; that fallback is documented behaviour,
not an accident.

## Client wiring

`config/opencode-kairic.jsonc`, symlinked to `~/.config/opencode/opencode.jsonc`.

**opencode reads that path and nothing else.** `OPENCODE_CONFIG` does not work
for the desktop app, which launches from the desktop and never sees your shell
environment. Note the extension is `.jsonc`.

**Restart opencode after any config change.** `opencode debug config` prints the
resolved configuration after merging and is the fastest way to confirm a change
took effect.

Three model entries, deliberately:

- `code` — your session. Pinned to `id_slot: 0`.
- `code-sub` — the same server model (`"id": "code"`) pinned to `id_slot: 1`,
  assigned to the `general` and `explore` agents. opencode's `general` agent
  runs work in parallel and inherits the main model unless told otherwise, so
  without this every subagent call evicts your session's KV and forces a full
  re-prefill. Confirm it is working in the server log:
  `slot launch_slot_: id 1` alongside `slot process_sing: id 0 | saving idle slot`.
- `compact` — the 4B.

`limit.context` is **131072, not 262144**, because context is divided across
slots and there are two. If you change `-np`, change this to match or compaction
will fire after the slot has already overflowed.

## Tuning levers

All are environment variables on the `code` role in
`config/llama-swap-kairic.yaml`; restart with `make kairic-down && make kairic-up`.

| variable | default | effect |
| --- | --- | --- |
| `KAIRIC_TEMP` | 1.0 | Qwen thinking-mode value |
| `KAIRIC_TOP_P` | 0.95 | " |
| `KAIRIC_TOP_K` | 20 | " |
| `KAIRIC_MIN_P` | 0.0 | " |
| `KAIRIC_PRESENCE_PENALTY` | 0.0 | raise only in non-thinking mode |
| `KAIRIC_REASONING` | on | `off` disables thinking entirely |
| `KAIRIC_REASONING_FORMAT` | deepseek | `none` leaves raw tags in content |
| `KAIRIC_REASONING_BUDGET` | -1 | cap thinking tokens; -1 unrestricted |
| `KAIRIC_SLOTS` | 2 | more slots divide context further |
| `CONTEXT` | 262144 | total across slots |
| `CACHE_RAM` | 16384 | prompt cache MiB |
| `KAIRIC_EDGE_COMPATIBILITY_MODE` | 1 | **do not set to 0**, see below |

**`reasoning_effort`** is a per-request parameter this model's chat template
understands: `xhigh` (its default), `medium`, `low`. Current guidance is xhigh
for agentic coding, low for high-volume endpoints. It is the main lever if turns
feel slow, since it directly controls how many thinking tokens are produced.

**To reproduce the published benchmark numbers**, set
`KAIRIC_REASONING=off KAIRIC_TEMP=0 KAIRIC_TOP_P=1.0 KAIRIC_TOP_K=0
KAIRIC_PRESENCE_PENALTY=0` and `KAIRIC_EDGE_COMPATIBILITY_MODE=0`. That is the
vendor's configuration, and it is what every figure in `bench/results.md` was
measured under. It cannot serve a tool call.

## Memory

    both models loaded    ~74 GiB used
    peak in use           ~91 GiB used
    after kairic-down     back to baseline

Weights and caches live in **GTT**, not process memory. `ps`, `top` and
`podman stats` reported 6 GB across both containers while 91 GiB was in use.

```
watch -n2 'awk "{printf \"%.1f GiB\n\", \$1/1073741824}" /sys/class/drm/card1/device/mem_info_gtt_used'
```

KV is allocated up front at `-c`, so context size costs the same whether you use
one token or all of them. What grows during use is the prompt cache (capped by
`CACHE_RAM`) and its checkpoints. Roughly 9 GiB of the observed growth is not
attributed to either; if you need a real bound, vary one flag at a time and watch
GTT.

`make kairic-up` refuses to start under 70 GiB free or with another contract
running. `make kairic-down` prints the memory that came back, so "stopped" is
demonstrated rather than asserted.

## Troubleshooting

**Tool calls return HTTP 400** with a message about "Exact-Q8 argmax accepts only
one unmodified greedy completion". The greedy argmax fast path is on. It is ~35%
faster and refuses tool calls, temperature above zero, grammar and logprobs —
everything an agent needs. Set `KAIRIC_EDGE_COMPATIBILITY_MODE=1`.

**The model repeats one command forever.** Greedy sampling with every penalty
disabled has nothing to break a repetition attractor. Check
`/upstream/code/props`; if `temperature` is 0 and `presence_penalty` is 0 with
`top_k` 0, the sampler flags did not land. Verify with
`podman top kairic-serve args` — reading the launcher script is not enough,
because a `#` comment inside a backslash-continuation silently truncates the
whole command.

**Empty `<think></think>` blocks in the transcript.** Two separate causes and
you may have both: `--reasoning off` generates no thoughts, and
`--reasoning-format none` leaves whatever tags appear unparsed inside
`message.content` instead of extracting them. Want `on` and `deepseek`.

**`response_format: json_schema` returns 400** `Failed to initialize samplers`.
A known fault in this engine branch, present in both modes. `json_object`, raw
GBNF grammar and the `tools:` path all work, so agents are unaffected. No fix;
retest if the engine is updated.

**opencode shows hosted models and no `contract` provider.** The config is not at
`~/.config/opencode/opencode.jsonc`. An env var will not do it for the desktop
app.

**"LSPs are disabled".** The `lsp` key is absent. Omitting it disables them;
`"lsp": true` enables the built-ins. opencode installs and manages the servers
itself — nothing to apt-install.

**The machine OOMs while every tool says memory is fine.** You are reading RSS.
See Memory above.

**The model will not load at all.** GTT ceiling. `cat
/sys/class/drm/card*/device/mem_info_gtt_total` should be ~118111600640, not
half your RAM. See [privileged-steps.md](privileged-steps.md).

**A container exits immediately with no log** (`podman run -d --rm` deletes the
evidence). Re-run it in the foreground without `-d`. Two known causes: the
`rocmfpx-hip` image's entrypoint is `llama-bench`, not `llama-server`, so server
flags print a usage block and exit; and `LLAMA_MTP_CPU_ARGMAX_FASTPATH=1` aborts
at startup unless both `--spec-draft-backend-sampling` and
`--spec-draft-p-min 0.0` are set.

**Setup blocks on the `render` group** right after `usermod`. Group membership
applies at login. Log out and back in, or `newgrp render` in that shell.

## Verifying a change actually took effect

Do not read the config and assume. Every one of these caught a real failure:

```
podman top kairic-serve args              # the argv the server really got
curl -s localhost:8080/upstream/code/props | python3 -m json.tool | head -40
opencode debug config                     # resolved opencode config after merge
opencode models                           # which models the client can see
podman logs kairic-serve | grep -i slot   # which slot served a request
```
