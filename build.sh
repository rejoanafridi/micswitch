#!/bin/zsh
# Builds MicSwitch.app next to this script.
set -e
cd "${0:A:h}"

APP=MicSwitch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MicSwitch</string>
    <key>CFBundleIdentifier</key><string>dev.rejoan.micswitch</string>
    <key>CFBundleExecutable</key><string>MicSwitch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.3</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 rejoanafridi. MIT License.</string>
</dict>
</plist>
PLIST

# Universal binary: Apple Silicon + Intel.
SOURCES=(main.swift HUD.swift SetupGuide.swift AutoMode.swift DriverInstaller.swift)
FRAMEWORKS=(-framework Cocoa -framework CoreAudio -framework Carbon -framework ServiceManagement)
TMP=$(mktemp -d)
for arch in arm64 x86_64; do
    swiftc -O -target $arch-apple-macos12.0 "${SOURCES[@]}" -o "$TMP/MicSwitch-$arch" "${FRAMEWORKS[@]}"
done
lipo -create "$TMP/MicSwitch-arm64" "$TMP/MicSwitch-x86_64" -output "$APP/Contents/MacOS/MicSwitch"
rm -rf "$TMP"
codesign --force -s - "$APP"
echo "Built $PWD/$APP"
