#!/bin/sh
# Builds the Safari extension's app, "Prism Capture.app", into build/safari/,
# signed with the team its Xcode project names — its toolbar icon, popup and
# scripts from Extensions/Prism — and opens it once, so Safari takes up the
# new extension. Check it is ticked in Safari ▸ Settings ▸ Extensions.
# `scripts/build-capture.sh --no-open` builds it alone.
set -e
cd "$(dirname "$0")/.."

project="Extensions/Safari/Prism Capture/Prism Capture.xcodeproj"
app="build/safari/Build/Products/Release/Prism Capture.app"

xcodebuild -project "$project" -scheme "Prism Capture" -configuration Release \
  -derivedDataPath build/safari -quiet build
echo "built $app"

[ "$1" = --no-open ] && exit 0
open "$app"
echo "opened it: Safari has the new extension once it is ticked in Settings ▸ Extensions"
