#!/bin/bash
#
# Uninstaller for mac-wifi-sleep-fix.
#
# Removes scripts, LaunchDaemon, and reverts pmset settings to defaults.
# Does NOT uninstall sleepwatcher (you may use it for other purposes).

set -e

log() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!! %s\033[0m\n" "$*"; }

if [ "$EUID" -eq 0 ]; then
    echo "Run as a normal user, not root."
    exit 1
fi

log "Caching sudo credentials"
sudo -v

log "Stopping and removing LaunchDaemon"
sudo launchctl bootout system /Library/LaunchDaemons/local.sleepwatcher.plist 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/local.sleepwatcher.plist

log "Removing wrapper script"
sudo rm -f /usr/local/sbin/sleepwatcher-wrapper.sh

log "Removing user hooks"
rm -f "$HOME/.sleep" "$HOME/.wakeup"

log "Reverting pmset settings to macOS defaults"
sudo pmset -a hibernatemode 3
sudo pmset -a tcpkeepalive 1
sudo pmset -a darkwakes 1

log "Killing any remaining sleepwatcher processes"
sudo pkill -f sleepwatcher-wrapper 2>/dev/null || true
sudo pkill -x sleepwatcher 2>/dev/null || true

cat <<EOF

==> Uninstall complete.

NOT removed (intentionally):
  - sleepwatcher (Homebrew package; remove manually if you wish: brew uninstall sleepwatcher)
  - /var/log/sleepwatcher.log (kept for reference)

To restore log file removal:
  sudo rm /var/log/sleepwatcher.log
EOF
