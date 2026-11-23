#!/bin/bash
# Builds IsolaPonte.app (release, ad-hoc signed).
#   ./build-app.sh            → mac/IsolaPonte/IsolaPonte.app
#   ./build-app.sh --install  → also copies it to /Applications (closing the running copy)
# Build and signing happen outside iCloud Drive (~/Library/Caches/isola-build/ponte): iCloud adds
# extended attributes that codesign refuses. The copy next to this script is just for convenience.
set -euo pipefail

cd "$(dirname "$0")"
HERE="$(pwd)"
SCRATCH="${PONTE_SCRATCH:-$HOME/Library/Caches/isola-build/ponte}"
APP="$SCRATCH/app/IsolaPonte.app"
VERSION="0.1.0"

echo "→ swift build (release)"
swift build -c release --product IsolaPonte --scratch-path "$SCRATCH"
BIN="$(swift build -c release --product IsolaPonte --scratch-path "$SCRATCH" --show-bin-path)/IsolaPonte"

echo "→ IsolaPonte.app"
rm -rf "$APP"
mkdir -p "$(dirname "$APP")" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/IsolaPonte"

ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN" --disegna-icona "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>it.isola.ponte</string>
	<key>CFBundleName</key>
	<string>Isola Ponte</string>
	<key>CFBundleDisplayName</key>
	<string>Isola Ponte</string>
	<key>CFBundleExecutable</key>
	<string>IsolaPonte</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>it</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Isola</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Isola Ponte scambia gli appunti con il tuo PC Windows attraverso Tailscale.</string>
</dict>
</plist>
PLIST

echo "→ codesign (ad-hoc)"
codesign --force --sign - --identifier it.isola.ponte "$APP"
codesign --verify --strict "$APP"
rm -rf "$HERE/IsolaPonte.app"
ditto --noextattr --noqtn "$APP" "$HERE/IsolaPonte.app"
echo "✓ $HERE/IsolaPonte.app"

if [[ "${1:-}" == "--install" ]]; then
	echo "→ /Applications/IsolaPonte.app"
	if pkill -x IsolaPonte >/dev/null 2>&1; then sleep 1; fi
	rm -rf /Applications/IsolaPonte.app
	ditto --noextattr --noqtn "$APP" /Applications/IsolaPonte.app
	codesign --verify --strict /Applications/IsolaPonte.app
	echo "✓ installata. Avvio: open /Applications/IsolaPonte.app"
fi
