#!/bin/bash
# Build "Lyric Box.app" (universal: Apple Silicon + Intel). Pass --dmg to also make a disk image.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/LyricBox"

APP="build/Lyric Box.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LyricBox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
codesign --force --sign - "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--dmg" ]]; then
  DMG="build/Lyric Box.dmg"
  rm -f "$DMG"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Lyric Box" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "Built $DMG ($(du -sh "$DMG" | cut -f1))"
fi
