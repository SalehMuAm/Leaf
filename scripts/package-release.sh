#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ $# -gt 0 ]]; then
  echo "Usage: scripts/package-release.sh" >&2
  echo "Optional: LEAF_SIGN_IDENTITY and LEAF_NOTARY_PROFILE (see docs/RELEASING.md)." >&2
  exit 2
fi

if [[ -n "${LEAF_NOTARY_PROFILE:-}" && "${LEAF_SIGN_IDENTITY:--}" == - ]]; then
  echo "Notarization requires LEAF_SIGN_IDENTITY to name a Developer ID Application identity." >&2
  exit 2
fi

./scripts/build-app.sh
app_path="$PWD/dist/Leaf.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
architecture="$(lipo -archs "$app_path/Contents/MacOS/Leaf")"
case "$architecture" in
  arm64|x86_64) ;;
  *) echo "Expected a single host architecture; got: $architecture" >&2; exit 1 ;;
esac
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Unexpected app version: $version" >&2
  exit 1
fi

archive_name="Leaf-$version-macos-$architecture.zip"
stage_dir="$(mktemp -d "$PWD/dist/.leaf-release.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
archive_path="$stage_dir/$archive_name"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"

if [[ -n "${LEAF_NOTARY_PROFILE:-}" ]]; then
  # Credentials stay in Keychain; this script takes only the saved profile name.
  report_path="$stage_dir/notarization.json"
  if ! xcrun notarytool submit "$archive_path" \
      --keychain-profile "$LEAF_NOTARY_PROFILE" --wait --output-format json > "$report_path"; then
    cat "$report_path" >&2
    exit 1
  fi
  if [[ "$(plutil -extract status raw -o - "$report_path")" != Accepted ]]; then
    cat "$report_path" >&2
    echo "Notarization was not accepted; no new release archive was produced." >&2
    exit 1
  fi
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  # ZIP files cannot be stapled. Recreate the archive from the stapled app.
  rm "$archive_path"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
fi

codesign --verify --deep --strict "$app_path"
unzip -tq "$archive_path"
(
  cd "$stage_dir"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
  shasum -a 256 -c "$archive_name.sha256"
)
mv "$archive_path" "$PWD/dist/$archive_name"
mv "$stage_dir/$archive_name.sha256" "$PWD/dist/$archive_name.sha256"
echo "Packaged $PWD/dist/$archive_name"
echo "Checksum $PWD/dist/$archive_name.sha256"
if [[ "${LEAF_SIGN_IDENTITY:--}" == - ]]; then
  echo "Ad hoc beta build: this archive is not Developer ID signed or notarized."
elif [[ -z "${LEAF_NOTARY_PROFILE:-}" ]]; then
  echo "Signed build: notarization was not requested."
else
  echo "Developer ID signed and notarized; the app includes a stapled ticket."
fi
