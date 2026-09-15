#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
application_path="$project_root/dist/iCloudScheduler.app"
codesign --verify --strict "$application_path"
# TCC and Keychain identify an app through its designated code requirement.
# Ad-hoc signatures change identity on every build, even with the same bundle ID.
signing_details="$(codesign --display --verbose=4 "$application_path" 2>&1)"
if [[ "$signing_details" != *"Authority=Developer ID Application:"* ]]; then
  if [[ "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]]; then
    echo "Public updates require Developer ID Application signing to preserve app identity." >&2
    echo "Rebuild with SIGNING_IDENTITY; ALLOW_ADHOC_RELEASE=1 is only for explicitly accepted unsigned distribution." >&2
    exit 1
  fi
  echo "WARNING: this archive does not preserve privacy/Keychain authorization across updates." >&2
fi
release_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$application_path/Contents/Info.plist")"
release_arch="$(lipo -archs "$application_path/Contents/MacOS/iCloudScheduler")"
case "$release_arch" in
  "arm64 x86_64"|"x86_64 arm64") release_arch="universal" ;;
  arm64|x86_64) ;;
  *) echo "Unsupported binary architectures: $release_arch" >&2; exit 1 ;;
esac
archive_name="iCloudScheduler-${release_version}-macos-${release_arch}.zip"
dmg_name="iCloudScheduler-${release_version}-macos-${release_arch}.dmg"
ditto -c -k --sequesterRsrc --keepParent "$application_path" "$project_root/dist/$archive_name"
# Only this task-created staging directory is disposable. The .app and archives are deliverables.
dmg_stage="$(mktemp -d "$project_root/dist/dmg-staging.XXXXXX")"
cleanup() {
  case "$dmg_stage" in
    "$project_root"/dist/dmg-staging.*) [[ -d "$dmg_stage" && ! -L "$dmg_stage" ]] && rm -rf -- "$dmg_stage" ;;
  esac
}
trap cleanup EXIT
ditto "$application_path" "$dmg_stage/iCloudScheduler.app"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create -volname "iCloudScheduler $release_version" -srcfolder "$dmg_stage" -format UDZO -ov "$project_root/dist/$dmg_name"
hdiutil verify "$project_root/dist/$dmg_name"
cd "$project_root/dist"
shasum -a 256 "$dmg_name" "$archive_name" > SHA256SUMS
echo "$project_root/dist/$dmg_name"
echo "$project_root/dist/$archive_name"
