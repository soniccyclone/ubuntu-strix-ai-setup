#!/usr/bin/env bats
# No model in the contract may be served with --reasoning-format none.
#
# Qwen3's chat template emits a literal `<think>\n\n</think>\n\n` marker for
# non-thinking mode. With format `none` nothing parses it and it lands in
# message.content, so opencode renders an empty thinking block above the reply.
# The 27B was fixed for this; the 4B compaction worker beside it was not, which
# made the symptom look random -- it only surfaced when compaction, title or
# summary ran. 496 stored message parts carried the tags.
#
# `--reasoning off` is fine and desirable on the compaction worker. It is the
# FORMAT that must never be `none`; the two are separate knobs.

@test "no contract model is served with --reasoning-format none" {
  run bash -c "grep -rn -- '--reasoning-format none' config/ | grep -v '^config/[^:]*:[0-9]*: *#'"
  [ -z "$output" ]
}

@test "every model that sets a reasoning format sets a parsing one" {
  # deepseek and auto both strip the marker; none does not. Anything else is
  # unverified here and should not be assumed safe.
  #
  # Comments are stripped first. These files explain WHY --reasoning-format none
  # is wrong, and a scan that reads the explanation as a setting fails the file
  # that documents the fix.
  run bash -c "for f in config/*; do sed 's/#.*//' \"\$f\"; done \
               | grep -ohE -- '--reasoning-format [a-z]+' \
               | awk '{print \$2}' | sort -u | grep -vE '^(deepseek|auto)\$' || true"
  [ -z "$output" ]
}

@test "the runner's default reasoning format is a parsing one" {
  local fmt
  # ':-' is one separator, so the default is field 2 when splitting on '-'.
  fmt=$(grep -oE 'KAIRIC_REASONING_FORMAT:-[a-z]+' config/run-kairic-serve.sh \
        | head -1 | sed 's/.*:-//')
  [ "$fmt" = "deepseek" ] || [ "$fmt" = "auto" ]
}
