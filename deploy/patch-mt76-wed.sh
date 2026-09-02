#!/bin/sh
# Enables WED (Wireless Ethernet Dispatch) for MediaTek Filogic Wi-Fi
# (mt7915e driver: MT7981/MT7986): offloaded wireless flows are forwarded
# by the ethernet<->WLAN hardware path instead of the CPU. The switch is a
# module parameter, so the change only takes effect on the next boot — the
# driver is already loaded when this runs. A sysupgrade or a kmod-mt7915e
# upgrade brings the stock modules.d file back, so keep it in the boot
# sequence (@boot in deploy.conf) to re-apply. Idempotent, safe to re-run.
set -eu

MOD_FILE=/etc/modules.d/mt7915e
OPT='wed_enable=Y'

log() {
    logger -t wed-patch "$*"
    echo "$*" >&2
}

[ -f "$MOD_FILE" ] || { log "ERROR: $MOD_FILE not found (kmod-mt7915e not installed?)"; exit 1; }

# WED only helps when hardware flow offload is on — without it no flow ever
# reaches the HW path. Warn, do not touch the firewall config here.
if [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" != 1 ]; then
    log "WARNING: firewall flow_offloading_hw is not enabled; WED needs hardware flow offload"
fi

if ! grep -q "$OPT" "$MOD_FILE"; then
    sed -i "s/^mt7915e.*/mt7915e $OPT/" "$MOD_FILE"
    # Verify before claiming success: a silently failed sed must not pass
    grep -q "$OPT" "$MOD_FILE" || { log "ERROR: patching $MOD_FILE failed"; exit 1; }
    log "wed_enable=Y added to $MOD_FILE"
fi

# Report whether the running driver actually has WED on
RUNTIME=$(cat /sys/module/mt7915e/parameters/wed_enable 2>/dev/null || echo unknown)
if [ "$RUNTIME" = Y ]; then
    log "WED active"
else
    log "WED patched but not active yet (runtime: $RUNTIME) - reboot required"
fi
