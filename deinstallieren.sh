#!/bin/sh
# Entfernt JumpBass Revived vollständig (Alternative zu "Deinstallieren …" in der App).
# Aufruf: ./deinstallieren.sh
ID=io.github.jumpbassrevived
pkill -x JumpBassRevived 2>/dev/null
sleep 1
rm -rf "/Applications/JumpBass Revived.app"
rm -f "$HOME/Library/LaunchAgents/$ID.plist"
defaults delete "$ID" 2>/dev/null
rm -f "$HOME/Library/Preferences/$ID.plist"
tccutil reset All "$ID" >/dev/null 2>&1
echo "JumpBass Revived wurde entfernt."
