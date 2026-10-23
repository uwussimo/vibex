#!/bin/sh
# Builds a universal (arm64 + x86_64) Vibex.app in Release, bundles universal simslim and XcodeGen,
# signs everything, and packs a DMG.
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

# Bundled tools, pinned. Built or downloaded fresh so both architectures are included
# (Homebrew bottles are arm64-only).
SIMSLIM_VERSION=0.12.2
XCODEGEN_VERSION=2.46.0
ARCHS="arm64 x86_64"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: $1 is required ($2)" >&2; exit 1; }; }
need xcodegen "brew install xcodegen"
need go "brew install go (builds simslim for both architectures)"

# Fails unless the binary contains every architecture in $ARCHS.
universal() {
  for arch in $ARCHS; do
    lipo "$1" -verify_arch "$arch" 2>/dev/null || { echo "error: $1 is missing $arch" >&2; exit 1; }
  done
}

echo "==> Vibex $VERSION, signing with $IDENTITY"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Building Release"
./scripts/fetch-icons.sh >/dev/null
xcodegen generate >/dev/null
xcodebuild -project Vibex.xcodeproj -scheme Vibex -configuration Release \
  -derivedDataPath "$DERIVED" -skipPackagePluginValidation ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO build 2>&1 \
  | grep -E "^/.*(error|warning):|^\*\* BUILD" | grep -v SourcePackages || true
cp -R "$DERIVED/Build/Products/Release/Vibex.app" "$APP"
universal "$APP/Contents/MacOS/Vibex"

echo "==> Bundling tools"
TOOLS=$APP/Contents/Resources/tools
mkdir -p "$TOOLS/bin" "$TOOLS/share" "$TOOLS/licenses"
WORK=$OUT/tools-src
mkdir -p "$WORK"

echo "    simslim $SIMSLIM_VERSION (from source)"
git clone -q --depth 1 --branch "v$SIMSLIM_VERSION" https://github.com/MobAI-App/simslim "$WORK/simslim" 2>/dev/null
for arch in $ARCHS; do
  goarch=$arch; [ "$arch" = x86_64 ] && goarch=amd64
  (cd "$WORK/simslim" && CGO_ENABLED=0 GOOS=darwin GOARCH=$goarch go build -trimpath \
    -ldflags "-s -w -X main.version=$SIMSLIM_VERSION" -o "../simslim-$arch" ./cmd/simslim)
done
lipo -create -output "$TOOLS/bin/simslim" $(for arch in $ARCHS; do echo "$WORK/simslim-$arch"; done)
cp "$WORK/simslim/LICENSE" "$TOOLS/licenses/simslim-LICENSE.txt"

echo "    XcodeGen $XCODEGEN_VERSION (release zip)"
curl -fsSL "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" -o "$WORK/xcodegen.zip"
unzip -q "$WORK/xcodegen.zip" -d "$WORK"
cp "$WORK/xcodegen/bin/xcodegen" "$TOOLS/bin/xcodegen"
cp -R "$WORK/xcodegen/share/xcodegen" "$TOOLS/share/xcodegen"
cp "$WORK/xcodegen/LICENSE" "$TOOLS/licenses/xcodegen-LICENSE.txt"
rm -rf "$WORK"
universal "$TOOLS/bin/simslim"
universal "$TOOLS/bin/xcodegen"
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
