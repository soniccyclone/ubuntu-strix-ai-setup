#!/usr/bin/env bats
# CUJ-05 — ask a question about an image.

CONTRACT="${CONTRACT:-http://127.0.0.1:8080}"
IMG=tests/fixtures/magenta-circle.png

# Why a colour and not text: an mmproj that is loaded but unwired will answer
# plausibly about a blank image, so the fixture has to carry something
# unguessable. A first attempt used a word in a hand-rolled 5x7 bitmap font;
# the model genuinely read letterforms off it ("look at the 9th letter, it
# looks like an 'E'") but could not resolve them, which tested the font rather
# than the projector. Magenta cannot be guessed and needs no OCR.

ask () {  # ask <role> <max_tokens> -> writes /tmp/vis.$$.json, echoes HTTP code
  local b64; b64=$(base64 -w0 "$IMG")
  curl -s -o "/tmp/vis.$$.json" -w '%{http_code}' -m 900 \
    "$CONTRACT/v1/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$1\",\"max_tokens\":$2,\"messages\":[{\"role\":\"user\",\"content\":[
        {\"type\":\"text\",\"text\":\"What colour is the shape in this image, and what shape is it? Answer in under 10 words.\"},
        {\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,${b64}\"}}]}]}"
}

@test "the vision role reads the image" {
  run ask fast 1500
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
  content=$(jq -r '.choices[0].message.content' "/tmp/vis.$$.json")
  # Both facts, because either alone could be a lucky guess.
  [[ "${content,,}" == *"magenta"* ]]
  [[ "${content,,}" == *"circle"* ]]
  rm -f "/tmp/vis.$$.json"
}

@test "a text-only role refuses an image rather than inventing an answer" {
  run ask fast-text 600
  [ "$status" -eq 0 ]
  [ "${output:0:1}" != "2" ]
  # An explicit refusal naming the limitation, and no content at all. A
  # confident wrong answer would be the worst outcome here.
  msg=$(jq -r '.error.message // ""' "/tmp/vis.$$.json")
  [[ "$msg" == *"image input is not supported"* ]]
  content=$(jq -r '.choices[0].message.content // ""' "/tmp/vis.$$.json")
  [ -z "$content" ]
  [[ "${content,,}" != *"magenta"* ]]
  rm -f "/tmp/vis.$$.json"
}
