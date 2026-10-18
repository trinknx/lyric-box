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
# macOS screen saver (Lyric Box.saver): same engine, fed by the app. Built with swiftc
# because SwiftPM can't produce a loadable bundle.
S=Sources/LyricBox
SAVER_SRC=("$S/Models.swift" "$S/LRC.swift" "$S/Flow.swift" "$S/Constellation.swift" "$S/WordZoom.swift"
           "$S/Ambient.swift" "$S/Scene.swift" "$S/SaverBridge.swift" "Saver/LyricBoxSaverView.swift")
OBJ=build/saver-obj
mkdir -p "$OBJ"
for arch in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -module-name LyricBoxSaver -target "$arch-apple-macos13.0" -swift-version 5 \
    -Xlinker -bundle -framework ScreenSaver -framework QuartzCore -framework AppKit \
    -o "$OBJ/LyricBoxSaver-$arch" "${SAVER_SRC[@]}"
done
SAVER="build/Lyric Box.saver"
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
lipo -create "$OBJ/LyricBoxSaver-arm64" "$OBJ/LyricBoxSaver-x86_64" -output "$SAVER/Contents/MacOS/LyricBoxSaver"
cp Saver/Info.plist "$SAVER/Contents/Info.plist"
cp -R Resources/Fonts "$SAVER/Contents/Resources/Fonts"
codesign --force --sign - "$SAVER"
cp -R "$SAVER" "$APP/Contents/Resources/"

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
