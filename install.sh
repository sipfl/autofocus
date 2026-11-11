#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

swift build -c release
app="$HOME/Applications/AutoFocus.app"
pkill -x AutoFocus 2>/dev/null || true
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/AutoFocus" "$app/Contents/MacOS/"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.autofocus</string>
  <key>CFBundleName</key><string>AutoFocus</string>
  <key>CFBundleExecutable</key><string>AutoFocus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - --identifier local.autofocus "$app"
open "$app"
echo "installed: $app"
