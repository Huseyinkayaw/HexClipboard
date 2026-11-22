#!/bin/bash
# HexClipboard.app'i derler, yerel (ad-hoc) olarak imzalar ve /Applications'a kurar.
#   ./build.sh               → derle + kur
#   ./build.sh --no-install  → yalnızca derle
#   ./build.sh --test        → test sürümü (build-test/, otomatik testler dahil; kurulmaz)
#   ./build.sh --dmg         → derle + dist/HexClipboard.dmg kurulum dosyasını hazırla (kurmaz)
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"
FLAGS=()
OUT="build"
if [[ "$MODE" == "--test" ]]; then FLAGS=(-D HEXTEST); OUT="build-test"; fi
APP="$OUT/HexClipboard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O ${FLAGS[@]+"${FLAGS[@]}"} -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/HexClipboard" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# İzinler her derlemede sıfırlanmasın diye imza kuralı paket kimliğine bağlanır.
codesign --force --sign - -r='designated => identifier "local.hexclipboard.app"' "$APP"
echo "Derlendi: $(pwd)/$APP"

if [[ "$MODE" == "--test" || "$MODE" == "--no-install" ]]; then exit 0; fi

if [[ "$MODE" == "--dmg" ]]; then
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  mkdir -p dist
  rm -f dist/HexClipboard.dmg
  hdiutil create -volname "HexClipboard" -srcfolder "$STAGE" -ov -format UDZO dist/HexClipboard.dmg >/dev/null
  rm -rf "$STAGE"
  echo "Kurulum dosyası: $(pwd)/dist/HexClipboard.dmg"
  exit 0
fi

pkill -x HexClipboard 2>/dev/null || true
rm -rf /Applications/HexClipboard.app
cp -R "$APP" /Applications/HexClipboard.app
echo "Kuruldu: /Applications/HexClipboard.app"
