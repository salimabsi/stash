#!/bin/bash
# Usage: ./build.sh            build build/Stash.app
#        ./build.sh install    also copy it to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Stash.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Stash "$APP/Contents/MacOS/Stash"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "Stash Local Signing" --identifier com.salimabsi.stash "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Stash || true
    rm -rf /Applications/Stash.app
    cp -R "$APP" /Applications/Stash.app
    open /Applications/Stash.app
    echo "Installed to /Applications/Stash.app"
fi
