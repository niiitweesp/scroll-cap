#!/usr/bin/env bash
set -euo pipefail

# Configuration
INPUT_IMAGE="input.png"
OVERLAY_TEXT="TEST"
FONT_FILE="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_SIZE=450
SCROLL_SPEED=200
DURATION=3
OUTPUT_FILE="output.mp4"

echo "Image:    $INPUT_IMAGE"
echo "Text:     $OVERLAY_TEXT"
echo "Output:   $OUTPUT_FILE"
echo "Starting render..."

# Check file exists
if [[ ! -f "$INPUT_IMAGE" ]]; then
  echo "Error: input file not found: $INPUT_IMAGE" >&2
  exit 1
fi

# Function attempts
probe_ffprobe_csv() {
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height \
    -of csv=p=0:s=x "$1" 2>/dev/null || return 1
}

probe_ffprobe_keys() {
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || return 1
}

probe_ffmpeg_parse() {
  ffmpeg -v error -i "$1" -f null - 2>&1 | \
    sed -n 's/.*, \([0-9]\+x[0-9]\+\).*/\1/p' | head -n1 || return 1
}

# Try detectors
WIDTH=""
HEIGHT=""

if size="$(probe_ffprobe_csv "$INPUT_IMAGE" 2>/dev/null || true)"; then
  if [[ -n "$size" && "$size" == *x* ]]; then
    WIDTH="${size%x*}"
    HEIGHT="${size#*x}"
  fi
fi

if [[ -z "$WIDTH" || -z "$HEIGHT" ]]; then
  if size="$(probe_ffprobe_keys "$INPUT_IMAGE" 2>/dev/null || true)"; then
    # ffprobe keyless returns two lines: width then height
    WIDTH="$(echo "$size" | sed -n '1p' | tr -d '\r\n')"
    HEIGHT="$(echo "$size" | sed -n '2p' | tr -d '\r\n')"
  fi
fi

if [[ -z "$WIDTH" || -z "$HEIGHT" ]]; then
  if wh="$(probe_ffmpeg_parse "$INPUT_IMAGE" 2>/dev/null || true)"; then
    if [[ -n "$wh" && "$wh" == *x* ]]; then
      WIDTH="${wh%x*}"
      HEIGHT="${wh#*x}"
    fi
  fi
fi

# Final fallback: ask user to hardcode (script will exit with instruction)
if [[ -z "$WIDTH" || -z "$HEIGHT" ]]; then
  cat >&2 <<EOF
Failed to auto-detect input size. Two options:
- Hardcode WIDTH and HEIGHT values near the top of this script and re-run.
- Run one of these commands and paste the output here so I can adapt:
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1:nokey=1 $INPUT_IMAGE
  ffmpeg -v error -i $INPUT_IMAGE -f null - 2>&1 | sed -n 's/.*, \\([0-9]\\+x[0-9]\\+\\).*/\\1/p'
EOF
  exit 1
fi

echo "Input size: ${WIDTH}x${HEIGHT}"

# Build filtergraph (uses the literal size for color)
FILTER_GRAPH="
[0:v]split=2[in_scroll][in_static];
[in_scroll]tile=2x1[tiled];
[tiled]crop=w=iw/2:h=ih:x='mod(${SCROLL_SPEED}*t, iw/2)':y=0[scroll];
color=s=${WIDTH}x${HEIGHT}:color=black@0[transparent];
[transparent]drawtext=fontfile='${FONT_FILE}':text='${OVERLAY_TEXT}':fontsize=${FONT_SIZE}:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2[mask_rgb];
[mask_rgb]format=gray[mask_gray];
[in_static]format=rgb24[static_rgb];
[static_rgb][mask_gray]alphamerge[text_cutout];
[scroll][text_cutout]overlay=x=0:y=0:format=auto[outv]
"

ffmpeg -y -loop 1 -i "$INPUT_IMAGE" \
  -filter_complex "$FILTER_GRAPH" \
  -map "[outv]" \
  -c:v libx264 -pix_fmt yuv420p -t "$DURATION" \
  "$OUTPUT_FILE"

echo "Done!"

