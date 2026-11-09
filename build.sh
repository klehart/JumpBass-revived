#!/bin/sh
# Baut "JumpBass Revived.app" als Universal Binary (Intel ab 10.13, Apple Silicon ab 11.0).
set -e
cd "$(dirname "$0")"
APP="build/JumpBass Revived.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"
FLAGS="-fobjc-arc -O2 -Wall -framework Cocoa -framework CoreAudio -weak_framework ServiceManagement"
clang $FLAGS -arch x86_64 -mmacosx-version-min=10.13 main.m MainWindow.m -o build/x86_64
clang $FLAGS -arch arm64 -mmacosx-version-min=11.0 main.m MainWindow.m -o build/arm64
lipo -create build/x86_64 build/arm64 -output "$APP/Contents/MacOS/JumpBassRevived"
rm build/x86_64 build/arm64
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Mit dem Zertifikat "JumpBass Revived" bleibt die Signatur über Versionen gleich, und macOS behält die
# Freigabe für die Systemaudioaufnahme. Ohne das Zertifikat (fremde Builds) ad-hoc signieren.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"JumpBass Revived"/ { print $2; exit }')
codesign --force --sign "${IDENTITY:--}" "$APP"
[ -n "$IDENTITY" ] && echo "Signiert mit Zertifikat JumpBass Revived" || echo "Ad-hoc signiert (Zertifikat JumpBass Revived nicht gefunden)"
echo "Fertig: $APP"
