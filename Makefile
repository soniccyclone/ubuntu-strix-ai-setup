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
        media-up media-down asset viewer sprite rig llm-up llm-down chat status stop-all \
        kairic-up kairic-down kairic-install kairic-setup env \
        uncensored uncensored-prereqs uncensored-images uncensored-weights uncensored-recipe \
        uncensored-pack uncensored-validate uncensored-bench \
        faces-ladder ref character prompt refcheck rigcheck mesh from-ref require-subj require-img

help:                    ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  %-20s %s\n", $$1, $$2}'

env:                     ## Write .env if absent, then regenerate the serving overlay
	@scripts/env-init.sh
	@scripts/env-overlay.sh

setup:                   ## Install the user-level test tooling
	@command -v bats >/dev/null || npm i -g bats
	@command -v jq   >/dev/null || { echo "jq missing; apt install jq (needs root)" >&2; exit 1; }
	@command -v podman >/dev/null || { echo "podman missing" >&2; exit 1; }
	@command -v dolt >/dev/null || { echo "dolt missing; the issue-history assertions need it. Install user-level from github.com/dolthub/dolt/releases and put it on PATH." >&2; exit 1; }
	@echo "setup ok: bats $$(bats --version | awk '{print $$2}'), jq $$(jq --version), $$(podman --version), dolt $$(dolt version | head -1 | awk '{print $$3}')"

harness-up:              ## Start the containerised test harness
	@./harness/suite.sh up

harness-down:            ## Stop the containerised test harness
	@./harness/suite.sh down

# Seven of these files hit the media services on 8188/8189/8191. Without
# media-up they passed only when something else happened to have started them,
# which is how a suite starts lying about what it covered.
test: harness-up media-up  ## Run every test
	@shopt -s nullglob; files=($(TESTS)/*.bats); \
	if [ $${#files[@]} -eq 0 ]; then echo "0 tests"; exit 0; fi; \
	trap '$(STOP_MEDIA)' EXIT; \
	$(BATS) "$${files[@]}"

test-isolation: harness-up ## Run only the isolation boundary tests
	@$(BATS) $(TESTS)/09-isolation.bats

TOOLKIT ?= $(HOME)/.local/share/text-to-3d-toolkit
OUT     ?= $(HOME)/t2m-out
# Used in traps instead of `$(MAKE) media-down`. GNU make executes any recipe
# line containing $(MAKE) even under `-n`, so a dry run of these targets was
# really running them -- it tried to mesh with the services stopped.
STOP_MEDIA = systemctl --user stop media-comfy media-engine media-rig
PROMPT  ?= a weathered wooden treasure chest with iron bands
RES     ?= 1024          # TRELLIS voxel grid, not the image size
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

chat: llm-up             ## Stream a reply live.  Q="..." [M=fast|deep]
	@test -n "$(Q)" || { echo 'usage: make chat Q="explain X" [M=deep]'; exit 2; }
	@python3 tools/chat.py --model $(or $(M),fast) $(if $(HIDE),--hide-thinking,) "$(Q)"

llm-down:                ## Stop the LLM contract
	@systemctl --user stop llama-swap contract-socket

media-up:                ## Start image + mesh + rig services
	@systemctl --user start media-comfy media-engine media-rig
	@printf "waiting"; for i in $$(seq 1 80); do \
	  curl -sf -m 2 http://127.0.0.1:8188/system_stats >/dev/null 2>&1 && \
	  curl -sf -m 2 http://127.0.0.1:8189/health      >/dev/null 2>&1 && \
	  curl -sf -m 2 http://127.0.0.1:8191/health      >/dev/null 2>&1 && break; \
	  printf "."; sleep 3; done; echo
	@# Report per port rather than announcing all three. The rig service loads
	@# SkinTokens checkpoints and is the slowest to answer; an earlier version
	@# waited only on 8188 and 8189 and then printed "rig 8191" anyway, so
	@# `make rig` fired into a socket that was not listening yet.
	@for pp in "comfy:8188:/system_stats" "mesh:8189:/health" "rig:8191:/health"; do \
	  n=$${pp%%:*}; rest=$${pp#*:}; port=$${rest%%:*}; path=$${rest#*:}; \
	  if curl -sf -m 2 "http://127.0.0.1:$$port$$path" >/dev/null 2>&1; \
	    then printf "%-6s %s ready\n" "$$n" "$$port"; \
	    else printf "%-6s %s NOT READY\n" "$$n" "$$port"; fi; done

media-down:              ## Stop them and free the GPU
	@systemctl --user stop media-comfy media-engine media-rig
	@echo "stopped; GPU idle"

asset: media-up          ## Text to GLB.  PROMPT="..." [RES=512|1024] [FACES=8000]
	@trap '$(STOP_MEDIA)' EXIT; \
	python3 $(TOOLKIT)/layers/pipeline/src/pipeline.py \
	  --prompt "$(PROMPT)" --out-dir $(OUT) --res $(RES) \
	  --target-faces $(FACES) --seed $(SEED) \
	  --runner server --engine-endpoint http://127.0.0.1:8189 \
	  --glb-path-only

rig: media-up            ## Rig a humanoid GLB.  make rig GLB=out/foo.glb
	@trap '$(STOP_MEDIA)' EXIT; \
	T2M_RIG_DRIVER=$(TOOLKIT)/layers/rig/src/rig.py tools/rig.sh \
	  --glb "$(GLB)" --out-dir $(OUT); \
	rigged=$(OUT)/$$(basename "$(GLB)" .glb)-rigged.glb; \
	test -f "$$rigged" && python3 tools/rigcheck.py "$$rigged" || true

SUBJ    ?=
CHARSEED ?= 100000
IMGSIZE ?= 1024          # reference image pixels (characters want 1024)

require-subj:
	@test -n "$(SUBJ)" || { echo 'usage: make $(MAKECMDGOALS) SUBJ="an orc shaman with a gnarled staff"'; exit 2; }

ref: require-subj media-up  ## Character reference sheet only.  SUBJ="an orc shaman"
	@trap '$(STOP_MEDIA)' EXIT; \
	img=$$(python3 tools/character.py --subject "$(SUBJ)" --seed $(CHARSEED) --size $(RES) | jq -r .image); \
	echo "reference: $$img"; python3 tools/refcheck.py "$$img" || true

mesh: require-img media-up  ## Existing image -> textured GLB.  IMG=path [FACES=8000]
	@trap '$(STOP_MEDIA)' EXIT; \
	python3 tools/refcheck.py "$(IMG)" || { echo "fix the reference first"; exit 3; }; \
	glb=$(OUT)/$$(basename "$(IMG)" .png).glb; \
	python3 tools/mesh.py "$(IMG)" "$$glb" --resolution $(RES) --target-faces $(FACES) --seed $(SEED); \
	echo "mesh: $$glb"

from-ref: require-img media-up  ## Existing image -> mesh -> rigged GLB.  IMG=path
	@trap '$(STOP_MEDIA)' EXIT; \
	python3 tools/refcheck.py "$(IMG)" || { echo "fix the reference first"; exit 3; }; \
	glb=$(OUT)/$$(basename "$(IMG)" .png).glb; \
	python3 tools/mesh.py "$(IMG)" "$$glb" --resolution $(RES) --target-faces $(FACES) --seed $(SEED); \
	echo "mesh: $$glb"; \
	T2M_RIG_DRIVER=$(TOOLKIT)/layers/rig/src/rig.py tools/rig.sh --glb "$$glb" --out-dir $(OUT) | tail -4; \
	rigged=$(OUT)/$$(basename "$$glb" .glb)-rigged.glb; \
	test -f "$$rigged" && python3 tools/rigcheck.py "$$rigged" || true

rigcheck:                ## Is a rigged GLB skeleton coherent?  GLB=path
	@python3 tools/rigcheck.py "$(GLB)"

refcheck:                ## Is a reference image one connected subject?  IMG=path
	@python3 tools/refcheck.py "$(IMG)"

character: require-subj media-up  ## Reference -> mesh -> rigged GLB.  SUBJ="an orc shaman"
	@trap '$(STOP_MEDIA)' EXIT; \
	img=$$(python3 tools/character.py --subject "$(SUBJ)" --seed $(CHARSEED) --size $(IMGSIZE) | jq -r .image); \
	echo "reference: $$img"; \
	python3 tools/refcheck.py "$$img" || { \
	  echo "stopping before the mesh stage; re-roll with CHARSEED=$$((($(CHARSEED))+1))"; exit 3; }; \
	glb=$(OUT)/$$(basename "$$img" .png).glb; \
	python3 tools/mesh.py "$$img" "$$glb" --resolution 1024 --target-faces $(FACES) --seed $(CHARSEED); \
	echo "mesh: $$glb"; \
	T2M_RIG_DRIVER=$(TOOLKIT)/layers/rig/src/rig.py tools/rig.sh --glb "$$glb" --out-dir $(OUT) | tail -3; \
	echo "rigged into $(OUT)"

prompt:                  ## Show the prompt a subject would produce, run nothing
	@python3 tools/character.py --subject "$(SUBJ)" --print-prompt

LADDER ?= 2000 8000 20000 60000

require-img:
	@test -n "$(IMG)" || { echo 'usage: make faces-ladder IMG=path/to/reference.png'; exit 2; }

faces-ladder: require-img  ## Mesh ONE image at several budgets to compare.  IMG=path
	@$(MAKE) --no-print-directory media-up
	@trap '$(STOP_MEDIA)' EXIT; \
	for f in $(LADDER); do \
	  echo "--- $$f faces ---"; \
	  python3 tools/mesh.py "$(IMG)" "$(OUT)/ladder-$$f.glb" \
	    --resolution $(RES) --target-faces $$f --seed $(SEED) || true; \
	  python3 tools/glbinfo.py "$(OUT)/ladder-$$f.glb" 2>/dev/null | jq -c '{triangles,textures}' || true; \
	done
	@echo "compare them with:  make viewer"

viewer:                  ## Browse generated GLBs (Ctrl-C to stop; needs no GPU)
	@echo "http://127.0.0.1:8190   -- Ctrl-C when done"
	@python3 $(TOOLKIT)/layers/preview/src/serve.py --dir $(OUT) --host 127.0.0.1 --port 8190

sprite: media-up         ## Pixel-art sprite, keyed to real alpha.  make sprite SUBJ=orc
	@trap '$(STOP_MEDIA)' EXIT; \
	python3 tools/pixel_ab.py klein --only $(or $(SUBJ),knight) --out $(OUT)/sprites --key

kairic-setup:            ## Full setup from a fresh machine: image, weights, wiring
	@scripts/setup-kairic.sh

kairic-install:          ## Install the Kairic contract units (one time)
	@mkdir -p ~/.config/systemd/user
	@cp systemd/llama-swap-kairic.service ~/.config/systemd/user/
	@systemctl --user daemon-reload
	@echo "installed. 'make kairic-up' to start."
	@mkdir -p ~/.config/opencode
	@ln -sfn $(PWD)/config/opencode-kairic.jsonc ~/.config/opencode/opencode.jsonc
	@echo "opencode config linked at ~/.config/opencode/opencode.jsonc"

kairic-up:               ## Start Kairic 27B (compat+live sampling) + 4B compaction; ~61 GiB at load, ~78 GiB peak
	@avail=$$(free -g | awk 'NR==2{print $$7}'); 	  if [ "$$avail" -lt 70 ]; then 	    echo "ABORT: $${avail} GiB available, this needs 60 and leaves nothing." >&2; 	    echo "Something else is holding memory. 'make status' first." >&2; exit 1; fi
	@systemctl --user is-active llama-swap >/dev/null 2>&1 && { 	  echo "ABORT: the 122B contract (llama-swap) is up. Two contracts do not fit." >&2; 	  echo "Run 'make llm-down' first." >&2; exit 1; } || true
	@systemctl --user start llama-swap-kairic
	@echo "contract on http://127.0.0.1:8080  (roles: code, ablit, compact)"
	@echo "models load on first request; the 27B takes ~90s."

kairic-down:             ## Stop the Kairic contract and prove the memory came back
	@systemctl --user stop llama-swap-kairic 2>/dev/null || true
	@podman rm -f kairic-serve ablit-serve compact-serve >/dev/null 2>&1 || true
	@sleep 3
	@printf "free now: %s GiB\n" "$$(free -g | awk 'NR==2{print $$7}')"

# Abliterated Qwen3.8-27B at Kairic speed. docs/uncensored-27b-replication.md.
# Each step is idempotent; `uncensored` runs them in order. The pack and
# validate steps run for an hour or more; bench starts and stops a server.
uncensored:              ## Everything below, in order: ~150 GB of downloads, hours
	@scripts/uncensored-27b.sh all
uncensored-prereqs:      ## Host checks: podman, /dev/kfd, render group, GTT, disk, Kairic present
	@scripts/uncensored-27b.sh prereqs
uncensored-images:       ## Build qwen-convert and rocmi4 images at ROCmFPX c49ebdbd
	@scripts/uncensored-27b.sh images
uncensored-weights:      ## Download the abliterated safetensors (74 GB, sha256-checked)
	@scripts/uncensored-27b.sh weights
uncensored-recipe:       ## Convert to bf16 GGUF and quantise to Kairic's mixed-precision recipe
	@scripts/uncensored-27b.sh recipe
uncensored-pack:         ## Pack the three IU4 sidecars from the bf16 GGUF
	@scripts/uncensored-27b.sh pack
uncensored-validate:     ## Pack STOCK and byte-diff against Kairic's published sidecars
	@scripts/uncensored-27b.sh validate
uncensored-bench:        ## Serve stock-repacked and ablit arms, measure tok/s and HumanEval, stop
	@scripts/uncensored-27b.sh bench

status:                  ## What is running and what it is costing
	@printf "GPU busy   %s%%\n" "$$(cat /sys/class/drm/card1/device/gpu_busy_percent 2>/dev/null)"
	@printf "GPU memory %.1f GiB\n" "$$(awk '{print $$1/1073741824}' /sys/class/drm/card1/device/mem_info_gtt_used)"
	@echo "--- containers ---";  podman ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null || true
	@echo "--- services ---"
	@for s in llama-swap llama-swap-kairic contract-socket media-comfy media-engine media-rig; do \
	   printf "%-18s %s\n" "$$s" "$$(systemctl --user is-active $$s 2>/dev/null)"; done
	@echo "--- stray helpers ---"
	@pgrep -a -x python3 2>/dev/null | grep -E "serve\.py|pipeline\.py|pixel_ab" || echo "none"

stop-all:                ## Stop EVERYTHING this repo can start, and prove it
	@systemctl --user stop media-comfy media-engine media-rig llama-swap llama-swap-kairic contract-socket 2>/dev/null || true
	@podman rm -f media-comfy media-engine media-rig contract-proxy kairic-serve ablit-serve compact-serve kairic-sweep >/dev/null 2>&1 || true
	@for p in $$(pgrep -x python3 2>/dev/null); do \
	   tr '\0' ' ' < /proc/$$p/cmdline 2>/dev/null | grep -q "serve\.py\|pipeline\.py\|pixel_ab" && kill $$p 2>/dev/null || true; done
	@sleep 3
	@$(MAKE) --no-print-directory status

clean:                   ## Remove test volumes left behind by a failed run
	@podman volume ls -q --filter label=suite-test | xargs -r podman volume rm -f
