#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
configuration="${1:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
    echo 'Usage: bash app/build.sh [debug|release]' >&2
    exit 2
fi
swift build --build-system native --arch arm64 -c "$configuration"
binary_dir="$(swift build --build-system native --arch arm64 -c "$configuration" --show-bin-path)"
# MAC-080: the app is presented as Maxplorer; the SwiftPM product keeps its name.
bundle="dist/Maxplorer.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/Explorer" "$bundle/Contents/MacOS/Maxplorer"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
cp -R ThirdPartyNotices "$bundle/Contents/Resources/ThirdPartyNotices"
codesign --force --sign - "$bundle"
echo "Built $PWD/$bundle"
