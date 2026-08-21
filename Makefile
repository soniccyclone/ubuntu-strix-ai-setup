# Local Claude suite on Strix Halo.
#
# The serving contract runs on BARE METAL, where the GPU and the weights are.
# Everything else — every agent, every test — runs in a rootless podman
# container with no host filesystem mounted. See .necklace/*/cuj.md.

SHELL     := /usr/bin/env bash
CONTRACT  ?= http://127.0.0.1:8080
BATS      ?= bats
TESTS     ?= tests

.PHONY: help setup test test-isolation harness-up harness-down clean \
        media-up media-down asset viewer sprite rig llm-up llm-down status stop-all

help:                    ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  %-16s %s\n", $$1, $$2}'

setup:                   ## Install the user-level test tooling
	@command -v bats >/dev/null || npm i -g bats
	@command -v jq   >/dev/null || { echo "jq missing; apt install jq (needs root)" >&2; exit 1; }
	@command -v podman >/dev/null || { echo "podman missing" >&2; exit 1; }
	@echo "setup ok: bats $$(bats --version | awk '{print $$2}'), jq $$(jq --version), $$(podman --version)"

harness-up:              ## Start the containerised test harness
	@./harness/suite.sh up

harness-down:            ## Stop the containerised test harness
	@./harness/suite.sh down

test: harness-up         ## Run every test
	@shopt -s nullglob; files=($(TESTS)/*.bats); \
	if [ $${#files[@]} -eq 0 ]; then echo "0 tests"; exit 0; fi; \
	$(BATS) "$${files[@]}"

test-isolation: harness-up ## Run only the isolation boundary tests
	@$(BATS) $(TESTS)/09-isolation.bats

TOOLKIT ?= $(HOME)/.local/share/text-to-3d-toolkit
OUT     ?= $(HOME)/t2m-out
PROMPT  ?= a weathered wooden treasure chest with iron bands
RES     ?= 512
SEED    ?= 1
# FACES is a game budget, not a speed knob, and it trades the wrong way:
#   FACES=150000 (engine default)   325 s   142,824 triangles
#   FACES=8000                     ~420 s    ~8,000 triangles
# ~90 s more for a mesh 12x lighter. Worth paying because decimation runs BEFORE
# the UV bake, so the texture is baked onto the geometry that survives --
# decimating in Blender afterwards costs you that fit. Raise it only if you
# intend to retopologise by hand anyway.
FACES   ?= 8000

llm-up:                  ## Start the LLM contract (opencode/goose/OpenPencil)
	@systemctl --user start llama-swap contract-socket
	@echo "contract on http://127.0.0.1:8080  (roles: fast, fast-text, deep)"

llm-down:                ## Stop the LLM contract
	@systemctl --user stop llama-swap contract-socket

media-up:                ## Start image + mesh + rig services
	@systemctl --user start media-comfy media-engine media-rig
	@printf "waiting"; for i in $$(seq 1 60); do \
	  curl -sf -m 2 http://127.0.0.1:8188/system_stats >/dev/null 2>&1 && \
	  curl -sf -m 2 http://127.0.0.1:8189/health >/dev/null 2>&1 && break; \
	  printf "."; sleep 3; done; echo
	@echo "comfy 8188 · mesh 8189 · rig 8191"

media-down:              ## Stop them and free the GPU
	@systemctl --user stop media-comfy media-engine media-rig
	@echo "stopped; GPU idle"

asset: media-up          ## Text to GLB.  PROMPT="..." [RES=512|1024] [FACES=8000]
	@trap '$(MAKE) --no-print-directory media-down' EXIT; \
	python3 $(TOOLKIT)/layers/pipeline/src/pipeline.py \
	  --prompt "$(PROMPT)" --out-dir $(OUT) --res $(RES) \
	  --target-faces $(FACES) --seed $(SEED) \
	  --runner server --engine-endpoint http://127.0.0.1:8189 \
	  --glb-path-only

rig: media-up            ## Rig a humanoid GLB.  make rig GLB=out/foo.glb
	@trap '$(MAKE) --no-print-directory media-down' EXIT; \
	T2M_RIG_DRIVER=$(TOOLKIT)/layers/rig/src/rig.py tools/rig.sh \
	  --glb "$(GLB)" --out-dir $(OUT)

viewer:                  ## Browse generated GLBs (Ctrl-C to stop; needs no GPU)
	@echo "http://127.0.0.1:8190   -- Ctrl-C when done"
	@python3 $(TOOLKIT)/layers/preview/src/serve.py --dir $(OUT) --host 127.0.0.1 --port 8190

sprite: media-up         ## Pixel-art sprite, keyed to real alpha.  make sprite SUBJ=orc
	@trap '$(MAKE) --no-print-directory media-down' EXIT; \
	python3 tools/pixel_ab.py klein --only $(or $(SUBJ),knight) --out $(OUT)/sprites --key

status:                  ## What is running and what it is costing
	@printf "GPU busy   %s%%\n" "$$(cat /sys/class/drm/card1/device/gpu_busy_percent 2>/dev/null)"
	@printf "GPU memory %.1f GiB\n" "$$(awk '{print $$1/1073741824}' /sys/class/drm/card1/device/mem_info_gtt_used)"
	@echo "--- containers ---";  podman ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null || true
	@echo "--- services ---"
	@for s in llama-swap contract-socket media-comfy media-engine media-rig; do \
	   printf "%-18s %s\n" "$$s" "$$(systemctl --user is-active $$s 2>/dev/null)"; done
	@echo "--- stray helpers ---"
	@pgrep -a -x python3 2>/dev/null | grep -E "serve\.py|pipeline\.py|pixel_ab" || echo "none"

stop-all:                ## Stop EVERYTHING this repo can start, and prove it
	@systemctl --user stop media-comfy media-engine media-rig llama-swap contract-socket 2>/dev/null || true
	@podman rm -f media-comfy media-engine media-rig contract-proxy >/dev/null 2>&1 || true
	@for p in $$(pgrep -x python3 2>/dev/null); do \
	   tr '\0' ' ' < /proc/$$p/cmdline 2>/dev/null | grep -q "serve\.py\|pipeline\.py\|pixel_ab" && kill $$p 2>/dev/null || true; done
	@sleep 3
	@$(MAKE) --no-print-directory status

clean:                   ## Remove test volumes left behind by a failed run
	@podman volume ls -q --filter label=suite-test | xargs -r podman volume rm -f
