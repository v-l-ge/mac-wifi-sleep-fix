# Troubleshooting

Common issues with `mac-wifi-sleep-fix` and how to address them.

## How to read the log

All wake events are recorded in `/var/log/sleepwatcher.log`. Each wake should
look like one of these patterns:

### Auto recovery (good — most common)
```
wakeup: start
wakeup: waiting 3s before bringing up Wi-Fi
wakeup: networksetup on (initial)
wakeup: smart polling up to 30s (need 5s stable)
wakeup: auto-recovery OK, IP 192.168.X.Y stable 5s — exit
```
Recovery time: typically 10–25 seconds.

### Cascade recovery (occasional — handled automatically)
```
wakeup: ...
wakeup: no stable auto-recovery in 30s, starting cascade
wakeup: networksetup off (try 1)
wakeup: networksetup on + airport -z (try 1)
wakeup: SUCCESS — IP 192.168.X.Y after networksetup try 1
```
Recovery time: typically 30–50 seconds. This is normal and expected for
some wakes; the cascade is the heart of this fix.

### FAILED (rare — manual reboot needed)
```
wakeup: cascade exhausted, killall airportd + bluetoothd
wakeup: starting patient stage (3 retries, 20s interval)
wakeup: FAILED — driver in deep hung state, manual reboot required
```
This is a kernel-level Broadcom driver deadlock that cannot be cleared from
userland. **Reboot the Mac** (Apple menu → Restart).

## "Wi-Fi icon is crossed out and cascade isn't helping"

This is **deep hung state** — the driver is stuck in a kernel-level deadlock
where `networksetup` and `airport -z` commands have no effect. The Wi-Fi icon
stays in its disabled state through the entire cascade.

**Why this happens:** macOS does not allow userland processes to force-reload
the SIP-protected `com.apple.driver.AirPort.BrcmNIC` kext. There is no way
for any script to revive the driver from this state.

**Solution:** Reboot the Mac.

**Frequency:** In our testing, ~5–10% of long sleeps (>5 hours). Rare on
short sleeps. May correlate with prior system instability (e.g., a recent
WindowServer crash), but this is not conclusive.

## "Cascade happens too often"

Some cascade is expected — the Broadcom driver occasionally enters a
hung-on-association state regardless of how cleanly we shut down before sleep.
Typical rate: 5–25% of wakes, varying by network conditions and sleep duration.

Things to check on **your network** (not the fix itself):

1. **DHCP pool size** — if your router's DHCP pool is exhausted (too few
   addresses for all your devices), some clients may not get a lease and
   fall back to other DHCP sources. Expand the pool in router admin.

2. **Lease time** — short lease times (e.g., 2 hours) cause `INIT-REBOOT`
   to fail at wake after a long sleep, forcing a full `DISCOVER`. This
   doubles the DHCP transaction time. Set lease time to 1+ days in router
   admin.

3. **Dual DHCP servers** — if your ISP modem and your router are both
   serving DHCP on the same L2 segment (common in "double-NAT" setups),
   they compete. Symptom: Mac sometimes gets an IP from the wrong subnet.
   Fix: put one device in bridge mode, or place the modem's cable into the
   router's **WAN** port (not LAN).

4. **Congested Wi-Fi channel** — many neighbors on the same 2.4 GHz channel
   slow association. Run Apple's Wireless Diagnostics (Option-click the
   Wi-Fi icon → Open Wireless Diagnostics) and check its channel
   recommendation.

5. **IPv6 timeouts** — if your router does not provide IPv6 but macOS keeps
   trying, each wake wastes 3–6 seconds on Router Solicitation timeouts.
   In System Settings → Network → Wi-Fi → Details → TCP/IP, set
   Configure IPv6 to **Link-local only**.

## "The Wi-Fi icon takes ~7 seconds to start searching after I open the lid"

This is the macOS IOPM hook delivery latency — sleepwatcher (a userland
daemon) cannot receive the wake event faster than macOS chooses to deliver
it. Typical lag is 4–10 seconds, varies by system load. Not something this
fix can change.

## "Battery drains while sleeping"

The fix configures `hibernatemode 25` which writes the RAM image to disk on
every sleep and powers off the chip. Battery loss during hibernation should
be approximately **0% per hour**.

If you see significant drain (>1% per hour):
- Check for assertions: `pmset -g log | grep PreventSystemSleep` around your
  sleep windows.
- Make sure Power Nap is off: `pmset -g | grep powernap` should show `0`.
- Make sure DarkWake background tasks are off: this is set by `install.sh`
  via `pmset -a darkwakes 0`.

## Uninstalling

Run `./uninstall.sh` from the repository directory. It will:
- Stop and remove the LaunchDaemon.
- Remove user hooks (`~/.sleep`, `~/.wakeup`).
- Remove the wrapper script.
- Revert `pmset` settings to macOS defaults.

It will **not** remove the `sleepwatcher` Homebrew package (you may have
installed it for other reasons). To remove it: `brew uninstall sleepwatcher`.

## Reporting issues

If you're consistently seeing FAILED or have unusual patterns, please open
an issue on GitHub with:
- macOS version (`sw_vers -productVersion`).
- Mac model (Apple menu → About This Mac).
- Wi-Fi chip (`system_profiler SPAirPortDataType | head -20`).
- Excerpt from `/var/log/sleepwatcher.log` showing the problematic wake(s).
- `pmset -g custom` output.
