#!/bin/zsh
# Builds MicSwitch and packages it as dist/MicSwitch-<version>.dmg for sharing.
set -e
cd "${0:A:h}"

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" MicSwitch.app/Contents/Info.plist)
DMG="dist/MicSwitch-$VERSION.dmg"

STAGE=$(mktemp -d)
cp -R MicSwitch.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to install.txt" <<'TXT'
MicSwitch: keep your Bluetooth headset in HD while your mic is off.

INSTALL
1. Drag MicSwitch into the Applications folder.
2. Open MicSwitch from Applications.

FIRST OPEN (one time)
MicSwitch is free and not from the App Store, so macOS blocks it the first time:
1. Open MicSwitch. macOS says it can't be verified. Click "Done".
2. Open System Settings → Privacy & Security.
3. Scroll down to "MicSwitch was blocked…" and click "Open Anyway".
4. Confirm with your password or Touch ID.

AFTER THAT
- Mac without a built-in mic (Mac mini, Studio, Pro)? Click "Install Now" in the
  welcome window to add the free silent-mic driver.
- In Discord / Zoom / Meet set the microphone to "Default".
- Click the headphones icon in the menu bar to turn your mic on/off,
  or right-click it → "Auto" to follow your call app's mute button.

More: https://github.com/rejoanafridi/micswitch
TXT

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "MicSwitch $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Packaged $PWD/$DMG"
