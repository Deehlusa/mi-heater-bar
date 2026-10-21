#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="build/MiHeaterBar.app"
BUNDLE_ID="${BUNDLE_ID:-io.github.mi-heater-bar}"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MiHeaterBar "$APP/Contents/MacOS/MiHeaterBar"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>MiHeaterBar</string>
    <key>CFBundleExecutable</key>
    <string>MiHeaterBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Controlar o aquecedor Xiaomi na rede local.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/MiHeaterBar.app"
    cp -R "$APP" "$HOME/Applications/"
fi
