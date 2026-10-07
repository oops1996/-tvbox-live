#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=3.7.3
ARCHIVE=VLCKit-3.7.3-319ed2c0-79128878.tar.xz
SHA256=019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d
DEPS="${FAMILYTV_DEPS_DIR:-$PWD/.build-deps}"
OUT="${FAMILYTV_OUTPUT_DIR:-$PWD/dist/macos}"
mkdir -p "$DEPS" "$OUT"

if [[ ! -f "$DEPS/$ARCHIVE" ]]; then
  curl --fail --location --retry 4 --connect-timeout 30 --max-time 900 \
    "https://download.videolan.org/pub/cocoapods/prod/$ARCHIVE" -o "$DEPS/$ARCHIVE"
fi
echo "$SHA256  $DEPS/$ARCHIVE" | shasum -a 256 --check
if [[ ! -d "$DEPS/unpacked" ]]; then
  mkdir -p "$DEPS/unpacked"
  tar -xJf "$DEPS/$ARCHIVE" -C "$DEPS/unpacked"
fi
FRAMEWORK=$(find "$DEPS/unpacked" -name VLCKit.framework -type d -print -quit)
[[ -n "$FRAMEWORK" ]] || { echo 'VLCKit.framework missing' >&2; exit 1; }
lipo -verify_arch arm64 "$FRAMEWORK/VLCKit"

APP="$OUT/家庭电视.app"
[[ ! -e "$APP" ]] || { echo "Output already exists: $APP; choose a new FAMILYTV_OUTPUT_DIR" >&2; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp macos/FamilyTV/Info.plist "$APP/Contents/Info.plist"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/VLCKit.framework"
cp macos/FamilyTV/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp macos/FamilyTV/LICENSE-VLCKit.txt "$APP/Contents/Resources/LICENSE-VLCKit.txt"

SWIFT_FLAGS=(-module-cache-path "$DEPS/module-cache")
if [[ -n "${FAMILYTV_SDK_PATH:-}" ]]; then SWIFT_FLAGS+=(-sdk "$FAMILYTV_SDK_PATH"); fi
xcrun swiftc "${SWIFT_FLAGS[@]}" -target arm64-apple-macos13.0 -O \
  macos/FamilyTV/Sources/*.swift -o "$APP/Contents/MacOS/FamilyTV" \
  -F "$APP/Contents/Frameworks" -framework VLCKit \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework SwiftUI -framework AppKit -framework Foundation

# Preserve framework symlinks; validate and sign every bundled native module first.
while IFS= read -r -d '' binary; do
  if file "$binary" | grep -q 'Mach-O'; then
    lipo -verify_arch arm64 "$binary"
    if otool -L "$binary" | awk '/compatibility version/ {print $1}' | grep -E '/opt/homebrew/|/usr/local/|/Users/|/Volumes/' ; then
      echo "Non-portable dependency in $binary" >&2; exit 1
    fi
    codesign --force --sign - "$binary"
  fi
done < <(find "$APP/Contents/Frameworks" -type f -print0)
codesign --force --sign - "$APP/Contents/Frameworks/VLCKit.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo -verify_arch arm64 "$APP/Contents/MacOS/FamilyTV"

# ZIP inside the artifact retains executable bits and framework symlinks.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/家庭电视-macOS-arm64-app.zip"
if [[ "${FAMILYTV_PACKAGE_APP_ONLY:-0}" == 1 ]]; then
  (cd "$OUT" && shasum -a 256 家庭电视-macOS-arm64-app.zip > SHA256SUMS.txt)
  echo "Built arm64 app only (DMG explicitly skipped): $OUT"
  exit 0
fi
STAGING=$(mktemp -d "$OUT/dmg-stage.XXXXXX")
ditto "$APP" "$STAGING/家庭电视.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname '家庭电视' -srcfolder "$STAGING" -format UDZO "$OUT/家庭电视-macOS-arm64.dmg"
(cd "$OUT" && shasum -a 256 家庭电视-macOS-arm64-app.zip 家庭电视-macOS-arm64.dmg > SHA256SUMS.txt)
echo "Built arm64 app and DMG: $OUT"
