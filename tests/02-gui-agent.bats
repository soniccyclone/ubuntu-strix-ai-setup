#!/usr/bin/env bats
# CUJ-02 — a GUI agent works on files without a terminal.
#
# Tested through goose's published image and its CLI, because the desktop build
# needs a display and this harness deliberately has none. That proves the
# contract and the agent loop, NOT the desktop binary. Nathan confirms the
# desktop app by pointing it at the same endpoint and using it.

NET=suite-net
IMG=localhost/suite-goose

goose_env=(
  -e GOOSE_PROVIDER=openai
  -e OPENAI_HOST=http://contract-proxy:8080
  -e OPENAI_BASE_PATH=v1/chat/completions
  -e OPENAI_API_KEY=not-needed
  -e GOOSE_MODEL=fast
)

@test "agent runs from environment configuration alone" {
  # No model file path anywhere in the agent's own configuration: it names a
  # role, and the roster decides what serves it.
  run bash -c "podman run --rm --network=$NET ${goose_env[*]} --entrypoint sh $IMG -c 'env | grep -c GOOSE_MODEL=fast'"
  [ "$status" -eq 0 ]
  run bash -c "podman run --rm --network=$NET ${goose_env[*]} --entrypoint sh $IMG -c 'env | grep -c gguf || true'"
  [ "${output//[[:space:]]/}" = "0" ]
}

@test "agent reaches the contract and completes a tool call" {
  vol="goose-$$"
  podman volume create --label suite-test "$vol" >/dev/null
  podman run --rm --network="$NET" -v "${vol}:/work" -w /work --entrypoint sh "$IMG" \
    -c 'echo "the secret word is XYLOPHONE" > /work/notes.txt' >/dev/null

  run timeout 900 podman run --rm --network="$NET" -v "${vol}:/work" -w /work \
      "${goose_env[@]}" "$IMG" \
      run -t "Read the file notes.txt in the current directory and tell me the secret word."

  podman volume rm -f "$vol" >/dev/null
  [ "$status" -eq 0 ]
  # XYLOPHONE exists only in the file, so it proves a tool call read it.
  [[ "$output" == *"XYLOPHONE"* ]]
}

@test "the agent container mounts nothing from the host" {
  # goose can run arbitrary shell. The guarantee is not that it behaves, it is
  # that there is no host path in its mount table to reach in the first place.
  vol="goose-mnt-$$"
  podman volume create --label suite-test "$vol" >/dev/null
  cid=$(podman run -d --network="$NET" -v "${vol}:/work" --entrypoint sleep "$IMG" 30)
  run podman inspect "$cid" --format '{{range .Mounts}}{{.Type}}:{{.Source}}{{"\n"}}{{end}}'
  podman rm -f "$cid" >/dev/null; podman volume rm -f "$vol" >/dev/null
  [ "$status" -eq 0 ]
  # No bind mounts at all: the agent has no host path in its mount table.
  [[ "$output" != *"bind:"* ]]
  # The one mount it does have is a podman-managed volume. Its Source sits
  # under $HOME because that is where rootless podman keeps its storage --
  # podman's own directory, not a bind of Nathan's files. Assert it is inside
  # the storage root rather than merely "not under /home", which would fail
  # for the wrong reason.
  [[ "$output" == volume:* ]]
  [[ "$output" == *"/containers/storage/volumes/"* ]]
}
