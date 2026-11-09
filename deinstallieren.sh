#!/bin/sh
# Entfernt JumpBass Revived vollständig (Alternative zu "Deinstallieren …" in der App).
# Aufruf: ./deinstallieren.sh
ID=io.github.jumpbassrevived
APP="/Applications/JumpBass Revived.app"
pkill -x JumpBassRevived 2>/dev/null
sleep 1
# Anmeldeobjekt (ab macOS 13 über SMAppService) abmelden, solange die App noch da ist
[ -x "$APP/Contents/MacOS/JumpBassRevived" ] && "$APP/Contents/MacOS/JumpBassRevived" --unregister-login
rm -rf "$APP"
rm -f "$HOME/Library/LaunchAgents/$ID.plist"
defaults delete "$ID" 2>/dev/null
rm -f "$HOME/Library/Preferences/$ID.plist"
tccutil reset All "$ID" >/dev/null 2>&1
echo "JumpBass Revived wurde entfernt."
