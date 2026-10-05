#!/bin/sh
# Builds "Prism.app" into build/, its fonts bundled (scripts/fetch-fonts.sh
# fetches them). `scripts/build-prism.sh run` also launches it.
set -e
cd "$(dirname "$0")/.."

[ -d Frameworks/alegreya ] || scripts/fetch-fonts.sh
swift build -c release --product Prism
app="build/Prism.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fonts"
cp "$(swift build -c release --show-bin-path)/Prism" "$app/Contents/MacOS/Prism"
for family in monasans monaspace recursive gofont literata jetbrainsmono source plex fraunces alegreya lato; do
  cp Frameworks/$family/*.[ot]tf "$app/Contents/Resources/Fonts/"
done
# The icon is drawn by a script, and only redrawn when the script changes.
if [ ! -f build/PrismIcon.icns ] || [ scripts/make-prism-icon.swift -nt build/PrismIcon.icns ]; then
  iconset=build/PrismIcon.iconset
  rm -rf "$iconset" && mkdir -p "$iconset"
  swift scripts/make-prism-icon.swift build/prism-icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/prism-icon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/prism-icon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o build/PrismIcon.icns
fi
cp build/PrismIcon.icns "$app/Contents/Resources/PrismIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Prism</string>
	<key>CFBundleIdentifier</key><string>com.mariusae.Prism</string>
	<key>CFBundleIconFile</key><string>PrismIcon</string>
	<key>CFBundleName</key><string>Prism</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1
echo "built $app"

if [ "$1" = run ]; then
  pkill -x Prism 2>/dev/null || true
  open "$app"
fi
