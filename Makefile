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
        media-up media-down asset viewer sprite rig llm-up llm-down status stop-all \
        faces-ladder ref character prompt refcheck rigcheck mesh from-ref require-subj require-img

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
