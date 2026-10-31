#!/bin/zsh
# Stop the auto-sidecar LaunchAgent and remove its files.
set -euo pipefail

LABEL="com.kevintraver.auto-sidecar"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/auto-sidecar"
echo "Uninstalled. Log left at ~/Library/Logs/auto-sidecar.log"
