#!/bin/sh
# Builds Vibex/Resources/Icons.xcassets from Untitled UI's free icons (@untitledui/icons on npm).
# Their license allows using the icons in apps but not redistributing them, so the icons stay out of
# git: this downloads the package and converts only the icons listed in scripts/icons.txt.
set -eu
cd "$(dirname "$0")/.."
VERSION=0.0.23
CACHE=build/icons/untitledui-icons-$VERSION
OUT=Vibex/Resources/Icons.xcassets
if [ ! -d "$CACHE/package" ]; then
  mkdir -p "$CACHE"
  (cd "$CACHE" && npm pack "@untitledui/icons@$VERSION" --silent >/dev/null && tar -xzf "untitledui-icons-$VERSION.tgz")
fi
python3 -I scripts/convert-icons.py "$CACHE/package/dist" scripts/icons.txt "$OUT"
