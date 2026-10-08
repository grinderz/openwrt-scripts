#!/bin/sh
# Backs up a list of remote OpenWrt devices in one pass. Failures on one
# host do not stop the others; a summary is printed at the end.
#
# Backup types (extensible, see "adding a type" below):
#   sysupgrade    — standard config backup ('sysupgrade -b'), the archive
#                   restorable via 'sysupgrade -r' or the LuCI backup page
#   packages      — list of installed packages (opkg or apk), useful together
#                   with a sysupgrade archive to rebuild a device
#   user-packages — packages installed by the user on top of the stock image,
#                   produced by list-user-packages.sh from this repo
#                   (options via USER_PACKAGES_OPTS)
#   overlay       — full copy of the writable overlay (/overlay/upper on a
#                   squashfs image): every file that differs from the stock
#                   firmware, installed packages included. Restore: extract
#                   the archive into /overlay and reboot
#   nor, nand     — raw dump of every mtd flash partition (disabled by
#                   default: not in the default TYPES, enable explicitly in
#                   the config or with -t). One <mtdN>-<name>.bin per
#                   partition plus a copy of /proc/mtd in one tar.gz;
#                   partitions stream over ssh straight into a local temp
#                   dir, nothing is written on the device. nor reads via
#                   cat; nand needs nanddump on the device (nand-utils
#                   package) to skip bad blocks. Note: dumps contain
#                   secrets (keys, passwords) and radio calibration data
#   emmc          — raw dump of every eMMC partition (disabled by default,
#                   same warning about secrets). Partitions are gzipped on
#                   the device — multi-GB but mostly-empty partitions travel
#                   and are stored compressed — and packed into a plain tar:
#                   one <dev>[-<gpt-name>].bin.gz per partition (rpmb is
#                   skipped, it is not readable), the first MiB of the bare
#                   disk (MBR/GPT) as <disk>-table.bin.gz, plus
#                   /proc/partitions and the GPT name map as a layout
#                   reference. Restore one partition:
#                   gzip -dc mmcblk0p4-crash.bin.gz | ssh host "cat > /dev/mmcblk0p4"
#
# Usage:   ./backup-openwrt.sh [-v] [-t types] [-c config] [host...]
# Example: ./backup-openwrt.sh -c backup-openwrt.conf
#          ./backup-openwrt.sh -c backup-openwrt.conf rtr1-gl-mt6000
#
#   -c file   config file, shell KEY=VALUE format, see
#             backup-openwrt.conf.example; default when omitted:
#             $XDG_CONFIG_HOME/openwrt-scripts/backup-openwrt.conf. Recognized keys:
#               HOSTS       whitespace-separated [user@]host list (required)
#               BACKUP_DIR  where to store backups (required); layout:
#                           BACKUP_DIR/<host>/<host>-<type>-<timestamp>.<ext>
#               TYPES       backup types to run (default: sysupgrade)
#               KEEP        keep this many newest backups per host+type,
#                           0 = keep everything (default: 0)
#               SSH_OPTS    extra ssh options, e.g. "-o ConnectTimeout=10"
#               USER_PACKAGES_OPTS  options for list-user-packages.sh in the
#                           user-packages type (default: "-m rom")
#   -t types  override TYPES from the config for this run
#   -v        verbose output to stderr
#   host...   backup only these hosts instead of HOSTS from the config
#
# Adding a type: define a backup_<name>() function below (hyphens in the
# type name map to underscores). It receives the host as $1 and must print
# the backup data to stdout (the caller redirects it into the destination
# file); everything diagnostic goes to stderr. Declare the file extension
# in ext_for() and, if needed, a validity check in verify_backup().

set -eu

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
    echo "Usage: $0 [-v] [-t types] [-c config] [host...]" >&2
    exit 1
}

VERBOSE=0
CONFIG=
TYPES_ARG=
while getopts "vt:c:" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        t) TYPES_ARG=$OPTARG ;;
        c) CONFIG=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

# --- config -------------------------------------------------------------------

[ -n "$CONFIG" ] || CONFIG=$(default_config backup-openwrt)

HOSTS=
BACKUP_DIR=
TYPES=sysupgrade
KEEP=0
SSH_OPTS=
USER_PACKAGES_OPTS="-m rom"
load_config "$CONFIG"

[ -n "$TYPES_ARG" ] && TYPES=$TYPES_ARG
[ $# -ge 1 ] && HOSTS=$*

[ -n "$HOSTS" ]      || die "HOSTS is not set in $CONFIG"
[ -n "$BACKUP_DIR" ] || die "BACKUP_DIR is not set in $CONFIG"
check_uint KEEP "$KEEP"

# One authenticated (multiplexed) connection per host: every ssh call after
# the first reuses the master — faster, and a flaky agent/key cannot fail an
# individual call mid-run (vital for the multi-call flash dump types)
# The socket path must stay under the ~104-byte unix-socket limit, hence
# the short /tmp template instead of the (long on macOS) default TMPDIR
CTL_DIR=$(mktemp -d /tmp/bo.XXXXXX 2>/dev/null) || CTL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bo.XXXXXX")
trap 'rm -rf "$CTL_DIR"' EXIT
SSH_OPTS="$SSH_OPTS -o ControlMaster=auto -o ControlPath=$CTL_DIR/%C -o ControlPersist=90"

STAMP=$(date +%Y%m%d-%H%M%S)
# Same moment reformatted for 'touch -t' (CCYYMMDDhhmm.SS): file mtimes are
# aligned to it so every artifact of one run carries identical time
TIME_PART=${STAMP#*-}
TOUCH_STAMP="${STAMP%-*}${TIME_PART%??}.${TIME_PART#????}"

# --- backup types ---------------------------------------------------------------
# Each type is a backup_<name>() function: $1 = host, backup data -> stdout,
# diagnostics -> stderr. Non-zero exit marks the backup as failed.

# File extension per type (used in the destination file name)
ext_for() {
    case $1 in
        sysupgrade|overlay|nor|nand) echo tar.gz ;;
        emmc)                        echo tar ;;   # members are already gzipped
        packages|user-packages)      echo txt ;;
        *)                           echo dat ;;
    esac
}

# Standard config backup: 'sysupgrade -b'. Modern sysupgrade streams the
# archive to stdout with '-b -' (nothing touches the device tmpfs); old
# versions without that support fall back to a temp file in /tmp.
backup_sysupgrade() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$1" sh -s <<'REMOTE'
set -eu
if grep -q 'proc/self/fd/1' /sbin/sysupgrade 2>/dev/null; then
    sysupgrade -b -
else
    f="/tmp/.backup.$$.tar.gz"
    trap 'rm -f "$f"' EXIT
    sysupgrade -b "$f" >&2
    cat "$f"
fi
REMOTE
}

# List of installed packages, opkg or apk depending on the firmware
backup_packages() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$1" sh -s <<'REMOTE'
set -eu
if command -v apk >/dev/null 2>&1 && [ ! -x /bin/opkg ]; then
    apk list --installed
else
    opkg list-installed
fi
REMOTE
}

# Full copy of the writable overlay. Only 'upper' is taken: 'work' is the
# transient overlayfs work dir and never needed for a restore. The 'upper/'
# path prefix is kept in the archive so it unpacks straight into /overlay.
backup_overlay() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$1" sh -s <<'REMOTE'
set -eu
[ -d /overlay/upper ] \
    || { echo "ERROR: /overlay/upper not found (not a squashfs+overlayfs image?)" >&2; exit 1; }
tar -C /overlay -czf - upper
REMOTE
}

# Packages installed by the user on top of the stock image; reuses
# list-user-packages.sh (run as a child script — it is not sourceable:
# it executes at the top level). ssh options go after the host there.
backup_user_packages() {
    # shellcheck disable=SC2086
    "$SCRIPT_DIR/list-user-packages.sh" $USER_PACKAGES_OPTS "$1" $SSH_OPTS
}

# Raw flash dump shared by the nor/nand types; $1 = host, $2 = nor|nand.
# Each partition from /proc/mtd streams over ssh into a local temp dir
# (no temp files on the device), then everything is packed locally.
backup_mtd() {
    mtd_tmp=$(mktemp -d) || return 1
    # shellcheck disable=SC2086
    if ! ssh $SSH_OPTS "$1" cat /proc/mtd > "$mtd_tmp/proc-mtd" \
       || ! grep -q '^mtd' "$mtd_tmp/proc-mtd"; then
        echo "ERROR: no mtd partitions on $1 (eMMC/SD device? $2 needs raw flash)" >&2
        rm -rf "$mtd_tmp"
        return 1
    fi
    if [ "$2" = nand ]; then
        # cat on NAND dies (or silently corrupts) on bad blocks — nanddump
        # from the nand-utils package skips them properly
        # shellcheck disable=SC2086
        ssh $SSH_OPTS "$1" command -v nanddump >/dev/null || {
            echo "ERROR: nanddump not found on $1 (opkg install nand-utils)" >&2
            rm -rf "$mtd_tmp"
            return 1
        }
    fi
    # /proc/mtd lines look like: mtd0: 00040000 00020000 "u-boot"
    while IFS= read -r mtd_line; do
        case $mtd_line in mtd*:*) ;; *) continue ;; esac
        mtd_dev=${mtd_line%%:*}
        mtd_name=$(echo "$mtd_line" | sed 's/^[^"]*"//; s/"$//' | tr ' /' '--')
        vlog "  $2: $mtd_dev ($mtd_name)"
        case $2 in
            # the mtdNro node is read-only — prefer it when present
            nor)  mtd_cmd="if [ -e /dev/${mtd_dev}ro ]; then cat /dev/${mtd_dev}ro; else cat /dev/$mtd_dev; fi" ;;
            nand) mtd_cmd="nanddump --bb=skipbad /dev/$mtd_dev" ;;
        esac
        mtd_ok=0
        # one retry per partition: a transient ssh hiccup must not void a
        # multi-partition dump ('>' truncates the file on each attempt)
        for mtd_try in 1 2; do
            # the command is built locally on purpose (SC2029); -n stops ssh
            # from eating the rest of proc-mtd off the while-loop stdin
            # shellcheck disable=SC2086,SC2029
            if ssh -n $SSH_OPTS "$1" "$mtd_cmd" > "$mtd_tmp/$mtd_dev-$mtd_name.bin"; then
                mtd_ok=1
                break
            fi
            vlog "  $2: retrying $mtd_dev (attempt $mtd_try failed)"
            sleep 2
        done
        if [ "$mtd_ok" = 0 ]; then
            echo "ERROR: dump of $mtd_dev ($mtd_name) failed on $1" >&2
            rm -rf "$mtd_tmp"
            return 1
        fi
    done < "$mtd_tmp/proc-mtd"
    tar -C "$mtd_tmp" -czf - .
    mtd_rc=$?
    rm -rf "$mtd_tmp"
    return $mtd_rc
}

backup_nor() {
    backup_mtd "$1" nor
}

backup_nand() {
    backup_mtd "$1" nand
}

# Raw dump of the eMMC partitions; $1 = host. Same idea as backup_mtd, but
# partitions can be multi-GB, so each one is gzipped on the device and kept
# compressed: the outer tar is therefore plain (no -z). Every fetched .gz is
# integrity-checked locally — a broken pipe mid-transfer must not pass.
backup_emmc() {
    emmc_tmp=$(mktemp -d) || return 1
    # shellcheck disable=SC2086
    if ! ssh $SSH_OPTS "$1" cat /proc/partitions > "$emmc_tmp/proc-partitions"; then
        rm -rf "$emmc_tmp"
        return 1
    fi
    emmc_parts=$(awk '$4 ~ /^mmcblk/ && $4 !~ /rpmb$/ {print $4}' "$emmc_tmp/proc-partitions")
    if [ -z "$emmc_parts" ]; then
        echo "ERROR: no eMMC (mmcblk*) devices on $1" >&2
        rm -rf "$emmc_tmp"
        return 1
    fi
    # GPT partition names: nicer file names and a layout reference on restore
    # shellcheck disable=SC2086,SC2029
    ssh $SSH_OPTS "$1" 'for u in /sys/class/block/mmcblk*/uevent; do
        n=$(sed -n "s/^PARTNAME=//p" "$u"); d=${u%/uevent}
        echo "${d##*/} $n"; done' > "$emmc_tmp/partnames" 2>/dev/null || : > "$emmc_tmp/partnames"
    # Reading gigabytes through the page cache can OOM a small router — the
    # cache fills faster than the kernel reclaims it. O_DIRECT bypasses it;
    # probe once, not every busybox dd is built with iflag support.
    emmc_probe=$(echo "$emmc_parts" | head -n 1)
    # shellcheck disable=SC2086,SC2029
    if ssh $SSH_OPTS "$1" "dd if=/dev/$emmc_probe of=/dev/null bs=1M count=1 iflag=direct" >/dev/null 2>&1; then
        emmc_direct="iflag=direct"
    else
        emmc_direct=""
        vlog "  emmc: dd has no iflag=direct on $1, reading through the page cache"
    fi
    for emmc_part in $emmc_parts; do
        case $emmc_part in
            *boot[0-9]*|*p[0-9]*)
                emmc_name=$(awk -v d="$emmc_part" '$1 == d {print $2}' "$emmc_tmp/partnames" | tr ' /' '--')
                emmc_out="$emmc_part${emmc_name:+-$emmc_name}.bin.gz"
                emmc_kb=$(awk -v d="$emmc_part" '$4 == d {print $3}' "$emmc_tmp/proc-partitions")
                vlog "  emmc: $emmc_part${emmc_name:+ ($emmc_name)}, ${emmc_kb}KB"
                # pipefail: a dd read error must fail the whole pipe — gzip
                # alone would exit 0 with a truncated but valid stream
                emmc_cmd="set -o pipefail; dd if=/dev/$emmc_part bs=1M $emmc_direct 2>/dev/null | gzip -c"
                ;;
            *)
                # bare disk: only the partition table area (MBR + GPT)
                emmc_out="$emmc_part-table.bin.gz"
                vlog "  emmc: $emmc_part (partition table, first 1MiB)"
                emmc_cmd="set -o pipefail; dd if=/dev/$emmc_part bs=1024 count=1024 $emmc_direct 2>/dev/null | gzip -c"
                ;;
        esac
        emmc_ok=0
        # one retry per partition: a transient ssh hiccup must not void a
        # multi-GB dump ('>' truncates the file on each attempt)
        for emmc_try in 1 2; do
            # shellcheck disable=SC2086,SC2029
            if ssh $SSH_OPTS "$1" "$emmc_cmd" > "$emmc_tmp/$emmc_out" \
               && gzip -t "$emmc_tmp/$emmc_out" 2>/dev/null; then
                emmc_ok=1
                break
            fi
            vlog "  emmc: retrying $emmc_part (attempt $emmc_try failed)"
            sleep 2
        done
        if [ "$emmc_ok" = 0 ]; then
            echo "ERROR: dump of $emmc_part failed on $1" >&2
            rm -rf "$emmc_tmp"
            return 1
        fi
    done
    tar -C "$emmc_tmp" -cf - .
    emmc_rc=$?
    rm -rf "$emmc_tmp"
    return $emmc_rc
}

# Sanity check of the fetched data before it replaces anything; $1 = type,
# $2 = file. Extend together with new types when they need validation.
verify_backup() {
    case $1 in
        sysupgrade|overlay|nor|nand) tar -tzf "$2" >/dev/null 2>&1 ;;
        emmc)          tar -tf "$2" >/dev/null 2>&1 ;;
        user-packages) : ;;   # empty list is valid: no user-installed packages
        *)             [ -s "$2" ] ;;
    esac
}

# --- run ------------------------------------------------------------------------

# Drop old backups beyond KEEP for one host+type; relies on the sortable
# timestamp in the file names
prune() {
    [ "$KEEP" -gt 0 ] || return 0
    # File names are generated by this script — no exotic characters
    # shellcheck disable=SC2012
    ls -1 "$1/$2-$3-"*".$4" 2>/dev/null | sort -r | tail -n "+$((KEEP + 1))" \
        | while IFS= read -r old; do
            vlog "prune: $old"
            rm -f "$old"
        done
}

FAILED=
OK=0
for host in $HOSTS; do
    name=${host#*@}                     # strip user@ for dir/file names
    dest_dir="$BACKUP_DIR/$name"
    mkdir -p "$dest_dir"
    for type in $TYPES; do
        # Hyphens in type names map to underscores in function names
        fn="backup_$(echo "$type" | tr '-' '_')"
        command -v "$fn" >/dev/null 2>&1 \
            || die "unknown backup type '$type' (no $fn function)"
        ext=$(ext_for "$type")
        out="$dest_dir/$name-$type-$STAMP.$ext"
        vlog "$host: $type -> $out"
        # Fetch into a .part file so an interrupted transfer never looks
        # like a valid backup
        if "$fn" "$host" > "$out.part" && verify_backup "$type" "$out.part"; then
            mv "$out.part" "$out"
            touch -t "$TOUCH_STAMP" "$out"
            echo "OK: $host $type ($(wc -c < "$out" | tr -d ' ') bytes) $out"
            OK=$((OK + 1))
            prune "$dest_dir" "$name" "$type" "$ext"
        else
            rm -f "$out.part"
            echo "FAILED: $host $type" >&2
            FAILED="$FAILED $host/$type"
        fi
    done
done

echo "done: $OK ok${FAILED:+, failed:$FAILED}"
[ -z "$FAILED" ]
