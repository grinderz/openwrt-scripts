#!/bin/sh
# Lists packages installed by the user on a remote OpenWrt device
# (i.e. not part of the stock/flashed image).
#
# Usage:   ./list-user-packages.sh [-v] [-u] [-i] [-b file] [-m mode] [-f filter] [user@]host [ssh options...]
# Example: ./list-user-packages.sh -v -m rom -f top root@192.168.1.1
#
#   -v         verbose output (detection method, counters) to stderr
#   -m mode    comparison method (required):
#                rom   — diff against the package database in /rom (squashfs);
#                        fails if /rom is not available
#                time  — Installed-Time heuristic (opkg only): packages newer
#                        than the firmware build time are considered
#                        user-installed
#                rom-manifest — packages present in the /rom image but absent
#                        from the manifest: what was baked into a custom image
#                        on top of the default package set (implies -u)
#                time+rom-manifest — union of time and rom-manifest: what
#                        changed after flashing plus what was baked into the
#                        image (implies -u); apk keeps no install time, so
#                        there the diff against /rom stands in for time
#   -u         exclude packages listed in the image manifest (works in all
#              modes). In time mode this hides stock packages manually
#              updated via opkg upgrade: they have a fresh Installed-Time
#              but belong to the default package set. Packages baked into a
#              custom image but absent from the official manifest are still
#              shown. The manifest is taken from -b, otherwise downloaded
#              from downloads.openwrt.org — tried on this machine first
#              (extra ssh probe for release/target), then on the device as
#              a fallback (use -b for custom builds). The downloaded manifest
#              is augmented with the device profile's default packages from
#              profiles.json (device_packages of the profile whose
#              supported_devices lists the board name); if no profile
#              matches, the manifest alone is used (logged with -v)
#   -b file    local file with the manifest package list — a manifest from
#              downloads.openwrt.org or just one name per line (first field
#              is used); implies -u
#   -i         (for -m rom-manifest / time+rom-manifest) keep only packages
#              that are currently installed: baked-in packages later removed
#              by the user are dropped (other modes list installed packages
#              by definition)
#   -f filter  result filtering:
#                all   — all user-installed packages (default)
#                top   — only packages no other installed package depends on
#                        (what was installed by hand, without packages pulled
#                        in as dependencies)

set -eu

usage() {
    echo "Usage: $0 [-v] [-u] [-i] [-b file] -m rom|time|rom-manifest|time+rom-manifest [-f all|top] [user@]host [ssh options...]" >&2
    exit 1
}

VERBOSE=0
MODE=
FILTER=all
UPGRADED=0
INSTALLED_ONLY=0
BASEFILE=
while getopts "vuim:f:b:" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        u) UPGRADED=1 ;;
        i) INSTALLED_ONLY=1 ;;
        b) BASEFILE=$OPTARG; UPGRADED=1 ;;
        m) MODE=$OPTARG ;;
        f) FILTER=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

case $MODE in
    rom|time) ;;
    rom-manifest|time+rom-manifest) UPGRADED=1 ;;   # these modes are defined by the manifest diff
    "") echo "ERROR: mode is required (-m rom|time|rom-manifest|time+rom-manifest)" >&2; usage ;;
    *) echo "ERROR: unknown mode '$MODE' (expected: rom, time, rom-manifest, time+rom-manifest)" >&2; usage ;;
esac
case $FILTER in
    all|top) ;;
    *) echo "ERROR: unknown filter '$FILTER' (expected: all, top)" >&2; usage ;;
esac

# The baseline package list (-b) is passed to the device as base64: the
# content becomes a single "word" on the ssh command line, no quoting issues.
BASELINE_B64=
if [ -n "$BASEFILE" ]; then
    [ -f "$BASEFILE" ] || { echo "ERROR: baseline file '$BASEFILE' not found (to auto-download the manifest use -u without -b)" >&2; usage; }
    BASELINE_B64=$(base64 < "$BASEFILE" | tr -d '\n')
fi

[ $# -ge 1 ] || usage
HOST="$1"
shift

# With -u and no -b, try to fetch the image manifest here on the client:
# the device often has no direct internet access. Falls back to downloading
# on the device (see baseline_names) if this fails.
if [ "$UPGRADED" = 1 ] && [ -z "$BASEFILE" ]; then
    INFO=$(ssh -n "$@" "$HOST" '. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE:-} ${DISTRIB_TARGET:-}"; ubus call system board 2>/dev/null | jsonfilter -e "@.board_name" 2>/dev/null || true' 2>/dev/null) || INFO=
    REL=$(echo "$INFO" | sed -n '1s/ .*//p')
    TGT=$(echo "$INFO" | sed -n '1s/^[^ ]* //p')
    BOARD=$(echo "$INFO" | sed -n '2p')
    if [ -n "$REL" ] && [ -n "$TGT" ]; then
        TGT_DASH=$(echo "$TGT" | tr '/' '-')
        if [ "$REL" = "SNAPSHOT" ]; then
            URL="https://downloads.openwrt.org/snapshots/targets/$TGT/openwrt-$TGT_DASH.manifest"
        else
            URL="https://downloads.openwrt.org/releases/$REL/targets/$TGT/openwrt-$REL-$TGT_DASH.manifest"
        fi
        [ "$VERBOSE" = 1 ] && echo "# baseline: downloading $URL (on client)" >&2
        MANIFEST=$(curl -fsS "$URL" 2>/dev/null || wget -qO- "$URL" 2>/dev/null) || MANIFEST=
        if [ -n "$MANIFEST" ]; then
            # Augment the manifest with the device profile's default packages
            # from profiles.json. An entry with a leading '-' means the package
            # is excluded from this device's default set — subtract it.
            # The profile key is not the board name (rpi-3 serves
            # raspberrypi,3-model-b and others), so the profile is the one
            # whose supported_devices lists the board. Keys are sorted, so
            # device_packages opens each profile and its supported_devices
            # follows before the next profile's device_packages. The same
            # lookup runs on the device in baseline_names.
            PURL="${URL%/*}/profiles.json"
            DEVPKGS=
            if [ -n "$BOARD" ]; then
                DEVPKGS=$(curl -fsS "$PURL" 2>/dev/null || wget -qO- "$PURL" 2>/dev/null || true)
                DEVPKGS=$(printf '%s' "$DEVPKGS" | tr -d '\n' | awk -v board="$BOARD" '
                    {
                        key = "\"device_packages\":["
                        s = $0
                        while ((i = index(s, key)) > 0) {
                            s = substr(s, i + length(key))
                            nxt = index(s, key)
                            chunk = nxt ? substr(s, 1, nxt - 1) : s
                            j = index(chunk, "\"supported_devices\":[")
                            if (!j) continue
                            sd = substr(chunk, j)
                            sd = substr(sd, 1, index(sd, "]"))
                            if (!index(sd, "\"" board "\"")) continue
                            pk = substr(chunk, 1, index(chunk, "]") - 1)
                            gsub(/[" ]/, "", pk)
                            n = split(pk, a, ",")
                            for (x = 1; x <= n; x++) if (a[x] != "") print a[x]
                            exit
                        }
                    }')
            fi
            if [ -n "$DEVPKGS" ]; then
                [ "$VERBOSE" = 1 ] && echo "# baseline: adding device profile packages ($BOARD): $(echo "$DEVPKGS" | tr '\n' ' ')" >&2
            else
                [ "$VERBOSE" = 1 ] && echo "# baseline: device profile packages unavailable ($BOARD), using manifest only" >&2
            fi
            BASELINE=$(printf '%s\n%s\n' "$MANIFEST" "$DEVPKGS" | awk '
                $1 == "" { next }
                substr($1, 1, 1) == "-" { neg[substr($1, 2)]; next }
                { seen[$1] }
                END { for (p in seen) if (!(p in neg)) print p }')
            BASELINE_B64=$(printf '%s\n' "$BASELINE" | base64 | tr -d '\n')
        elif [ "$VERBOSE" = 1 ]; then
            echo "# baseline: client-side download failed, will retry on the device" >&2
        fi
    fi
fi

# All analysis runs on the device itself in a single ssh call.
# VERBOSE/MODE/FILTER/UPGRADED are passed to the remote shell via the command line.
# stdout is buffered locally so the package list does not interleave with
# verbose logs (stderr travels over ssh as a separate stream, order is not
# guaranteed).
# the option variables expand on the client on purpose (SC2029)
# shellcheck disable=SC2029
PKGS=$(ssh "$@" "$HOST" "VERBOSE=$VERBOSE MODE=$MODE FILTER=$FILTER UPGRADED=$UPGRADED INSTALLED_ONLY=$INSTALLED_ONLY BASELINE_B64=$BASELINE_B64 sh -s" <<'REMOTE'
set -eu

STATUS=/usr/lib/opkg/status
ROM_STATUS=/rom/usr/lib/opkg/status
APK_DB=/lib/apk/db/installed
ROM_APK_DB=/rom/lib/apk/db/installed

vlog() {
    if [ "${VERBOSE:-0}" = 1 ]; then
        echo "# $*" >&2
    fi
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Print the list, adding a counter to stderr in verbose mode
report() {
    result=$(cat)
    if [ -n "$result" ]; then
        vlog "user-installed packages: $(printf '%s\n' "$result" | wc -l)"
        printf '%s\n' "$result"
    else
        vlog "user-installed packages: 0"
    fi
}

# --- baseline package list of the image (for -u) -----------------------------

BASE_LIST=/tmp/.pkgs_base

# Package names from the image manifest: provided by the client (-b file or
# downloaded there), or downloaded here as a fallback
baseline_names() {
    if [ -n "${BASELINE_B64:-}" ]; then
        vlog "baseline: manifest provided by client (-b file or client-side download)"
        echo "$BASELINE_B64" | base64 -d | awk '$1 != "" {print $1}'
    else
        # There is a single manifest per target on downloads.openwrt.org
        # (no device profile in the name), e.g.:
        #   releases/24.10.2/targets/ath79/generic/openwrt-24.10.2-ath79-generic.manifest
        #   snapshots/targets/x86/64/openwrt-x86-64.manifest
        . /etc/openwrt_release 2>/dev/null \
            || die "-u: no /etc/openwrt_release, cannot locate image manifest (use -b FILE)"
        tgt=$(echo "$DISTRIB_TARGET" | tr '/' '-')
        if [ "$DISTRIB_RELEASE" = "SNAPSHOT" ]; then
            url="https://downloads.openwrt.org/snapshots/targets/$DISTRIB_TARGET/openwrt-$tgt.manifest"
        else
            url="https://downloads.openwrt.org/releases/$DISTRIB_RELEASE/targets/$DISTRIB_TARGET/openwrt-$DISTRIB_RELEASE-$tgt.manifest"
        fi
        vlog "baseline: downloading $url"
        wget -qO /tmp/.pkgs_manifest "$url" \
            || die "-u: manifest download failed: $url (no internet or https support on device? use -b FILE)"
        # Augment with the device profile's default packages from
        # profiles.json; a leading '-' excludes the package from the set.
        # The profile is found by its supported_devices, the same lookup as
        # on the client (jsonfilter cannot match an array element)
        board=$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name' 2>/dev/null || true)
        devpkgs=
        if [ -n "$board" ] && wget -qO /tmp/.profiles_json "${url%/*}/profiles.json" 2>/dev/null; then
            devpkgs=$(tr -d '\n' < /tmp/.profiles_json | awk -v board="$board" '
                {
                    key = "\"device_packages\":["
                    s = $0
                    while ((i = index(s, key)) > 0) {
                        s = substr(s, i + length(key))
                        nxt = index(s, key)
                        chunk = nxt ? substr(s, 1, nxt - 1) : s
                        j = index(chunk, "\"supported_devices\":[")
                        if (!j) continue
                        sd = substr(chunk, j)
                        sd = substr(sd, 1, index(sd, "]"))
                        if (!index(sd, "\"" board "\"")) continue
                        pk = substr(chunk, 1, index(chunk, "]") - 1)
                        gsub(/[" ]/, "", pk)
                        n = split(pk, a, ",")
                        for (x = 1; x <= n; x++) if (a[x] != "") print a[x]
                        exit
                    }
                }')
        fi
        rm -f /tmp/.profiles_json
        if [ -n "$devpkgs" ]; then
            vlog "baseline: adding device profile packages ($board): $(echo "$devpkgs" | tr '\n' ' ')"
        else
            vlog "baseline: device profile packages unavailable ($board), using manifest only"
        fi
        { awk '{print $1}' /tmp/.pkgs_manifest; printf '%s\n' "$devpkgs"; } | awk '
            $1 == "" { next }
            substr($1, 1, 1) == "-" { neg[substr($1, 2)]; next }
            { seen[$1] }
            END { for (p in seen) if (!(p in neg)) print p }'
        rm -f /tmp/.pkgs_manifest
    fi
}

# Prepare $BASE_LIST; called before the pipeline so die works under set -e
prepare_baseline() {
    [ "${UPGRADED:-0}" = 1 ] || return 0
    baseline_names > "$BASE_LIST"
    [ -s "$BASE_LIST" ] || die "-u: manifest package list is empty (download failed? use -b FILE with the image manifest)"
    vlog "baseline: $(wc -l < "$BASE_LIST") packages in manifest"
}

# --- filters ------------------------------------------------------------------

# Drop packages that were part of the original image: manually updated system
# packages have a fresh Installed-Time but are not user-installed
filter_upgraded() {
    if [ "${UPGRADED:-0}" != 1 ]; then
        cat
        return
    fi
    vlog "filter: -u — dropping packages present in image manifest"
    awk 'NR==FNR{base[$1];next} !($1 in base)' "$BASE_LIST" -
}

# Keep only packages that are currently installed (opkg); relevant for
# rom-manifest mode, where baked-in packages may have been removed since
filter_installed_opkg() {
    if [ "${INSTALLED_ONLY:-0}" != 1 ]; then
        cat
        return
    fi
    vlog "filter: -i — dropping packages not currently installed"
    awk 'NR==FNR {if ($1 == "Package:") inst[$2]; next} $0 in inst' "$STATUS" -
}

# Same for apk
filter_installed_apk() {
    if [ "${INSTALLED_ONLY:-0}" != 1 ]; then
        cat
        return
    fi
    vlog "filter: -i — dropping packages not currently installed"
    apk_names "$APK_DB" > /tmp/.pkgs_inst
    awk 'NR==FNR{inst[$0];next} $0 in inst' /tmp/.pkgs_inst -
    rm -f /tmp/.pkgs_inst
}

# Keep only packages that appear in no installed package's Depends: (opkg).
# The set of all dependencies is collected in one pass over the status file.
filter_top_opkg() {
    if [ "${FILTER:-all}" != top ]; then
        cat
        return
    fi
    vlog "filter: top — dropping packages required by other installed packages"
    awk '
        FNR == NR {
            if (/^Depends:/) {
                sub(/^Depends: */, "")
                n = split($0, a, /, */)
                for (i = 1; i <= n; i++) {
                    gsub(/ *\(.*/, "", a[i])   # strip version constraints
                    dep[a[i]]
                }
            }
            next
        }
        !($0 in dep)
    ' "$STATUS" -
}

# Same for apk: a candidate must have no reverse dependencies
filter_top_apk() {
    if [ "${FILTER:-all}" != top ]; then
        cat
        return
    fi
    vlog "filter: top — dropping packages required by other installed packages"
    while IFS= read -r pkg; do
        rdeps=$(apk info --rdepends "$pkg" 2>/dev/null | sed '1d' | grep -c . || true)
        [ "${rdeps:-0}" -eq 0 ] && echo "$pkg" || true
    done
}

# --- comparison methods -------------------------------------------------------

# Bare package names from an apk database ($APK_DB or $ROM_APK_DB). `apk list`
# prints name-version, which matches neither the manifest nor
# `apk info --rdepends`; the P: lines of the database carry the name alone
apk_names() {
    awk '/^P:/ {print substr($0, 3)}' "$1" | sort
}

apk_rom() {
    [ -f "$ROM_APK_DB" ] || die "mode 'rom' requires $ROM_APK_DB (squashfs image)"
    vlog "method: apk, diff against /rom image database"
    prepare_baseline
    apk_names "$ROM_APK_DB" > /tmp/.pkgs_rom
    vlog "packages in rom image: $(wc -l < /tmp/.pkgs_rom)"
    vlog "packages installed now: $(grep -c '^P:' "$APK_DB")"
    apk_names "$APK_DB" \
        | awk 'NR==FNR{rom[$0];next} !($0 in rom)' /tmp/.pkgs_rom - \
        | filter_upgraded \
        | filter_top_apk \
        | report
    rm -f /tmp/.pkgs_rom "$BASE_LIST"
}

opkg_rom() {
    [ -f "$ROM_STATUS" ] || die "mode 'rom' requires $ROM_STATUS (squashfs image)"
    vlog "method: opkg, diff against /rom status file"
    vlog "packages in rom image: $(grep -c '^Package:' "$ROM_STATUS")"
    vlog "packages installed now: $(grep -c '^Package:' "$STATUS")"
    prepare_baseline
    awk '/^Package:/ {
             if (NR == FNR) rom[$2]
             else if (!($2 in rom)) print $2
         }' "$ROM_STATUS" "$STATUS" | sort | filter_upgraded | filter_top_opkg | report
    rm -f "$BASE_LIST"
}

# Packages baked into the /rom image on top of the default package set:
# everything in /rom that the image manifest does not list
apk_rom_manifest() {
    [ -f "$ROM_APK_DB" ] || die "mode 'rom-manifest' requires $ROM_APK_DB (squashfs image)"
    vlog "method: apk, /rom packages absent from manifest"
    prepare_baseline
    vlog "packages in rom image: $(grep -c '^P:' "$ROM_APK_DB")"
    apk_names "$ROM_APK_DB" \
        | filter_upgraded | filter_installed_apk | filter_top_apk | report
    rm -f "$BASE_LIST"
}

opkg_rom_manifest_names() {
    awk '/^Package:/{print $2}' "$ROM_STATUS"
}

opkg_rom_manifest() {
    [ -f "$ROM_STATUS" ] || die "mode 'rom-manifest' requires $ROM_STATUS (squashfs image)"
    vlog "method: opkg, /rom packages absent from manifest"
    prepare_baseline
    vlog "packages in rom image: $(grep -c '^Package:' "$ROM_STATUS")"
    opkg_rom_manifest_names | sort \
        | filter_upgraded | filter_installed_opkg | filter_top_opkg | report
    rm -f "$BASE_LIST"
}

# Image packages share the same Installed-Time (firmware build time).
# busybox is the reference; anything newer was installed by the user.
# $BASE_TIME is computed before the pipelines so die works under set -e
init_base_time() {
    BASE_TIME=$(awk '/^Package: busybox$/{f=1} f&&/^Installed-Time:/{print $2; exit}' "$STATUS")
    [ -n "${BASE_TIME:-}" ] || die "cannot determine base install time"
    vlog "base install time (busybox): $BASE_TIME ($(date -d "@$BASE_TIME" 2>/dev/null || echo '?'))"
}

opkg_time_names() {
    awk -v base="$BASE_TIME" '
        /^Package:/        {pkg=$2}
        /^Installed-Time:/ {if ($2 > base) print pkg}
    ' "$STATUS"
}

opkg_time() {
    vlog "method: opkg, Installed-Time heuristic"
    vlog "packages installed now: $(grep -c '^Package:' "$STATUS")"
    init_base_time
    prepare_baseline
    opkg_time_names | sort | filter_upgraded | filter_top_opkg | report
    rm -f "$BASE_LIST"
}

# Union of time and rom-manifest: everything that changed after flashing
# plus everything baked into the custom image
opkg_time_rom_manifest() {
    [ -f "$ROM_STATUS" ] || die "mode 'time+rom-manifest' requires $ROM_STATUS (squashfs image)"
    vlog "method: opkg, union of time and rom-manifest"
    vlog "packages in rom image: $(grep -c '^Package:' "$ROM_STATUS")"
    vlog "packages installed now: $(grep -c '^Package:' "$STATUS")"
    init_base_time
    prepare_baseline
    { opkg_time_names; opkg_rom_manifest_names; } | sort -u \
        | filter_upgraded | filter_installed_opkg | filter_top_opkg | report
    rm -f "$BASE_LIST"
}

# Union of the /rom diff and rom-manifest. apk records no install time, and
# on a squashfs image what was installed after flashing is exactly what the
# /rom database lacks, so the diff takes the place of time. With the manifest
# filter (implied) the union is (installed + /rom) minus the manifest
apk_time_rom_manifest() {
    [ -f "$ROM_APK_DB" ] || die "mode 'time+rom-manifest' requires $ROM_APK_DB (squashfs image)"
    vlog "method: apk, union of /rom diff (in place of time) and rom-manifest"
    vlog "packages in rom image: $(grep -c '^P:' "$ROM_APK_DB")"
    vlog "packages installed now: $(grep -c '^P:' "$APK_DB")"
    prepare_baseline
    { apk_names "$APK_DB"; apk_names "$ROM_APK_DB"; } | sort -u \
        | filter_upgraded | filter_installed_apk | filter_top_apk | report
    rm -f "$BASE_LIST"
}

# --- package manager and mode selection ---------------------------------------

vlog "host: $(cat /etc/board.json 2>/dev/null | grep -o '"id":[^,]*' | head -1 || uname -n)"
vlog "release: $(. /etc/openwrt_release 2>/dev/null && echo "$DISTRIB_DESCRIPTION" || echo unknown)"
vlog "requested mode: $MODE, filter: ${FILTER:-all}, upgraded-filter: ${UPGRADED:-0}"

# OpenWrt >= 24.10 may use apk instead of opkg
if command -v apk >/dev/null 2>&1 && [ ! -x /bin/opkg ]; then
    case "$MODE" in
        (time)   die "mode 'time' is not supported with apk (no install time recorded)" ;;
        (rom)    apk_rom ;;
        (rom-manifest) apk_rom_manifest ;;
        (time+rom-manifest) apk_time_rom_manifest ;;
    esac
    exit 0
fi

[ -f "$STATUS" ] || die "no opkg status file at $STATUS"

case "$MODE" in
    (rom)    opkg_rom ;;
    (time)   opkg_time ;;
    (rom-manifest) opkg_rom_manifest ;;
    (time+rom-manifest) opkg_time_rom_manifest ;;
esac
REMOTE
)

if [ -n "$PKGS" ]; then
    printf '%s\n' "$PKGS"
fi
