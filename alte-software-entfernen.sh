#!/bin/sh
# Entfernt die Reste der originalen Twelve South BassJump 3.0.1 Software.
# Aufruf: sudo ./alte-software-entfernen.sh
set -x
launchctl bootout system /Library/LaunchDaemons/com.twelvesouth.bassjump.player.plist 2>/dev/null
rm -rf "/Library/Audio/Plug-Ins/HAL/BassJumpDriver.driver"
rm -rf "/Library/Extensions/BassJumpOverrideDriver.kext"
rm -rf "/System/Library/Extensions/BassJumpOverrideDriver.kext" 2>/dev/null
rm -f  "/Library/LaunchAgents/com.twelvesouth.bassjump.observer.plist"
rm -f  "/Library/LaunchDaemons/com.twelvesouth.bassjump.player.plist"
rm -rf "/Applications/BassJump.app"
rm -rf "/Library/PreferencePanes/BassJump.prefpane"
rm -rf "/Library/Audio/Plug-Ins/HAL/bassJumpAudioBassPlugIn.plugin"
for p in application driver player observer; do pkgutil --forget com.twelvesouth.installer.bassjump.$p 2>/dev/null; done
pkgutil --forget com.twelvesouth.bassjump.installer.overridekext 2>/dev/null
kextcache -i / 2>/dev/null || kmutil clear-staging 2>/dev/null
killall coreaudiod
