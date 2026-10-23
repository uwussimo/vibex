#!/bin/sh
# Builds the AppIcon asset catalog and README icon from docs/icon-art.png.
set -eu
cd "$(dirname "$0")/.."
SET=Vibex/Resources/Assets.xcassets/AppIcon.appiconset
swift scripts/render-icon.swift docs/icon-art.png docs/icon-1024.png
mkdir -p "$SET"
rm -f "$SET"/*.png
for size in 16 32 128 256 512; do
  sips -z $size $size docs/icon-1024.png --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double docs/icon-1024.png --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 256 256 docs/icon-1024.png --out docs/icon.png >/dev/null
cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "icon set written to $SET"
