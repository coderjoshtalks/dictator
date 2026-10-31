#!/bin/zsh
# Packages dist/Dictator.app into dist/Dictator-<version>.dmg for sharing.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE=$(mktemp -d)/Dictator
mkdir -p "$STAGE"
cp -R dist/Dictator.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/INSTALL.txt "$STAGE/How to install.txt"
DMG="dist/Dictator-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Dictator $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
[[ -n "${SIGN_IDENTITY:-}" ]] && codesign --force --sign "$SIGN_IDENTITY" "$DMG"
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
