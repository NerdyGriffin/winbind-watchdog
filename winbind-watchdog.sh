#!/bin/bash
# winbind-watchdog.sh — detect hung winbind idmap/trust state and recover.
#
# Symptoms this handles:
#   - Mode 1 — wedged trust state: `wbinfo -t` returns WBC_ERR_WINBIND_NOT_AVAILABLE
#     while `wbinfo -p` and `wbinfo -P` still report healthy (winbindd is alive
#     but wedged on idmap_ad / trust credential operations, often after DC
#     maintenance or machine-password rotation). smbd logs
#     "check_account: Failed to convert SID ... to a UID".
#   - Mode 2 — idmap_ad LDAP path silently broken while RPC stays green:
#     `wbinfo -t` succeeds but `getent passwd 'DOMAIN\user'` and `wbinfo -i`
#     hang or return empty. Trigger seen in the wild: cached machine-account
#     TGT expired without auto-renewal; winbind kept passing the RPC trust
#     check but couldn't bind LDAP for SID→UID mapping. smbd logs
#     "check_account: Failed to find local account with UID NNNN" and
#     "add_local_groups: getpwuid(NNNN) failed, is nsswitch configured?".
#
# Recovery sequence:
#   1. pkill -9 winbindd           — force-kill hung workers
#   2. kinit -k $MACHINE_PRINCIPAL — refresh Kerberos ticket from keytab
#   3. systemctl restart winbind   — clean start
#
# Mode 1 is detected by `wbinfo -t`. Mode 2 requires a second probe against
# a known-resolvable AD account — see IDMAP_PROBE_USER.

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
# Optional second probe — exercises full nsswitch (idmap_ad → LDAP). Set to
# a known-resolvable AD account (e.g. 'NERDYGRIFFIN\christian.admin') to
# catch mode-2 failures where wbinfo -t passes but SID→UID lookups hang.
# Empty (default) = disabled, behaves like 1.0.x.
IDMAP_PROBE_USER=""

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

# Second probe — only runs if IDMAP_PROBE_USER is configured. Returns:
#   0  healthy (or not configured, or inconclusive misconfig — see below)
#   1  wedged (timeout)
#
# Behaviour on inconclusive results (rc != 124, but rc != 0 or empty stdout):
# log a warning and return 0. This handles the case where IDMAP_PROBE_USER
# is misspelled or the account was removed — that is a config problem, not a
# winbind wedge, and we don't want to recovery-loop on it.
probe_idmap() {
    [[ -z "$IDMAP_PROBE_USER" ]] && return 0
    local out rc
    out=$(timeout "$PROBE_TIMEOUT" getent passwd "$IDMAP_PROBE_USER" 2>>"$LOG")
    rc=$?
    if (( rc == 124 )); then
        log "idmap probe TIMEOUT: 'getent passwd $IDMAP_PROBE_USER' did not return within ${PROBE_TIMEOUT}s"
        return 1
    fi
    if (( rc != 0 )) || [[ -z "$out" ]]; then
        log "idmap probe inconclusive (rc=$rc, empty_output=$([[ -z "$out" ]] && echo yes || echo no)) — check IDMAP_PROBE_USER='$IDMAP_PROBE_USER'; treating as healthy to avoid recovery loop on config issue"
        return 0
    fi
    return 0
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

    local primary_ok=0 idmap_ok=0
    probe && primary_ok=1
    probe_idmap && idmap_ok=1
    if (( primary_ok && idmap_ok )); then
        exit 0
    fi

    if (( ! primary_ok )); then
        log "primary probe failed: '${PROBE_CMD[*]}' did not return success within ${PROBE_TIMEOUT}s"
    fi
    if (( ! idmap_ok )); then
        log "idmap probe failed (see prior log line for details)"
    fi

    recover || { log "recovery: aborted"; exit 1; }

    primary_ok=0; idmap_ok=0
    probe && primary_ok=1
    probe_idmap && idmap_ok=1
    if (( primary_ok && idmap_ok )); then
        log "recovery: succeeded — winbind is healthy again"
        exit 0
    fi

    log "recovery: FAILED — probes still failing after restart (primary=$primary_ok idmap=$idmap_ok); manual intervention required"
    exit 1
}

main "$@"
