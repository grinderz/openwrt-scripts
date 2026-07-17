#!/bin/sh
# Removes the hardcoded POWERDOWNFLAG line from /etc/init.d/nut-monitor: with
# that flag in the generated upsmon.conf a master upsmon writes
# /var/run/killpower during a low-battery shutdown and orders the UPS to cut
# output power. Runs on the device; idempotent, exits silently when
# nut-monitor is not installed. A package upgrade brings the stock init
# script back — keep it in the boot sequence (@boot@keep in deploy.conf) to
# re-apply. rc.local runs after the init scripts, so the service is restarted
# to regenerate its config whenever the file actually changes.
set -eu

F=/etc/init.d/nut-monitor
PATTERN='echo "POWERDOWNFLAG /var/run/killpower"'

log() {
    logger -t nut-monitor-patch "$*"
    echo "$*" >&2
}

[ -f "$F" ] || exit 0               # package not installed
grep -qF "$PATTERN" "$F" || exit 0  # already patched

sed -i '/echo "POWERDOWNFLAG \/var\/run\/killpower"/d' "$F"
# Verify before restarting: a silently failed sed must not pass as patched
if grep -qF "$PATTERN" "$F"; then
    log "ERROR: patching $F failed"
    exit 1
fi

# Pick up the change if the service already started with the stock config
if "$F" running 2>/dev/null; then
    "$F" restart || log "WARNING: nut-monitor restart failed"
fi

log "POWERDOWNFLAG removed from nut-monitor init script"
