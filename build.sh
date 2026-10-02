#!/bin/sh
# Usage: [VERSION=x.y.z] ./build.sh [install]
set -eu
cd "$(dirname "$0")"

APP=build/MyPRs.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f AppIcon.icns ] || { swift icon.swift && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns; }
cp AppIcon.icns "$APP/Contents/Resources/"

swiftc -parse-as-library -O -swift-version 6 -target arm64-apple-macos14 \
  -o "$APP/Contents/MacOS/MyPRs" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MyPRs</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.danielsellers.myprs</string>
  <key>CFBundleName</key><string>My PRs</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-1.0}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

if [ "${1:-}" = install ]; then
  rm -rf "$HOME/Applications/MyPRs.app"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/MyPRs.app"
else
  echo "Built $APP"
fi
