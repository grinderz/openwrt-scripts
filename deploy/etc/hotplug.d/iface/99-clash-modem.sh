#!/bin/sh
# Hotplug hook: (re)start clash when the modem interface comes up. Clash
# fetches rule-providers and subscriptions on start, so wait for real
# internet access first — ifup alone does not mean the uplink works yet.
# The wait runs in the background: hotplug handlers must not block other
# events. No set -e: hotplug scripts are sourced by hotplug-call, not
# executed. Deployed to /etc/hotplug.d/iface/ (add @keep in deploy.conf
# so it survives sysupgrade).

TAG=clash-hotplug
IFACE=modem
PING_HOST=77.88.8.8   # something outside the tunnel that answers pings
TRIES=15
INTERVAL=2
LOCK=/tmp/.clash-hotplug.lock

[ "${ACTION:-}" = ifup ] && [ "${INTERFACE:-}" = "$IFACE" ] || exit 0

# One waiter at a time: a flapping interface must not pile up clash restarts
mkdir "$LOCK" 2>/dev/null || {
    logger -t "$TAG" "$IFACE up again, a waiter is already running - skipping"
    exit 0
}

logger -t "$TAG" "$IFACE up - waiting for connectivity to start clash"

(
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    i=0
    while [ "$i" -lt "$TRIES" ]; do
        if ping -c 1 -W 2 -q "$PING_HOST" >/dev/null 2>&1; then
            /etc/init.d/clash restart
            logger -t "$TAG" "clash started"
            exit 0
        fi
        i=$((i + 1))
        sleep "$INTERVAL"
    done
    logger -t "$TAG" "$IFACE up but no connectivity after $((TRIES * INTERVAL))s - clash not started"
) &
