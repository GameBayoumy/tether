#!/bin/bash
# Builds Tether and packages it as build/Tether.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Tether.app"
VERSION="0.1.0"

cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Tether"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tether"

# OpenXR runtime for Unity Play mode / Unreal VR Preview, with its loader manifest.
swift build -c release --product TetherOpenXR
mkdir -p "$APP/Contents/Resources/openxr"
cp "$(swift build -c release --show-bin-path)/libTetherOpenXR.dylib" "$APP/Contents/Resources/openxr/"
cat > "$APP/Contents/Resources/openxr/tether_openxr.json" <<JSON
{
    "file_format_version": "1.0.0",
    "runtime": {
        "name": "Tether",
        "library_path": "./libTetherOpenXR.dylib"
    }
}
JSON

ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tether</string>
    <key>CFBundleDisplayName</key><string>Tether</string>
    <key>CFBundleIdentifier</key><string>io.dashxr.Tether</string>
    <key>CFBundleExecutable</key><string>Tether</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign with a stable identity so macOS privacy grants (Screen Recording, Accessibility) survive rebuilds.
# Ad-hoc signatures change with every build, which makes macOS forget the grant.
IDENTITY="${TETHER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Contents/Resources/openxr/libTetherOpenXR.dylib"
    codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP/Contents/Resources/openxr/libTetherOpenXR.dylib"
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (privacy permissions will need re-granting after each rebuild)"
fi
echo "Built $APP"
