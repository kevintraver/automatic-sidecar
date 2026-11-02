#!/bin/zsh
# Build auto-sidecar and run it at login as a LaunchAgent.
set -euo pipefail
cd "${0:A:h}"

BIN="$HOME/.local/bin/auto-sidecar"
LABEL="com.kevintraver.auto-sidecar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "${BIN:h}" "${PLIST:h}"
clang -fobjc-arc -O2 -framework Foundation -framework IOKit auto-sidecar.m -o "$BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>watch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/auto-sidecar.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
# bootout returns before the old agent is gone; bootstrap fails with an I/O error until it is
while launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; do sleep 0.1; done
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Installed. Logs: ~/Library/Logs/auto-sidecar.log"
