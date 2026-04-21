#!/bin/bash
# winbind-watchdog.sh — detect hung winbind idmap/trust state and recover.
#
# Symptoms this handles:
#   - smbd logging "check_account: Failed to convert SID ... to a UID"
#   - `wbinfo -t` returning WBC_ERR_WINBIND_NOT_AVAILABLE while `wbinfo -p`
#     and `wbinfo -P` still report healthy (winbindd is alive but wedged on
#     idmap_ad / trust credential operations, often after DC maintenance or
#     machine password rotation).
#
# Recovery sequence (the probe that works without requiring full winbind
# state to be valid is `wbinfo -t`):
#   1. pkill -9 winbindd           — force-kill hung workers
#   2. kinit -k $MACHINE_PRINCIPAL — refresh Kerberos ticket from keytab
#   3. systemctl restart winbind   — clean start

set -u

LOG="/var/log/winbind-watchdog.log"
CONF="/etc/winbind-watchdog.conf"

# Defaults (override via $CONF)
PROBE_TIMEOUT=10
PROBE_CMD=(wbinfo -t)
RECOVERY_GRACE=3
MACHINE_PRINCIPAL=""   # auto-detected if empty
REALM=""               # auto-detected from /etc/krb5.conf if empty
DRY_RUN=0

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

log() { printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }

auto_detect_principal() {
    [[ -n "$MACHINE_PRINCIPAL" ]] && return 0
    local realm="$REALM"
    if [[ -z "$realm" && -r /etc/krb5.conf ]]; then
        realm=$(awk '/^[[:space:]]*default_realm[[:space:]]*=/ { print $3; exit }' /etc/krb5.conf)
    fi
    if [[ -z "$realm" ]]; then
        log "ERROR: cannot determine Kerberos realm (set REALM or MACHINE_PRINCIPAL in $CONF)"
        return 1
    fi
    local host_upper
    host_upper=$(hostname -s | tr '[:lower:]' '[:upper:]')
    MACHINE_PRINCIPAL="${host_upper}\$@${realm}"
    return 0
}

probe() {
    timeout "$PROBE_TIMEOUT" "${PROBE_CMD[@]}" >/dev/null 2>&1
}

recover() {
    log "recovery: starting (principal=$MACHINE_PRINCIPAL)"
    if (( DRY_RUN )); then
        log "DRY_RUN: would run pkill -9 winbindd; kinit -k $MACHINE_PRINCIPAL; systemctl restart winbind"
        return 0
    fi

    pkill -9 winbindd 2>/dev/null || true
    sleep 2

    if kinit -k "$MACHINE_PRINCIPAL" >>"$LOG" 2>&1; then
        log "recovery: kinit ok"
    else
        log "recovery: kinit FAILED (will still attempt winbind restart)"
    fi

    if systemctl restart winbind >>"$LOG" 2>&1; then
        log "recovery: winbind restarted"
    else
        log "recovery: systemctl restart winbind FAILED"
        return 1
    fi

    sleep "$RECOVERY_GRACE"
    return 0
}

main() {
    auto_detect_principal || exit 2

    if probe; then
        exit 0
    fi
    log "probe failed: '${PROBE_CMD[*]}' did not return success within ${PROBE_TIMEOUT}s"

    recover || { log "recovery: aborted"; exit 1; }

    if probe; then
        log "recovery: succeeded — winbind is healthy again"
        exit 0
    fi

    log "recovery: FAILED — probe still failing after restart (manual intervention required)"
    exit 1
}

main "$@"
