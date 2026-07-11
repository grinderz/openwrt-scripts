#!/bin/sh
# Patches the firewall4 ruleset template so flow offload only starts after a
# connection has seen 30 packets: short-lived connections stay on the normal
# path where accounting/QoS still see them, only long flows get offloaded.
# Runs on the device; idempotent, safe to re-run. A sysupgrade brings the
# stock template back, so keep it in the boot sequence (@boot in deploy.conf)
# to re-apply after upgrades.
set -eu

FW_TPL=/usr/share/firewall4/templates/ruleset.uc
RULE='meta l4proto { tcp, udp } flow offload @ft;'
PATCHED='meta l4proto { tcp, udp } ct original packets ge 30 flow offload @ft;'

log() {
    logger -t fw4-patch "$*"
    echo "$*" >&2
}

[ -f "$FW_TPL" ] || { log "ERROR: $FW_TPL not found (firewall4 not installed?)"; exit 1; }

# Already patched — nothing to do
grep -qF "$PATCHED" "$FW_TPL" && exit 0

if ! grep -qF "$RULE" "$FW_TPL"; then
    log "WARNING: offload rule not found in $FW_TPL, patch NOT applied"
    exit 1
fi

sed -i "s/$RULE/$PATCHED/" "$FW_TPL"
# Verify before reloading: a silently failed sed must not pass as patched
grep -qF "$PATCHED" "$FW_TPL" || { log "ERROR: patching $FW_TPL failed"; exit 1; }

fw4 reload || { log "ERROR: fw4 reload failed after patching"; exit 1; }
log "flow offload patch applied"
