#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
application_path="$project_root/dist/iCloudScheduler.app"
codesign --verify --strict "$application_path"
release_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$application_path/Contents/Info.plist")"
release_arch="$(lipo -archs "$application_path/Contents/MacOS/iCloudScheduler")"
case "$release_arch" in
  "arm64 x86_64"|"x86_64 arm64") release_arch="universal" ;;
  arm64|x86_64) ;;
  *) echo "Unsupported binary architectures: $release_arch" >&2; exit 1 ;;
esac
archive_name="iCloudScheduler-${release_version}-macos-${release_arch}.zip"
ditto -c -k --sequesterRsrc --keepParent "$application_path" "$project_root/dist/$archive_name"
cd "$project_root/dist"
shasum -a 256 "$archive_name" > SHA256SUMS
echo "$project_root/dist/$archive_name"
