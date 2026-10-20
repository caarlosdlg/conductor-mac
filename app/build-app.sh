#!/usr/bin/env bash
# Empaqueta Conductor.app (no requiere Xcode, sólo Swift de Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
OUT="${1:-$ROOT/dist}"
APP="$OUT/Conductor.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Conductor"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$BIN" "$APP/Contents/MacOS/Conductor"
cp "$ROOT"/src/*.js "$APP/Contents/Resources/engine/"
echo '{"type":"module"}' > "$APP/Contents/Resources/engine/package.json"

ICONSET="$(mktemp -d)/Conductor.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Conductor.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Conductor</string>
  <key>CFBundleDisplayName</key><string>Conductor</string>
  <key>CFBundleIdentifier</key><string>com.carlosdelgado.conductor</string>
  <key>CFBundleExecutable</key><string>Conductor</string>
  <key>CFBundleIconFile</key><string>Conductor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Carpeta de proyecto</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string></array>
  </dict></array>
  <key>NSAppleEventsUsageDescription</key><string>Conductor abre sesiones de Claude en Terminal cuando se lo pides.</string>
</dict></plist>
PLIST

codesign --force --sign - --deep "$APP" 2>&1 | tail -1 || true
echo "✔ $APP"
