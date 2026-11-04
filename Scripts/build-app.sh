#!/usr/bin/env bash
# Builds "Capture Pro.app" and a distributable zip in ./dist.
#   VERSION=1.0.0 SIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/Capture Pro.app"

echo "→ Compiling (release)…"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/CapturePro"
  echo "  universal binary"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/CapturePro"
  echo "  native binary ($(uname -m))"
fi

echo "→ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CapturePro"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift Scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"

echo "→ Signing…"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --entitlements Resources/CapturePro.entitlements -s "$SIGN_IDENTITY" "$APP"
else
  # Ad-hoc signature with an explicit designated requirement on the bundle identifier, so macOS
  # privacy permissions (Screen Recording, Camera…) survive rebuilds and updates instead of being
  # tied to one build's hash.
  codesign --force -s - --requirements '=designated => identifier "io.github.virajdas.capturepro"' "$APP"
fi

mkdir -p dist
ZIP="dist/CapturePro-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $APP"
echo "✓ $ZIP"
