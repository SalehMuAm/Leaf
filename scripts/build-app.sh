#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Leaf requires macOS and Xcode or the Xcode Command Line Tools." >&2
  exit 1
fi

configuration=release
if [[ $# -eq 1 && "$1" == "--debug" ]]; then
  configuration=debug
elif [[ $# -gt 0 ]]; then
  echo "Usage: scripts/build-app.sh [--debug]" >&2
  exit 2
fi

# Keep compiler caches inside the checkout, including in restricted environments.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

# This dependency-free package also builds from an already sandboxed runner.
# Swift builds the host architecture. Release filenames report that architecture.
swift build --disable-sandbox -c "$configuration"
bin_path="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
mkdir -p "$PWD/dist"
stage_dir="$(mktemp -d "$PWD/dist/.leaf-build.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
app_path="$stage_dir/Leaf.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/Leaf" "$app_path/Contents/MacOS/Leaf"
cp Resources/Leaf.icns Resources/LeafMark.png Resources/Welcome.pdf "$app_path/Contents/Resources/"
# Preserve SwiftPM's resource bundle as well as the native app's direct resources.
for bundle in "$bin_path"/*.bundle; do
  if [[ -d "$bundle" ]]; then
    ditto "$bundle" "$app_path/Contents/Resources/$(basename "$bundle")"
  fi
done
if [[ -f LICENSE ]]; then
  cp LICENSE "$app_path/Contents/Resources/LICENSE"
fi

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Leaf</string>
  <key>CFBundleIdentifier</key><string>com.leaf.reader</string>
  <key>CFBundleName</key><string>Leaf</string>
  <key>CFBundleDisplayName</key><string>Leaf</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleShortVersionString</key><string>1.2.1</string>
  <key>CFBundleIconFile</key><string>Leaf</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>PDF document</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    <key>CFBundleTypeExtensions</key><array><string>pdf</string></array>
    <key>CFBundleTypeIconFile</key><string>Leaf</string>
  </dict></array>
</dict>
</plist>
PLIST

plutil -lint "$app_path/Contents/Info.plist"
sign_identity="${LEAF_SIGN_IDENTITY:--}"
if [[ "$sign_identity" == - ]]; then
  codesign --force --sign - "$app_path"
else
  # The identity must already be installed in the local Keychain.
  codesign --force --options runtime --timestamp --sign "$sign_identity" "$app_path"
fi
codesign --verify --deep --strict "$app_path"

# Replace only the generated app, after assembling and verifying a fresh bundle.
rm -rf "$PWD/dist/Leaf.app"
mv "$app_path" "$PWD/dist/Leaf.app"
app_path="$PWD/dist/Leaf.app"
echo "Built $app_path"
echo "Launch with: open \"$app_path\""
