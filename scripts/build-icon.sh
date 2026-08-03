#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
resources_root="$repository_root/Resources"
iconset="$resources_root/AppIcon.iconset"
source_png="$resources_root/CodexCoveIcon-1024.png"
generator_binary="$repository_root/.build/codex-cove-icon-generator"
module_cache="$repository_root/.build/icon-module-cache"

mkdir -p "$repository_root/.build" "$module_cache"
swiftc \
    -module-cache-path "$module_cache" \
    "$repository_root/scripts/generate-icon.swift" \
    -o "$generator_binary"
"$generator_binary" "$source_png"

rm -rf "$iconset"
mkdir -p "$iconset"

sips -z 16 16 "$source_png" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$source_png" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$source_png" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$source_png" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$source_png" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$source_png" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$source_png" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$source_png" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$source_png" --out "$iconset/icon_512x512.png" >/dev/null
cp -f "$source_png" "$iconset/icon_512x512@2x.png"

iconutil -c icns "$iconset" -o "$resources_root/AppIcon.icns"
printf '%s\n' "$resources_root/AppIcon.icns"
