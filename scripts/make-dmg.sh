#!/bin/zsh
# Builds a Release OriCmd.app (universal, ad-hoc signed) and packs it into
# build/OriCmd-<version>.dmg with an Applications link for drag-and-drop install.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(xcodebuild -project OriCmd.xcodeproj -target OriCmd -configuration Release -showBuildSettings 2>/dev/null \
  | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
WORK=build/release
rm -rf "$WORK"

echo "Building OriCmd $VERSION…"
xcodebuild -project OriCmd.xcodeproj -scheme OriCmd -configuration Release \
  -derivedDataPath "$WORK/DerivedData" ONLY_ACTIVE_ARCH=NO build \
  | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"

APP="$WORK/DerivedData/Build/Products/Release/OriCmd.app"
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/OriCmd"
lipo -archs "$APP/Contents/XPCServices/OriCmdHighlighter.xpc/Contents/MacOS/OriCmdHighlighter"

STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/OriCmd.app"
ln -s /Applications "$STAGE/Applications"

DMG="build/OriCmd-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "OriCmd $VERSION" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
echo "Created $DMG"
