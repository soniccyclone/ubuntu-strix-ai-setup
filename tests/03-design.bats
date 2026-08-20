#!/usr/bin/env bats
# CUJ-03 — a described screen becomes an editable document and returns as code.
#
# Exercised through the OpenPencil CLI and the AI SDK it uses, not the Tauri
# desktop build, which needs a display this harness deliberately does not have.
# These prove the document engine and the provider seam. They do NOT prove the
# desktop binary; Nathan confirms that by pointing it at the same endpoint.

NET=suite-net
IMG=localhost/suite-openpencil

@test "the provider seam reaches the contract on the OpenAI shape" {
  # createOpenAI({baseURL}) is exactly what OpenPencil's
  # createOpenAICompatibleAdapter() calls in src/app/ai/providers/compatible.ts.
  # The OpenAI shape is used on purpose: the browser build fails CORS on the
  # ANTHROPIC shape, while the Tauri build does not. Nathan's desktop app may
  # take either path, so this covers one of the two.
  run timeout 900 podman run --rm --network="$NET" \
      -e CONTRACT_BASE_URL=http://contract-proxy:8080/v1 -e CONTRACT_ROLE=fast \
      "$IMG" bun /opt/ai-probe.mjs
  [ "$status" -eq 0 ]
  [[ "$output" == *"OPENPENCIL OK"* ]]
}

@test "HTML becomes an editable document with addressable nodes" {
  vol="op-$$"; podman volume create --label suite-test "$vol" >/dev/null
  run podman run --rm -v "${vol}:/work" -w /work "$IMG" sh -c '
    printf "%s\n" "<div class=\"card\"><p class=\"title\">Telemetry Panel</p><p class=\"body\">Readings from the sensor array.</p></div>" > card.html
    printf "%s\n" ".card{display:flex;flex-direction:column;gap:16px;padding:24px;width:320px}.title{font-size:24px;font-weight:700}.body{font-size:14px}" > card.css
    openpencil import card.html --css card.css -o card.fig >/dev/null 2>&1 &&
    openpencil tree card.fig'
  [ "$status" -eq 0 ]
  # Real nodes, not a flat image: a frame containing two addressable text nodes.
  [[ "$output" == *"[frame]"* ]]
  [[ "$output" == *'[text] "Telemetry Panel"'* ]]
  [[ "$output" == *'[text] "Readings from the sensor array."'* ]]
  podman volume rm -f "$vol" >/dev/null
}

@test "export to markup and reimport preserves text and addressability" {
  vol="op-rt-$$"; podman volume create --label suite-test "$vol" >/dev/null
  run podman run --rm -v "${vol}:/work" -w /work "$IMG" sh -c '
    printf "%s\n" "<div class=\"card\"><p class=\"title\">Telemetry Panel</p><p class=\"body\">Readings from the sensor array.</p></div>" > card.html
    printf "%s\n" ".card{display:flex;flex-direction:column;gap:16px;padding:24px;width:320px}.title{font-size:24px;font-weight:700}.body{font-size:14px}" > card.css
    openpencil import card.html --css card.css -o a.fig >/dev/null 2>&1 || exit 1
    openpencil info a.fig | grep -oE "[0-9]+ nodes" | head -1 | sed "s/^/BEFORE=/"
    openpencil export a.fig -f html --html standalone -o round.html >/dev/null 2>&1 || exit 1
    openpencil import round.html -o b.fig >/dev/null 2>&1 || exit 1
    openpencil info b.fig | grep -oE "[0-9]+ nodes" | head -1 | sed "s/^/AFTER=/"
    openpencil tree b.fig'
  podman volume rm -f "$vol" >/dev/null
  [ "$status" -eq 0 ]
  # The text survives the trip out to markup and back in.
  [[ "$output" == *"Telemetry Panel"* ]]
  [[ "$output" == *"Readings from the sensor array."* ]]
  # Text node count is preserved: two in, two out.
  [ "$(grep -c '\[text\]' <<<"$output")" -eq 2 ]

  # Total node count is NOT preserved and that is not a bug. A standalone HTML
  # export needs a document stage, so 3 nodes (1 FRAME, 2 TEXT) come back as
  # 6 (4 FRAME, 2 TEXT) wrapped in op-stage/op-N frames. Content survives the
  # trip; layout structure is re-nested. Asserting equality here would have
  # been asserting a requirement nobody has.
  [[ "$output" == *"op-stage"* ]]
}
