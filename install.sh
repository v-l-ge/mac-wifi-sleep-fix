#!/bin/bash
#
# Installer for mac-wifi-sleep-fix.
#
# Installs:
#   - sleepwatcher (via Homebrew)
#   - ~/.sleep and ~/.wakeup (user-level hooks)
#   - /usr/local/sbin/sleepwatcher-wrapper.sh (with $HOME substituted)
#   - /Library/LaunchDaemons/local.sleepwatcher.plist (system daemon)
#
# Applies system settings via pmset:
#   - hibernatemode 25 (full hibernation on every sleep)
#   - tcpkeepalive 0   (no TCP keepalive during sleep; disables Find My Mac wake)
#   - darkwakes 0      (suppress background DarkWake tasks)
#
# Run as your normal user (not root). The script will use sudo as needed
# and will prompt for password.

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG=/var/log/sleepwatcher.log

# --- Pre-flight checks ---

log() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!! %s\033[0m\n" "$*"; }
fail() { printf "\033[1;31m!! %s\033[0m\n" "$*"; exit 1; }

log "Pre-flight checks"

# Not root
if [ "$EUID" -eq 0 ]; then
    fail "Run as a normal user, not root. The script will call sudo when needed."
fi

# macOS
if [ "$(uname -s)" != "Darwin" ]; then
    fail "This is a macOS-only tool."
fi

# Intel
if [ "$(uname -m)" != "x86_64" ]; then
    fail "Apple Silicon Macs use a different Wi-Fi chip; this fix is for Intel Macs with Broadcom."
fi

# macOS version (Monterey 12.x or Big Sur 11.x; later versions untested)
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_MAJOR" -gt 12 ]; then
    warn "macOS $(sw_vers -productVersion) is newer than tested (11/12). Proceeding, but YMMV."
fi

# Homebrew
if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew is required. Install from https://brew.sh first."
fi

# Wi-Fi chip is Broadcom
if ! system_profiler SPNetworkDataType 2>/dev/null | grep -i broadcom >/dev/null; then
    warn "Could not detect Broadcom Wi-Fi. This fix may not apply to your hardware."
    read -p "Continue anyway? (y/N) " ans
    [ "$ans" = "y" ] || fail "Aborted."
fi

log "Caching sudo credentials"
sudo -v

# --- Backup existing config ---

BACKUP_DIR="/tmp/wifi-fix-backup-$(date +%Y%m%d-%H%M%S)"
log "Backing up existing config to $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
pmset -g custom > "$BACKUP_DIR/pmset-before.txt"
for f in "$HOME/.sleep" "$HOME/.wakeup" /usr/local/sbin/sleepwatcher-wrapper.sh; do
    [ -f "$f" ] && cp "$f" "$BACKUP_DIR/" || true
done

# --- Install sleepwatcher ---

log "Installing sleepwatcher via Homebrew"
if ! brew list sleepwatcher >/dev/null 2>&1; then
    brew install sleepwatcher
else
    log "sleepwatcher already installed"
fi

# --- pmset settings ---

log "Applying pmset settings (hibernatemode 25, tcpkeepalive 0, darkwakes 0)"
sudo pmset -a hibernatemode 25
sudo pmset -a tcpkeepalive 0
sudo pmset -a darkwakes 0

# --- Install user-level scripts ---

log "Installing ~/.sleep and ~/.wakeup"
install -m 700 "$REPO_DIR/scripts/sleep" "$HOME/.sleep"
install -m 700 "$REPO_DIR/scripts/wakeup" "$HOME/.wakeup"

# --- Install wrapper (with $HOME substituted) ---

log "Installing /usr/local/sbin/sleepwatcher-wrapper.sh"
sudo mkdir -p /usr/local/sbin
sed "s|{{HOME}}|$HOME|g" "$REPO_DIR/scripts/sleepwatcher-wrapper.sh" \
    | sudo tee /usr/local/sbin/sleepwatcher-wrapper.sh >/dev/null
sudo chmod 755 /usr/local/sbin/sleepwatcher-wrapper.sh
sudo chown root:wheel /usr/local/sbin/sleepwatcher-wrapper.sh

# --- Install LaunchDaemon ---

log "Installing /Library/LaunchDaemons/local.sleepwatcher.plist"
sudo install -m 644 -o root -g wheel \
    "$REPO_DIR/plist/local.sleepwatcher.plist" \
    /Library/LaunchDaemons/local.sleepwatcher.plist

# --- Ensure log file exists with right permissions ---

log "Preparing $LOG"
sudo touch "$LOG"
sudo chmod 644 "$LOG"
sudo chown root:wheel "$LOG"

# --- Load LaunchDaemon ---

log "Loading LaunchDaemon"
# bootout may fail with EIO if not loaded; that's harmless.
sudo launchctl bootout system /Library/LaunchDaemons/local.sleepwatcher.plist 2>/dev/null || true
sleep 1
sudo launchctl bootstrap system /Library/LaunchDaemons/local.sleepwatcher.plist
sleep 5

# --- Verify ---

log "Verifying installation"
if pgrep -fl sleepwatcher-wrapper >/dev/null && pgrep -xl sleepwatcher >/dev/null; then
    log "Sleepwatcher running successfully"
else
    warn "Sleepwatcher processes not found — check $LOG"
fi

cat <<EOF

==> Installation complete.

Test the fix:
  1. Close the lid and let the Mac sleep.
  2. Wait at least 30 minutes (or overnight for a long sleep).
  3. Open the lid.
  4. Check the log:   tail -30 $LOG

Expected wake events look like:
  wakeup: start
  wakeup: waiting 3s before bringing up Wi-Fi
  wakeup: networksetup on (initial)
  wakeup: smart polling up to 30s (need 5s stable)
  wakeup: auto-recovery OK, IP X.X.X.X stable 5s — exit

If you see "starting cascade" — that's the fix doing its job for hung-on-association.
If you see "FAILED — driver in deep hung state" — manual reboot is required (rare).

Backup of previous config is in: $BACKUP_DIR
To uninstall: ./uninstall.sh
EOF
