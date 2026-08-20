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

@test "no agent container declares a host bind mount" {
  # Any -v/--volume whose source starts with / or ~ is a host path.
  run grep -nE '(-v|--volume)[= ]+[~/]' harness/suite.sh
  [ "$status" -ne 0 ]
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

@test "the contract is not reachable from the LAN" {
  # Every globally-scoped address this host owns must refuse the contract port.
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
