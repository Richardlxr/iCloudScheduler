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
framework_source="$project_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$application_path/Contents/Frameworks"
ditto "$framework_source" "$application_path/Contents/Frameworks/Sparkle.framework"
install -m 644 "$project_root/.build/checkouts/Sparkle/LICENSE" "$application_path/Contents/Resources/Sparkle-LICENSE"
cp "$binary_directory/iCloudScheduler" "$application_path/Contents/MacOS/iCloudScheduler"
cp "$project_root/Resources/Info.plist" "$application_path/Contents/Info.plist"
if [[ -f "$project_root/Resources/AppIcon.icns" ]]; then
  cp "$project_root/Resources/AppIcon.icns" "$application_path/Contents/Resources/AppIcon.icns"
fi
# Preserve Sparkle's upstream signatures for ad-hoc builds. Hardened runtime otherwise
# rejects a framework signed by another team when the host has no signing team.
app_entitlements="$project_root/Resources/iCloudScheduler.entitlements"
if [[ "${SIGNING_IDENTITY:--}" == "-" ]]; then
  app_entitlements="$project_root/Resources/iCloudScheduler-adhoc.entitlements"
  echo "Local ad-hoc build: permissions may be requested again after replacement. Use a stable Developer ID Application identity for public updates." >&2
else
  framework="$application_path/Contents/Frameworks/Sparkle.framework/Versions/B"
  for nested in "$framework/XPCServices/Downloader.xpc" "$framework/XPCServices/Installer.xpc" "$framework/Autoupdate" "$framework/Updater.app" "$application_path/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --preserve-metadata=entitlements "$nested"
  done
fi
codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime --entitlements "$app_entitlements" "$application_path"
codesign --verify --deep --strict "$application_path"
echo "$application_path"
