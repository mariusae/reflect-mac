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
# Chronicle, for the reader: the owner's, when fetch-fonts.sh found it.
cp Frameworks/hoefler/ChronicleSSm-*.otf "$app/Contents/Resources/Fonts/" 2>/dev/null || true
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

# The GitHub App Prism signs in through: the iPhone's, from the file kept
# beside its xcconfig and never committed. Read here, never printed.
github_config=iOS/GitHub.local.xcconfig
github_value() {
  [ -f "$github_config" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$github_config" | tail -1 | sed 's/[[:space:]]*$//'
}
GITHUB_CLIENT_ID=$(github_value GITHUB_CLIENT_ID)
GITHUB_CLIENT_SECRET=$(github_value GITHUB_CLIENT_SECRET)
GITHUB_APP_SLUG=$(github_value GITHUB_APP_SLUG)
# The sync relay (worker/): its host, once deployed.
SYNC_RELAY_HOST=$(github_value SYNC_RELAY_HOST)

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
	<key>GitHubClientID</key><string>$GITHUB_CLIENT_ID</string>
	<key>GitHubClientSecret</key><string>$GITHUB_CLIENT_SECRET</string>
	<key>GitHubAppSlug</key><string>$GITHUB_APP_SLUG</string>
	<key>SyncRelayHost</key><string>$SYNC_RELAY_HOST</string>
	<key>NSCalendarsFullAccessUsageDescription</key><string>Prism shows today’s meetings over today’s note, and makes each a note with when it is and who is in it.</string>
	<key>NSMicrophoneUsageDescription</key><string>Prism listens while you hold the dictation key, to write down what you say.</string>
	<key>NSSpeechRecognitionUsageDescription</key><string>Offline, Prism writes down what you say with the Mac’s own speech recognition.</string>
</dict>
</plist>
PLIST
# From macOS 26 the icon is Icon Composer's (Resources/Icons/Prism.icon,
# drawn by the same script): the cards as layers on the paper, which the
# system draws light, dark, clear or tinted as Appearance ▸ Icon & widget
# style asks — compiled by Xcode's actool into Assets.car, the bundle
# naming it (CFBundleIconName). Without Xcode, PrismIcon.icns stays.
if [ scripts/make-prism-icon.swift -nt Resources/Icons/Prism.icon/icon.json ]; then
  swift scripts/make-prism-icon.swift --icon Resources/Icons/Prism.icon
fi
rm -f "$app/Contents/Resources/Assets.car"
# (absolute paths: actool's helper may not run where we are)
if xcrun actool "$PWD/Resources/Icons/Prism.icon" --compile "$(cd "$app/Contents/Resources" && pwd)" --app-icon Prism \
     --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist "$PWD/build/icon-partial.plist" >/dev/null 2>&1 \
   && [ -f "$app/Contents/Resources/Assets.car" ]; then
  rm -f "$app/Contents/Resources/Prism.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string Prism" "$app/Contents/Info.plist"
fi
# The Finder and the Dock cache a bundle's icon by its path: the bundle
# is touched and registered again so a new icon shows at the next launch.
touch "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" >/dev/null 2>&1 || true

codesign --force --sign - "$app" >/dev/null 2>&1
echo "built $app"

if [ "$1" = run ]; then
  pkill -x Prism 2>/dev/null || true
  open "$app"
fi
