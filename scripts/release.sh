#!/bin/sh
# Builds Vibex.app in Release, bundles simslim and XcodeGen, signs everything, and packs a DMG.
# Usage: scripts/release.sh            (version comes from project.yml)
#        SIGN_IDENTITY=<sha1|name> scripts/release.sh
set -eu
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -1)
IDENTITY=${SIGN_IDENTITY:-$(sed -n 's/^ *CODE_SIGN_IDENTITY: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -1)}
OUT=build/release
DERIVED=$OUT/DerivedData
APP=$OUT/Vibex.app
DMG=$OUT/Vibex-$VERSION.dmg

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: $1 is required ($2)" >&2; exit 1; }; }
need xcodegen "brew install xcodegen"
need simslim "brew install mobai-app/tap/simslim"

echo "==> Vibex $VERSION, signing with $IDENTITY"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Building Release"
xcodegen generate >/dev/null
xcodebuild -project Vibex.xcodeproj -scheme Vibex -configuration Release \
  -derivedDataPath "$DERIVED" -skipPackagePluginValidation build 2>&1 \
  | grep -E "^/.*(error|warning):|^\*\* BUILD" | grep -v SourcePackages || true
cp -R "$DERIVED/Build/Products/Release/Vibex.app" "$APP"

echo "==> Bundling tools"
TOOLS=$APP/Contents/Resources/tools
mkdir -p "$TOOLS/bin" "$TOOLS/share" "$TOOLS/licenses"
SIMSLIM=$(brew --prefix simslim 2>/dev/null || dirname "$(dirname "$(command -v simslim)")")
XCODEGEN=$(brew --prefix xcodegen 2>/dev/null || dirname "$(dirname "$(command -v xcodegen)")")
cp "$SIMSLIM/bin/simslim" "$TOOLS/bin/simslim"
cp "$XCODEGEN/bin/xcodegen" "$TOOLS/bin/xcodegen"
cp -R "$XCODEGEN/share/xcodegen" "$TOOLS/share/xcodegen"
cp "$SIMSLIM/LICENSE" "$TOOLS/licenses/simslim-LICENSE.txt"
cp "$XCODEGEN/LICENSE" "$TOOLS/licenses/xcodegen-LICENSE.txt"
SIMSLIM_VERSION=$("$TOOLS/bin/simslim" --version 2>/dev/null | head -1 || echo unknown)
XCODEGEN_VERSION=$("$TOOLS/bin/xcodegen" --version 2>/dev/null | head -1 || echo unknown)
cat > "$TOOLS/licenses/README.txt" <<NOTICE
Vibex bundles these MIT-licensed tools. Copies you install yourself take precedence.

simslim ($SIMSLIM_VERSION)  https://github.com/MobAI-App/simslim
XcodeGen ($XCODEGEN_VERSION)  https://github.com/yonaskolb/XcodeGen
NOTICE

echo "==> Signing (inside out)"
ENTITLEMENTS=$OUT/entitlements.plist
codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null
# Development signing adds get-task-allow (debugger attach); a release must not carry it.
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENTITLEMENTS" 2>/dev/null || true
for tool in "$TOOLS/bin/"*; do
  codesign --force --options runtime --sign "$IDENTITY" "$tool"
done
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
"$TOOLS/bin/xcodegen" --version >/dev/null
"$TOOLS/bin/simslim" --help >/dev/null

echo "==> Packing $DMG"
STAGE=$OUT/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Vibex $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" "$DMG"
rm -rf "$STAGE"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
