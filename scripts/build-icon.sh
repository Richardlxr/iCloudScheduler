#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
iconset_path="$project_root/dist/AppIcon.iconset"
mkdir -p "$iconset_path"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$project_root/Resources/AppIcon.png" --out "$iconset_path/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$project_root/Resources/AppIcon.png" --out "$iconset_path/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_path" -o "$project_root/Resources/AppIcon.icns"
echo "$project_root/Resources/AppIcon.icns"
