# mac-wifi-sleep-fix

Automated recovery for the Broadcom WiFi "hung-on-association" bug on Intel
Macs after wake from sleep.

If your old Intel Mac (especially MacBook Air/Pro 2014–2017 on Monterey or
Big Sur) refuses to reconnect to Wi-Fi after a long sleep and requires a
reboot to recover — this fix is for you.

## The problem

After a long sleep (typically 5+ hours), the Broadcom BCM43xx Wi-Fi driver
can enter one of two stuck states on wake:

1. **Hung-on-association** — the chip formally associates with the AP
   (SSID and BSSID look correct in `ifconfig`), but no actual traffic flows.
   ARP probes to the router time out. DHCP `INIT-REBOOT` succeeds in setting
   an IP but is then NAK'd, and `DISCOVER` retries hang.

2. **Deep hung** — the kernel driver enters a deadlock state where
   `networksetup -setairportpower en0 on` returns success at the script level
   but the Wi-Fi chip never actually powers up. The menu-bar icon stays
   crossed out. No userland command can revive the driver from this state.

The first state can be cleared by forcing a clean re-association. The second
state requires a reboot.

Apple has not fixed this on Intel Macs in macOS 12 Monterey, and is unlikely
to ship a fix for older Macs going forward.

## What this fix does

A `sleepwatcher`-driven shell script runs on every wake event:

1. **Waits 3 seconds** to let the chip and system finish hibernate-restore.
2. **Brings up the interface** with `networksetup -setairportpower en0 on`.
3. **Issues `airport -z`** (force disassociate) — the key command that
   breaks the chip out of the hung-on-association state by forcing a
   clean scan + new association.
4. **Smart polling** for up to 30 seconds, requiring 5 consecutive seconds
   of stable IP before declaring success. (This filter rejects transient
   leases that get DHCP-NAK'd and disappear.)
5. **Cascade**: if polling fails, up to 15 cycles of
   `off → on + airport -z`, separated by 10-second pauses. This forcibly
   re-initializes the chip's association state.
6. **Killall airportd + bluetoothd**, then one more cycle.
7. **Patient stage**: 3 more attempts with 20-second pauses.

If none of those stages produces a working IP, the script logs FAILED —
this is the deep-hung case, and only a reboot helps.

Before sleep, a separate script powers down the chip cleanly with a 5-second
pause to ensure the hibernate image captures a clean, off-state chip — which
reduces the frequency of hung-on-association on wake.

The `airport -z` (force disassociate) is the critical command. Common
WiFi-reconnect scripts use only `networksetup off/on`, which does not break
the hung-on-association state. `airport` is a private framework binary at
`/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport`
and is rarely seen in published scripts.

## Requirements

- **Intel Mac** with Broadcom Wi-Fi (BCM43xx series). Apple Silicon Macs
  have a different chip and don't need this fix.
- **macOS Monterey 12 or Big Sur 11**. Newer versions are untested.
- **Homebrew** installed (for `sleepwatcher`).
- **Administrator account** (uses `sudo` for `pmset` and LaunchDaemon).

## Installation

```sh
git clone https://github.com/v-l-ge/mac-wifi-sleep-fix.git
cd mac-wifi-sleep-fix
./install.sh
```

The installer will:
- Install `sleepwatcher` via Homebrew.
- Apply `pmset` settings (`hibernatemode 25`, `tcpkeepalive 0`, `darkwakes 0`).
- Copy `~/.sleep` and `~/.wakeup` hooks.
- Install `/usr/local/sbin/sleepwatcher-wrapper.sh`.
- Install and load `/Library/LaunchDaemons/local.sleepwatcher.plist`.
- Back up any existing config to `/tmp/wifi-fix-backup-<timestamp>/`.

To verify after install:
```sh
tail -30 /var/log/sleepwatcher.log
```

## Test

Close the lid, leave the Mac asleep for at least 30 minutes (longer is
better for triggering the bug), then open it. Watch the menu-bar Wi-Fi
icon — it should reconnect automatically within ~15–30 seconds.

Check the log:
```sh
tail -30 /var/log/sleepwatcher.log
```

You should see something like:
```
wakeup: start
wakeup: waiting 3s before bringing up Wi-Fi
wakeup: networksetup on (initial)
wakeup: smart polling up to 30s (need 5s stable)
wakeup: auto-recovery OK, IP 192.168.x.y stable 5s — exit
```

## Recovery statistics

Tested on MacBook Air 2015 (MacBookAir7,2), Monterey 12.7.6, with
Broadcom BCM4350 Wi-Fi. Sample: 165 wake events over ~5 weeks of daily
use, including 11 long sleeps of 5+ hours (one up to 28 hours).

| Outcome | Frequency | Recovery time |
|---|---|---|
| AUTO recovery | ~75–80% | 10–25 sec |
| CASCADE recovery (force disassociate cycles) | ~15–20% | 30–50 sec |
| Deep hung (manual reboot required) | ~5–10% | — |

**Sleeps up to 28 hours** have been recovered cleanly. **Battery loss
during hibernation is approximately 0% per hour** (`hibernatemode 25`
powers everything off).

The most recent 7 days (after pre-sleep timing was tuned to a 5-second
pause and a 3-second post-wake delay) saw **0 cascades** across daily
long sleeps — but a 7-day window is too small to claim that as the
steady-state rate.

These numbers are from a single machine. Your mileage will vary
depending on Wi-Fi chip variant, network conditions, and sleep duration.

## Configuration

If your Wi-Fi recovery is slower or faster than typical, you can tune the
pauses in the installed scripts:

- `~/.sleep` — pause after `networksetup off` (default 5 seconds).
- `~/.wakeup` — pause before `networksetup on` (default 3 seconds).

Empirically, 3–5 seconds is the "saturation" point — longer pauses do not
measurably reduce cascade frequency.

## Known limitations

**Deep hung is unfixable from userland.** macOS does not allow userland
processes to force-reload the SIP-protected `com.apple.driver.AirPort.BrcmNIC`
kext. When the driver enters kernel-level deadlock, the only remedy is a
reboot. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for how to recognize
this case.

**macOS hook delivery latency is ~5–10 seconds.** sleepwatcher cannot
receive the wake event faster than macOS chooses to deliver it. The
"Wi-Fi icon stays crossed out for several seconds after opening the lid"
is mostly this OS-level delay, not the recovery script.

**The fix can be sensitive to network conditions** (small DHCP pool, short
lease time, dual-DHCP setups, IPv6 misconfiguration). See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) for diagnostics.

## How does this differ from existing WiFi-reconnect scripts?

Most published scripts simply toggle Wi-Fi off and on via `networksetup`.
This works for trivial cases — when the driver just needs a kick — but
fails on hung-on-association, which requires a force-disassociate command.

This fix adds:
- **`airport -z` force disassociate** — the key command.
- **Cascade loop** with up to 15 attempts and tuned pauses.
- **Smart polling with stability check** that rejects transient leases.
- **Killall + patient stage** as fallback layers.
- **Empirically-tuned pre-sleep pauses** to reduce hung-on-association frequency.
- **Detailed logging** for debugging.

## Uninstalling

```sh
./uninstall.sh
```

Removes scripts, the LaunchDaemon, and reverts `pmset` settings to defaults.
Does not remove `sleepwatcher` (Homebrew package).

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

This fix manipulates low-level networking and system sleep. While I've used
it daily without issue, every Mac is different. Try it on a non-critical
system first if possible. The uninstaller cleanly reverses all changes.
