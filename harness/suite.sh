#!/usr/bin/env bash
# Harness control for the containerised evaluation environment.
#
# Shape:
#   suite-net       podman network, --internal: no route off the box at all
#   contract-proxy  the ONLY container on both suite-net and the default
#                   network. Forwards one port to the bare-metal contract.
#   agent           on suite-net only. Its network namespace has no path to
#                   anything except other containers on suite-net.
#
# Egress is therefore structural, not a firewall rule someone can forget.
set -euo pipefail

NET=${NET:-suite-net}
PROBE=${PROBE:-localhost/suite-probe}
CONTRACT_PORT=${CONTRACT_PORT:-8080}
PROXY=${PROXY:-contract-proxy}

build () {
  podman build -q -t "$PROBE" -f harness/Containerfile.probe harness >/dev/null
}

up () {
  podman network exists "$NET" || podman network create --internal "$NET" >/dev/null
  podman container exists "$PROXY" && podman rm -f "$PROXY" >/dev/null 2>&1 || true
  # Attached to both networks. Nothing else is.
  # All three descriptors closed. `podman run -d` leaves a conmon process that
  # inherits whatever stdout/stderr it was given; under bats that keeps the
  # test runner's pipe open and bats never exits, with every test already
  # green. Cost 20 minutes to find, so: detach properly.
  podman run -d --name "$PROXY" --network "$NET" --network podman \
    "$PROBE" socat TCP-LISTEN:${CONTRACT_PORT},fork,reuseaddr \
    TCP:host.containers.internal:${CONTRACT_PORT} </dev/null >/dev/null 2>&1
}

down () {
  podman rm -f "$PROXY" >/dev/null 2>&1 || true
  podman network rm -f "$NET" >/dev/null 2>&1 || true
}

# Run a command in an agent container: suite-net only, no host mounts,
# optional named volume at /work.
agent () {
  local vol=${VOL:-}
  local args=(--rm --network "$NET")
  [ -n "$vol" ] && args+=(-v "${vol}:/work" --label suite-test)
  podman run "${args[@]}" "$PROBE" "$@"
}

case "${1:-}" in
  build) build ;;
  up)    build; up ;;
  down)  down ;;
  agent) shift; agent "$@" ;;
  *) echo "usage: $0 {build|up|down|agent <cmd...>}" >&2; exit 2 ;;
esac
