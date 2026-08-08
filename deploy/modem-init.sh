#!/bin/sh
# Per-model USB modem initialization; called from the usb hotplug hook
# (etc/hotplug.d/usb/99-modems) with the hotplug PRODUCT string as $1
# ('vid/pid/rev', lowercase hex without leading zeros).
#
# Model-specific steps:
#   1bc7/1910 (Telit LN940): register the id with qmi_wwan and unbind the
#     <cfg>.2-.4 interfaces from it — they are serial ports, qmi_wwan must
#     keep only the QMI interface
#   1bc7/1900, 413c/81d7, 413c/81d6 (DW5821e): Dell firmware exposes the
#     usable ports only in USB configuration 1; if the device enumerated
#     with configuration 2, switch it over
#
# Every device is then registered with the option usb-serial driver so its
# serial ports appear — that alone is the whole init for the remaining
# INIT_IDS (19d2/1404, 19d2/9994, 5c6/90d5, 5c6/9025, ...).
set -eu

TAG=modem-init
USBDEV=/sys/bus/usb/devices

log() {
    logger -t "$TAG" "$*"
    echo "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

[ $# -eq 1 ] || die "usage: $0 vid/pid[/rev]"
USB=$1

vid=${USB%%/*}
pid=${USB#*/}
pid=${pid%%/*}
# sysfs idVendor/idProduct are zero-padded to 4 hex digits, PRODUCT is not
VID=$(printf '%04x' "0x$vid") || die "bad vid in '$USB'"
PID=$(printf '%04x' "0x$pid") || die "bad pid in '$USB'"

# sysfs name (port) of the first device matching VID:PID; the original
# vendor-only grep could pick another device from the same vendor
find_port() {
    for _d in "$USBDEV"/*; do
        [ -f "$_d/idVendor" ] && [ -f "$_d/idProduct" ] || continue
        [ "$(cat "$_d/idVendor")" = "$VID" ] || continue
        [ "$(cat "$_d/idProduct")" = "$PID" ] || continue
        echo "${_d##*/}"
        return 0
    done
    return 1
}

case $USB in
1bc7/1910/*)
    port=$(find_port) || die "device $VID:$PID not found in sysfs"
    log "telit ln940 ($VID:$PID) on $port: leaving only the QMI interface to qmi_wwan"
    # Registering an already-known id fails with EEXIST — fine here
    echo "$VID $PID" > /sys/bus/usb/drivers/qmi_wwan/new_id 2>/dev/null || :
    # The USB config number <cfg> comes from the first <port>:<cfg>.2 interface
    cfg=
    for _i in "$USBDEV/$port":*.2; do
        [ -e "$_i" ] || continue
        cfg=${_i##*:}
        cfg=${cfg%.2}
        break
    done
    [ -n "$cfg" ] || die "no $port:<cfg>.2 interface in sysfs"
    # .2-.4 are the serial ports; unbind fails harmlessly when not bound
    for _n in 2 3 4; do
        echo "$port:$cfg.$_n" > /sys/bus/usb/drivers/qmi_wwan/unbind 2>/dev/null || :
    done
    ;;
1bc7/1900/*|413c/81d7/*|413c/81d6/*)
    port=$(find_port) || die "device $VID:$PID not found in sysfs"
    cfgfile="$USBDEV/$port/bConfigurationValue"
    if grep -qi dell "$USBDEV/$port/manufacturer" 2>/dev/null \
        && [ "$(cat "$cfgfile")" = 2 ]; then
        log "dw5821e ($VID:$PID) on $port: switching usb configuration 2 -> 1"
        # The config write makes the modem re-enumerate and it can come back
        # with a different pid (81d6 -> 81d7). The sysfs node then vanishes
        # or changes id mid-loop: stop this run — the add event for the new
        # pid runs this script again and finishes the init.
        # Bounded retries instead of the original infinite loop
        tries=0
        while :; do
            if [ "$(cat "$USBDEV/$port/idProduct" 2>/dev/null)" != "$PID" ]; then
                log "$port re-enumerated with a new id - its add event takes over"
                exit 0
            fi
            if [ "$(cat "$cfgfile" 2>/dev/null)" = 1 ]; then
                break
            fi
            [ "$tries" -lt 10 ] || die "$port did not switch to configuration 1"
            tries=$((tries + 1))
            # printf: echo may eat '-1' as a flag; the writes can fail while
            # the device re-enumerates - the next iteration handles that
            { printf '%s\n' -1 > "$cfgfile"; } 2>/dev/null || :
            { printf '%s\n' 1 > "$cfgfile"; } 2>/dev/null || :
            sleep 1
        done
        log "$port is in configuration 1"
    fi
    ;;
esac

log "registering $VID:$PID with the option usb-serial driver"
# Registering an already-known id fails with EEXIST — fine here
echo "$VID $PID" > /sys/bus/usb-serial/drivers/option1/new_id 2>/dev/null || :
