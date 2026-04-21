# winbind-watchdog

A systemd timer that periodically probes winbind with `wbinfo -t` and, if the probe fails, runs a targeted recovery sequence. Intended for realm-joined AD member servers (e.g. Samba file servers) where winbindd can silently wedge on `idmap_ad` / trust credential operations — typically after a DC blip or machine-password rotation.

## Why not just `systemctl restart winbind`?

When winbindd is wedged in this state, a plain `systemctl restart` often does not clear it. The Kerberos ticket for the machine account needs to be refreshed from the keytab, and any hung worker processes need to be force-killed first. The documented recovery is:

1. `pkill -9 winbindd`
2. `kinit -k '<HOSTNAME>$@<REALM>'`
3. `systemctl restart winbind`

This package runs exactly that sequence — but only when the probe says it's needed.

## Detection signal

`wbinfo -t` ("check trust secret via RPC") is the most sensitive single probe. It fails with `WBC_ERR_WINBIND_NOT_AVAILABLE` while `wbinfo -p` and `wbinfo -P` still report success — i.e. winbindd is up, the DC is reachable, but the trust state machine is wedged. When this probe fails, downstream SID→UID translations used by smbd (and PAM) also fail.

Symptoms on the host:
- `smbd` logs `check_account: Failed to convert SID ... to a UID` on every connection
- `getent passwd '<DOMAIN>\<user>'` hangs or returns empty
- `sudo` becomes slow (PAM stack blocks on winbind)

## How it works

1. A systemd timer (`winbind-watchdog.timer`) fires every 3 minutes.
2. The timer activates `winbind-watchdog.service` (a oneshot).
3. The service runs `/usr/sbin/winbind-watchdog.sh`, which:
   - Runs `timeout 10 wbinfo -t`.
   - On success: exits 0 silently.
   - On failure: logs, runs the recovery sequence, re-probes, logs the outcome.

## Building the RPM

Requires `rpmbuild` (`dnf install rpm-build`).

```bash
make rpm
```

The built RPM will be at `rpmbuild/RPMS/noarch/winbind-watchdog-1.0.0-1.el8.noarch.rpm`.

## Installation

```bash
sudo ./install.sh
# or directly:
sudo rpm -ivh rpmbuild/RPMS/noarch/winbind-watchdog-*.noarch.rpm
```

The RPM will:
- Install the script to `/usr/sbin/winbind-watchdog.sh`
- Install `winbind-watchdog.service` and `winbind-watchdog.timer` to `/usr/lib/systemd/system/`
- Install logrotate config to `/etc/logrotate.d/winbind-watchdog`
- Create `/etc/winbind-watchdog.conf` with documented defaults
- Enable and start the **timer** (the service is oneshot — only run by the timer)

## Configuration

Edit `/etc/winbind-watchdog.conf` (sourced as bash):

```bash
PROBE_TIMEOUT=10                  # seconds
PROBE_CMD=(wbinfo -t)             # bash array
RECOVERY_GRACE=3                  # seconds after restart before re-probe
MACHINE_PRINCIPAL=""              # auto-detected from hostname + krb5.conf
REALM=""                          # only if default_realm is unset
DRY_RUN=0                         # 1 = log what would happen, don't act
```

The config file is preserved across RPM upgrades (`%config(noreplace)`).

### Auto-detection

If `MACHINE_PRINCIPAL` is unset, the script derives it as:

```
<uppercase hostname -s>$@<default_realm from /etc/krb5.conf>
```

For a host named `hl15-00` joined to `AD.EXAMPLE.COM`, that's `HL15-00$@AD.EXAMPLE.COM`. Override the principal explicitly if the host was joined under a non-default sAMAccountName.

## Logs

- `/var/log/winbind-watchdog.log` — human-readable event log (probe failures, recovery attempts, outcomes)
- `journalctl -u winbind-watchdog.service` — systemd's view

Logs are rotated automatically (10 rotations, 1M max size, compressed).

## Checking status

```bash
# Timer state + last run
systemctl status winbind-watchdog.timer
systemctl list-timers winbind-watchdog.timer

# Recent watchdog activity
tail -30 /var/log/winbind-watchdog.log

# Manual one-shot probe + recovery (safe — same as the timer does)
sudo /usr/sbin/winbind-watchdog.sh

# Dry-run mode: log what recovery would do without acting
echo 'DRY_RUN=1' | sudo tee -a /etc/winbind-watchdog.conf
```

## Uninstallation

```bash
sudo rpm -e winbind-watchdog
```

`/etc/winbind-watchdog.conf` is preserved as `.rpmsave` if modified.

## License

GPL-3.0
