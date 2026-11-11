#!/bin/zsh
# Builds Smudge.app next to this script.
set -e
cd "$(dirname "$0")"
APP="Smudge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -Ounchecked -swift-version 5 main.swift -o "$APP/Contents/MacOS/Smudge"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Smudge</string>
  <key>CFBundleIdentifier</key><string>local.joke.smudge</string>
  <key>CFBundleName</key><string>Smudge</string>
  <key>CFBundleDisplayName</key><string>Smudge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
xattr -cr "$APP"
codesign --force -s - "$APP"
echo "Built $APP"
