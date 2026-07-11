#!/bin/sh
# Hard-resets the modem by pulsing its reset GPIO. smstools3 is stopped
# first so it does not talk to a half-dead device mid-reset; starting it
# back is left to a separate script once the modem is up again. Runs on
# the device.
set -eu

TAG=modem-reset
GPIO=/sys/class/gpio/modem_reset/value
HOLD=10      # seconds to keep the reset line asserted

log() {
    logger -t "$TAG" "$*"
    echo "$*" >&2
}

[ -w "$GPIO" ] || { log "ERROR: $GPIO not found or not writable"; exit 1; }

# Stop smstools3 while the modem goes away
SMS=/etc/init.d/smstools3
if [ -x "$SMS" ] && "$SMS" status 2>/dev/null | grep -q running; then
    log "stopping smstools3"
    "$SMS" stop
fi

log "resetting modem (holding reset for ${HOLD}s)"
echo 1 > "$GPIO"
# Whatever happens below, never leave the reset line asserted — that would
# keep the modem dead until a reboot
trap 'echo 0 > "$GPIO" 2>/dev/null || :' EXIT
sleep "$HOLD"
echo 0 > "$GPIO"
trap - EXIT

log "modem reset done"
