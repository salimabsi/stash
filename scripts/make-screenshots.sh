#!/bin/bash
# Regenerates docs/screenshot.png and docs/menus.png from the sample notes in scripts/screenshots.
# A sample window and its menus flash on screen for a moment while the menus are captured.
# Your own notes are never read or changed; everything runs in a temporary folder.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; defaults delete stash-screenshots >/dev/null 2>&1 || true; rm -f ~/Library/Preferences/stash-screenshots.plist' EXIT

swiftc -O -o "$WORK/stash-screenshots" $(ls Sources/Stash/*.swift | grep -v '/main.swift$') scripts/screenshots/*.swift
STASH_DATA_DIR="$WORK/data" "$WORK/stash-screenshots" docs
