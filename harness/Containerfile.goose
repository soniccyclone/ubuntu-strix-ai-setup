# goose agent container.
#
# Uses the project's published image and configures it entirely by environment
# variables, which is the documented path and means no model file path ever
# appears in the agent's own configuration.
FROM ghcr.io/aaif-goose/goose:latest
USER root
RUN (apk add --no-cache curl jq git bash 2>/dev/null) || \
    (apt-get update && apt-get install -y --no-install-recommends curl jq git ca-certificates && rm -rf /var/lib/apt/lists/*)
WORKDIR /work
