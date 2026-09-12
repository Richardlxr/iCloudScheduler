#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_configuration="${1:-release}"
build_arch="${2:-universal}"
if [[ "$build_configuration" != "release" && "$build_configuration" != "debug" ]]; then
  echo "Usage: scripts/build-app.sh [release|debug] [universal|arm64|x86_64]" >&2
  exit 2
fi
cd "$project_root"
case "$build_arch" in
  universal) architecture_flags=(--arch arm64 --arch x86_64) ;;
  arm64|x86_64) architecture_flags=(--arch "$build_arch") ;;
  *) echo "Unsupported architecture: $build_arch" >&2; exit 2 ;;
esac
swift build -c "$build_configuration" "${architecture_flags[@]}" --product iCloudScheduler
binary_directory="$(swift build -c "$build_configuration" "${architecture_flags[@]}" --show-bin-path)"
application_path="$project_root/dist/iCloudScheduler.app"
mkdir -p "$application_path/Contents/MacOS" "$application_path/Contents/Resources"
cp "$binary_directory/iCloudScheduler" "$application_path/Contents/MacOS/iCloudScheduler"
cp "$project_root/Resources/Info.plist" "$application_path/Contents/Info.plist"
if [[ -f "$project_root/Resources/AppIcon.icns" ]]; then
  cp "$project_root/Resources/AppIcon.icns" "$application_path/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime --entitlements "$project_root/Resources/iCloudScheduler.entitlements" "$application_path"
codesign --verify --strict "$application_path"
echo "$application_path"
