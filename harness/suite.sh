#!/usr/bin/env bash
# Harness control for the containerised evaluation environment.
#
# Shape:
#   llama-swap      binds 127.0.0.1 ONLY. Never any routable interface, so the
#                   LAN cannot reach it no matter what the firewall says.
#   host socat      bridges that loopback port to a unix socket in
#                   $XDG_RUNTIME_DIR, which is mode 0700 and owned by nathan.
#   contract-proxy  on suite-net, with ONLY that socket bind-mounted. It runs
#                   socat. It is not an agent and never sees a model or a
#                   prompt. This is the single mount in the whole harness.
#   agent           on suite-net only, with no mounts but its work volume. No
#                   route off the box, and no path to the host except through
#                   a unix socket it cannot see.
#
# Exposure is structural. Nothing is bound to a routable address, so there is
# no rule to forget and no firewall to enable.
set -euo pipefail

NET=${NET:-suite-net}
PROBE=${PROBE:-localhost/suite-probe}
CONTRACT_PORT=${CONTRACT_PORT:-8080}
PROXY=${PROXY:-contract-proxy}
SOCK=${SOCK:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/contract.sock}

build () {
  podman build -q -t "$PROBE" -f harness/Containerfile.probe harness >/dev/null
}

up () {
  podman network exists "$NET" || podman network create --internal "$NET" >/dev/null

  # Host bridge: loopback TCP -> unix socket. llama-swap is TCP-only, so this
  # is what lets it stay on 127.0.0.1 and still be reachable from a container.
  if ! [ -S "$SOCK" ] || ! socat -u OPEN:/dev/null UNIX-CONNECT:"$SOCK" 2>/dev/null; then
    rm -f "$SOCK"
    setsid socat UNIX-LISTEN:"$SOCK",fork,reuseaddr,mode=600 \
      TCP:127.0.0.1:${CONTRACT_PORT} </dev/null >/dev/null 2>&1 &
    for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
  fi

  podman container exists "$PROXY" && podman rm -f "$PROXY" >/dev/null 2>&1 || true
  # Attached to both networks. Nothing else is.
  # All three descriptors closed. `podman run -d` leaves a conmon process that
  # inherits whatever stdout/stderr it was given; under bats that keeps the
  # test runner's pipe open and bats never exits, with every test already
  # green. Cost real time to find, so: detach properly.
  #
  # suite-net ONLY. The proxy has no second network -- its path to the host is
  # the mounted socket, nothing else.
  podman run -d --name "$PROXY" --network "$NET" \
    -v "${SOCK}:/run/contract.sock" \
    "$PROBE" socat TCP-LISTEN:${CONTRACT_PORT},fork,reuseaddr \
    UNIX-CONNECT:/run/contract.sock </dev/null >/dev/null 2>&1
}

down () {
  podman rm -f "$PROXY" >/dev/null 2>&1 || true
  podman network rm -f "$NET" >/dev/null 2>&1 || true
  pkill -f "UNIX-LISTEN:${SOCK}" 2>/dev/null || true
  rm -f "$SOCK"
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
