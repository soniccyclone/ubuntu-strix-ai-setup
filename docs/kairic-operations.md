# Operating the Kairic contract

Everything needed to run, tune and repair this stack without having watched it
being built. Setup is in [kairic-edge-opencode.md](kairic-edge-opencode.md); this is what
comes after. Repo overview: [../README.md](../README.md).

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
| `compact` | Qwen3.8-4B-Distill abliterated Q8_0 | compaction, titles, summaries |

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

Two model entries:

- `code` — your session, and the `general` and `explore` agents. Pinned to
  `id_slot: 0`, which is the only slot.
- `compact` — the 4B.

A third entry, `code-sub`, used to pin subagents to `id_slot: 1` so they could
not evict your session. It was removed with the second slot: the session log
recorded it serving two of 590 assistant messages. Subagents now share the one
slot and contend with the session.

`limit.context` is **262144**, the whole window, because there is one slot.
**If you change `-np`, change this to match**: `-c` is total across slots, so
two slots means 131072 here and eight means 32768, and a client declaring more
than its slot has means compaction fires after the slot has already overflowed.
`tests/p04-context.bats` and `tests/p05-recommendation.bats` fail if the two
drift apart, or if a model pins a slot the server does not have.

## Performance, and what to expect

Measured on this machine. HumanEval tasks 0-9, chat-adapted, hot cache, MTP
speculation on in every arm, matched settings. Method: `bench/results.md`.

| configuration | tok/s | draft accept |
| --- | ---: | ---: |
| Kairic IU4, greedy fast path | 56.72 | 76.2% |
| Kairic IU4, compatibility mode | 41.89 | 76.2% |
| ROCmFP4 + MTP, same engine family | 22.21 | 95.7% |
| stock Q4_K_M, upstream llama.cpp Vulkan | 12.23 | — |

The vendor publishes 48.78 for that same ten-task slice and 41.87 for
compatibility mode; ours reproduces the latter to within 0.05%.

**Those are benchmark-configuration numbers and you will not see them in
ordinary chat.** They were taken greedy, with reasoning off and a hot prompt
cache. Two things move the figure a long way:

*Draft acceptance tracks how predictable the output is.* MTP speculation only
pays when drafts are accepted. Code accepts ~76% and runs at 41-57 tok/s.
Discursive prose accepts 46-47% and runs at 16-21. Same model, same settings —
the workload is doing it. A single cold prose question landing near 17 tok/s is
normal, not a fault.

*Cache warmth.* Cold on the same ten tasks was 28.41 against 41.89 hot. Agent
sessions reuse thousands of tokens of prefix per turn, so real use trends toward
the hot number as a session goes on.

Interactive sampling costs nothing measurable. The same coding prompt at temp 0
greedy gave 19.49 tok/s at 72.4% acceptance; at temp 1.0 with thinking enabled,
20.04 tok/s at 73.9%. Thinking does add tokens before the answer, so
time-to-first-token rises even though throughput does not fall — that is what
`KAIRIC_REASONING_BUDGET` is for.

Notably, the gain here is not acceptance. ROCmFP4 accepts 95.7% of its drafts
and is still 2.5x slower. Kairic accepts fewer and wins on how fast it verifies
them, which is the IU4 lane doing its job on 2-to-5-row verification batches.
The vendor does not claim M1 decode is native IU4, and the measurements agree.

**Checking your own install** without running a suite: send one coding prompt
twice and read the server's own timings. The second is the number that matters.

```
curl -s localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"code","messages":[{"role":"user","content":"Write a red-black tree insert in C with comments."}],"max_tokens":384}' \
  | python3 -c 'import json,sys; t=json.load(sys.stdin)["timings"]; \
print("%.2f tok/s, draft accept %.1f%%" % (t["predicted_per_second"], 100.0*t.get("draft_n_accepted",0)/max(t.get("draft_n",1),1)))'
```

Roughly 20 tok/s on a cold single prompt and acceptance above 70% means the IU4
lane and MTP are both working. If acceptance is near zero, speculation is not
engaging and the `--spec-draft-*` flags did not land.

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
| `KAIRIC_REASONING_FORMAT` | deepseek | `none` leaves raw tags in content; never set it |
| `KAIRIC_REASONING_BUDGET` | -1 | cap thinking tokens; -1 unrestricted |
| `KAIRIC_SLOTS` | 1 | more slots divide context further; move `limit.context` with it |
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

## Empty thinking blocks above a reply

**Symptom.** opencode renders an empty grey thinking block, then the real answer.
The stored message content literally begins `<think>\n\n</think>\n\n`.

**Cause.** Qwen3's chat template emits that marker for non-thinking mode. It is
the *reasoning format*, not the reasoning switch, that decides whether anything
parses it: with `--reasoning-format none` the marker is never consumed and lands
in `message.content`.

`--reasoning off` is unrelated and perfectly fine — the compaction worker should
not think. The two are separate knobs and only the format matters here.

**Where it hid.** The 27B was fixed for this; the 4B compaction worker beside it
kept `--reasoning-format none`, so the marker only appeared when compaction,
title or summary ran. That is why it looked random rather than constant.

**Check it.** Ask the compaction model directly:

```
curl -s -H 'Content-Type: application/json' \
  -d '{"model":"compact","messages":[{"role":"user","content":"say ok"}],"max_tokens":40}' \
  http://127.0.0.1:8080/v1/chat/completions | jq -r '.choices[0].message.content'
```

Any `<think>` in that output means a model is being served with
`--reasoning-format none`. `tests/p08-reasoning.bats` fails if one is.
