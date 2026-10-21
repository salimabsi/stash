#!/bin/bash
# Renders docs/demo.mp4 and docs/demo.gif from scripts/demo/main.swift. Everything is drawn
# offscreen from sample notes in a temporary folder; needs ffmpeg (brew install ffmpeg).
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG=$(command -v ffmpeg) || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; defaults delete stash-demo >/dev/null 2>&1 || true; rm -f ~/Library/Preferences/stash-demo.plist' EXIT

swiftc -swift-version 5 -O -o "$WORK/stash-demo" $(ls Sources/Stash/*.swift | grep -v '/main.swift$') scripts/demo/main.swift
mkdir -p "$WORK/data" docs
STASH_DATA_DIR="$WORK/data" "$WORK/stash-demo" docs/demo.mp4 "$FFMPEG"

"$FFMPEG" -y -loglevel error -i docs/demo.mp4 \
    -vf "fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    docs/demo.gif
ls -lh docs/demo.mp4 docs/demo.gif
