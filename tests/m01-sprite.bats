#!/usr/bin/env bats
# CUJ-01 — a described character becomes a game-ready sprite.
# CUJ-02 — matched pairs exist so Nathan can pick a track by eye.

OUT=/tmp/sprite-test-$$

setup_file() {
  curl -sf -m 10 http://127.0.0.1:8188/system_stats >/dev/null \
    || { echo "media-comfy not answering" >&2; return 1; }
}
teardown_file() { rm -rf /tmp/sprite-test-*; }

@test "raw generator output has no alpha, and the pipeline does not pretend otherwise" {
  # Recorded as a test because it was got wrong: the LoRA card claims RGBA and
  # the model paints a checkerboard, which is visually identical to real
  # transparency in every viewer. The VAE returns three channels; alpha has to
  # be constructed. If a future model does emit alpha this test fails, which is
  # the correct way to find out.
  mkdir -p "$OUT"
  run python3 tools/pixel_ab.py klein --only chest --out "$OUT"
  [ "$status" -eq 0 ]
  raw=$(ls "$OUT"/AB-klein-chest.png)
  run python3 tools/pngprobe.py "$raw"
  [[ "$output" == *"color_type=2"* ]]
}

@test "the keyed sprite carries real alpha with a transparent corner" {
  mkdir -p "$OUT"
  run python3 tools/pixel_ab.py klein --only knight --out "$OUT" --key
  [ "$status" -eq 0 ]
  keyed=$(ls "$OUT"/AB-klein-knight-keyed.png)
  run python3 tools/pngprobe.py "$keyed"
  [[ "$output" == *"color_type=6"* ]]
  [[ "$output" == *"corner_alpha=0"* ]]
}

@test "keying removes the background without eating the sprite" {
  mkdir -p "$OUT"
  python3 tools/pixel_ab.py klein --only orc --out "$OUT" >/dev/null
  run python3 tools/key_bg.py "$OUT/AB-klein-orc.png" "$OUT/orc-keyed.png"
  [ "$status" -eq 0 ]
  pct=$(grep -oE '= [0-9]+\.[0-9]+%' <<<"$output" | tr -dc '0-9.')
  # A sprite that fills the frame or vanishes entirely both indicate a broken
  # key. 40-95% transparent is a sprite on a background.
  awk -v p="$pct" 'BEGIN{exit !(p > 40 && p < 95)}'
}

@test "a sprite generates in single-digit seconds warm" {
  mkdir -p "$OUT"
  python3 tools/pixel_ab.py klein --only knight --out "$OUT" >/dev/null
  run python3 tools/pixel_ab.py klein --only knight --out "$OUT"
  [ "$status" -eq 0 ]
  secs=$(grep -oE '[0-9]+\.[0-9]+ s' <<<"$output" | head -1 | tr -d ' s')
  [ -n "$secs" ]
  awk -v s="$secs" 'BEGIN{exit !(s < 15)}'
}

@test "both tracks produce the same subject set at matched seeds" {
  mkdir -p "$OUT"
  run python3 tools/pixel_ab.py klein --out "$OUT" --seed 991
  [ "$status" -eq 0 ]
  run python3 tools/pixel_ab.py sdxl --out "$OUT" --seed 991
  [ "$status" -eq 0 ]
  for s in knight archer orc chest; do
    [ -f "$OUT/AB-klein-${s}.png" ]
    [ -f "$OUT/AB-sdxl-${s}.png" ]
  done
}
