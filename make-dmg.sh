#!/bin/sh
# Baut die App und packt sie in ein DMG zum Verteilen: App + Verknüpfung auf "Programme" zum Hineinziehen.
set -e
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="build/JumpBass-Revived-$VERSION.dmg"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/JumpBass Revived.app" "$STAGE/"
ln -s /Applications "$STAGE/Programme"
hdiutil create -volname "JumpBass Revived $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Fertig: $DMG"
