#!/usr/bin/env bats
# CUJ-09 — nothing under evaluation reaches Nathan's files.
#
# This is the one slice tested to destruction, because every failure mode in it
# is silent. Everything else in this suite smoke-tests plumbing and leaves
# judgement to Nathan; that trade is only sound if the blast radius is real.

PROBE=localhost/suite-probe
NET=suite-net
CONTRACT_PORT=8080

# The harness is brought up by `make test`, not here. Starting a detached
# container from inside bats leaves a conmon process holding the runner's
# stdout, and bats then never exits even with every test green.
setup_file() {
  podman container exists contract-proxy \
    || { echo "harness not up; run: ./harness/suite.sh up" >&2; return 1; }
}

@test "only the proxy has a host bind mount, and it is one socket" {
  # Inspect what is actually mounted, not what the source text says: ${SOCK}
  # and ${vol} are indistinguishable to grep, and only one is a host path.
  run podman inspect contract-proxy --format '{{range .Mounts}}{{.Type}}:{{.Source}}{{"\n"}}{{end}}'
  [ "$status" -eq 0 ]
  binds=$(grep -c '^bind:' <<<"$output" || true)
  [ "$binds" -eq 1 ]
  [[ "$output" == *"contract.sock"* ]]

  # An agent container mounts nothing from the host at all.
  vol="mnt-$$"
  podman volume create --label suite-test "$vol" >/dev/null
  cid=$(podman run -d --network="$NET" -v "${vol}:/work" "$PROBE" sleep 30)
  run podman inspect "$cid" --format '{{range .Mounts}}{{.Type}}{{"\n"}}{{end}}'
  podman rm -f "$cid" >/dev/null; podman volume rm -f "$vol" >/dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"bind"* ]]
}

@test "an agent container cannot see the host home" {
  run podman run --rm --network="$NET" "$PROBE" sh -c 'ls /home | wc -l'
  [ "$status" -eq 0 ]
  [ "${output//[[:space:]]/}" = "0" ]

  run podman run --rm --network="$NET" "$PROBE" ls /home/nathan
  [ "$status" -ne 0 ]
}

@test "an agent container reaches the contract through the proxy" {
  run podman run --rm --network="$NET" "$PROBE" \
      curl -sf -m 10 "http://contract-proxy:${CONTRACT_PORT}/v1/models"
  [ "$status" -eq 0 ]
  jq -e '.data|length > 0' <<<"$output" >/dev/null
}

@test "an agent container reaches nothing but the contract" {
  # No route off the box at all: suite-net is --internal.
  run podman run --rm --network="$NET" "$PROBE" curl -sf -m 6 http://1.1.1.1/
  [ "$status" -ne 0 ]

  # And it cannot step around the proxy to the host directly.
  run podman run --rm --network="$NET" "$PROBE" \
      curl -sf -m 6 "http://host.containers.internal:${CONTRACT_PORT}/v1/models"
  [ "$status" -ne 0 ]

  # DNS for the outside world resolves to nothing usable either.
  run podman run --rm --network="$NET" "$PROBE" curl -sf -m 6 https://huggingface.co/
  [ "$status" -ne 0 ]
}

@test "the contract is bound to loopback and unreachable from the LAN" {
  # Assert the BINDING, not just a refusal. A refusal can come from a firewall
  # rule someone disables later; a socket bound to 127.0.0.1 cannot receive a
  # packet addressed to a routable interface at all. No firewall is involved.
  run ss -ltn "sport = :${CONTRACT_PORT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"127.0.0.1:${CONTRACT_PORT}"* ]]
  [[ "$output" != *"0.0.0.0:${CONTRACT_PORT}"* ]]
  [[ "$output" != *"*:${CONTRACT_PORT}"* ]]

  # And confirm the consequence on every routable address this host owns.
  lan_addrs=$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}')
  [ -n "$lan_addrs" ]
  for addr in $lan_addrs; do
    run curl -sf -m 4 "http://${addr}:${CONTRACT_PORT}/v1/models"
    [ "$status" -ne 0 ]
  done
}

@test "a work volume outlives its container and is readable by another" {
  vol="suite-work-$$"
  podman volume create --label suite-test "$vol" >/dev/null
  podman run --rm --network="$NET" -v "${vol}:/work" "$PROBE" \
      sh -c 'echo written-by-first > /work/marker'
  run podman run --rm --network="$NET" -v "${vol}:/work" "$PROBE" cat /work/marker
  [ "$status" -eq 0 ]
  [ "$output" = "written-by-first" ]
  podman volume rm -f "$vol" >/dev/null
}
