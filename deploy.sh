#!/bin/sh
# Deploys files from a local directory to OpenWrt devices over ssh. Which
# files go to which host is defined by the DEPLOY map in the config. Files
# stream through ssh (no scp/sftp server needed on the device), land
# atomically (.part + mv) and are skipped when the remote copy is already
# identical (md5 match). The remote mode comes from an optional ':mode'
# suffix on the pattern (e.g. 'watchdog.sh:700'); without it the local
# executable bit decides: executable -> 755, otherwise 644. Failures on one
# host do not stop the others; a summary is printed at the end.
#
# Usage:   ./deploy.sh [-v] [-n] -c config [host...]
# Example: ./deploy.sh -c deploy.conf
#          ./deploy.sh -c deploy.conf rtr1-gl-mt6000
#
#   -c file   config file (required), shell KEY=VALUE format, see
#             deploy.conf.example. Recognized keys:
#               DEPLOY      host-to-files map (required); one entry per line:
#                             <[user@]host> <file|glob>[:mode][@boot][@keep]...
#                           patterns are shell globs relative to DEPLOY_DIR
#                           ('*' = every file in the top level; files in a
#                           subdirectory need an explicit 'subdir/*'), the
#                           optional ':mode' is octal permissions for every
#                           file the pattern matches (e.g. 'secret.conf:600'),
#                           the optional '@boot' registers the deployed file
#                           in /etc/rc.local (its remote path is inserted
#                           before the final 'exit 0', once — re-runs do not
#                           duplicate it), the optional '@keep' adds the
#                           remote path to /etc/sysupgrade.conf so the file
#                           is included in sysupgrade backups and survives
#                           firmware upgrades ('@boot@keep' combines both),
#                           '#' starts a comment, several lines per host
#                           are allowed and accumulate
#               DEPLOY_DIR  local source directory
#                           (default: deploy/ next to this script)
#               DEST_DIR    remote directory for the top-level files
#                           (default: /usr/bin). Files in subdirectories
#                           ignore DEST_DIR and mirror the device root fs
#                           instead: deploy/etc/config/foo -> /etc/config/foo
#               SSH_OPTS    extra ssh options, e.g. "-o ConnectTimeout=10"
#   -n        dry run: print what would be deployed, no ssh connections
#   -v        verbose output to stderr
#   host...   deploy only to these hosts (must be present in DEPLOY)

set -eu

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
    echo "Usage: $0 [-v] [-n] -c config [host...]" >&2
    exit 1
}

VERBOSE=0
DRY_RUN=0
CONFIG=
while getopts "vnc:" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        n) DRY_RUN=1 ;;
        c) CONFIG=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

# --- config -------------------------------------------------------------------

[ -n "$CONFIG" ] || { echo "ERROR: config file is required (-c FILE)" >&2; usage; }

DEPLOY=
DEPLOY_DIR="$SCRIPT_DIR/deploy"
DEST_DIR=/usr/bin
SSH_OPTS=
load_config "$CONFIG"

[ -n "$DEPLOY" ]     || die "DEPLOY map is not set in $CONFIG"
[ -d "$DEPLOY_DIR" ] || die "DEPLOY_DIR '$DEPLOY_DIR' does not exist"

# --- DEPLOY map parsing ---------------------------------------------------------
# Map format, one entry per line: <[user@]host> <file|glob>...
# '#' starts a comment; blank and comment-only lines are skipped.

# Print the hosts of the map in order, duplicates removed. Subshell body:
# noglob must not leak, and the globs in the map must not expand here —
# they are expanded later, relative to DEPLOY_DIR
map_hosts() (
    set -f
    echo "$DEPLOY" | while IFS= read -r mh_line; do
        mh_line=${mh_line%%#*}
        # shellcheck disable=SC2086
        set -- $mh_line
        [ $# -ge 2 ] && echo "$1"
    done | awk '!seen[$0]++'
)

# Print the file patterns mapped to a host; $1 = [user@]host as in the map.
# Subshell body for the same noglob reason as map_hosts.
patterns_for() (
    set -f
    pf_host=$1
    echo "$DEPLOY" | while IFS= read -r pf_line; do
        pf_line=${pf_line%%#*}
        # shellcheck disable=SC2086
        set -- $pf_line
        [ $# -ge 2 ] || continue
        pf_h=$1
        shift
        [ "$pf_h" = "$pf_host" ] && echo "$*"
    done
)

# Register a deployed file in the boot sequence: its path goes into
# /etc/rc.local before the final 'exit 0' (or is appended when there is no
# such line). Idempotent: an already-present line is left alone.
# $1 = host, $2 = remote path; prints 'added' when rc.local was changed.
ensure_startup() {
    # the remote path is embedded locally on purpose (SC2029)
    # shellcheck disable=SC2086,SC2029
    ssh $SSH_OPTS "$1" "CMD='$2' RC=/etc/rc.local sh -s" <<'REMOTE'
set -eu
grep -qxF "$CMD" "$RC" 2>/dev/null && exit 0
if grep -q '^exit 0' "$RC" 2>/dev/null; then
    awk -v c="$CMD" '!d && /^exit 0/ { print c; d=1 } { print }' "$RC" > "$RC.tmp"
    cat "$RC.tmp" > "$RC"
    rm -f "$RC.tmp"
else
    echo "$CMD" >> "$RC"
fi
echo added
REMOTE
}

# Add a deployed file to /etc/sysupgrade.conf so sysupgrade backups include
# it and it survives firmware upgrades. Idempotent: an already-present line
# is left alone. $1 = host, $2 = remote path; prints 'added' on change.
ensure_keep() {
    # the remote path is embedded locally on purpose (SC2029)
    # shellcheck disable=SC2086,SC2029
    ssh $SSH_OPTS "$1" "CMD='$2' CFG=/etc/sysupgrade.conf sh -s" <<'REMOTE'
set -eu
grep -qxF "$CMD" "$CFG" 2>/dev/null && exit 0
echo "$CMD" >> "$CFG"
echo added
REMOTE
}

# md5 digest of a local file. md5sum on Linux, BSD md5 on macOS; md5 and
# not cksum because the busybox cksum applet is disabled in the default
# OpenWrt build (BUSYBOX_DEFAULT_CKSUM=n) while md5sum is enabled.
local_md5() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum < "$1" | awk '{print $1}'
    else
        md5 -q "$1"
    fi
}

# Remote destination for one DEPLOY_DIR-relative path: top-level files go
# to DEST_DIR, files in subdirectories mirror the device root fs
dest_for() {
    case $1 in
        */*) echo "/$1" ;;
        *)   echo "$DEST_DIR/$1" ;;
    esac
}

MAP_HOSTS=$(map_hosts)
[ -n "$MAP_HOSTS" ] || die "DEPLOY map in $CONFIG has no valid '<host> <files>' lines"

# Positional args narrow the host list; they match the map entry with or
# without its user@ part
if [ $# -ge 1 ]; then
    HOSTS=
    for want in "$@"; do
        found=
        for h in $MAP_HOSTS; do
            if [ "$h" = "$want" ] || [ "${h#*@}" = "$want" ]; then
                found=$h
                break
            fi
        done
        [ -n "$found" ] || die "host '$want' not found in the DEPLOY map"
        HOSTS="$HOSTS $found"
    done
else
    HOSTS=$MAP_HOSTS
fi

# --- ssh setup ------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
    # One authenticated (multiplexed) connection per host: every ssh call
    # after the first reuses the master. The socket path must stay under the
    # ~104-byte unix-socket limit, hence the short /tmp template instead of
    # the (long on macOS) default TMPDIR
    CTL_DIR=$(mktemp -d /tmp/dw.XXXXXX 2>/dev/null) || CTL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dw.XXXXXX")
    trap 'rm -rf "$CTL_DIR"' EXIT
    SSH_OPTS="$SSH_OPTS -o ControlMaster=auto -o ControlPath=$CTL_DIR/%C -o ControlPersist=90"
fi

# --- run ------------------------------------------------------------------------

FAILED=
OK=0
UNCHANGED=0
# noglob for the whole loop: patterns from the map must only expand inside
# the DEPLOY_DIR subshell below, never against the current directory
set -f
for host in $HOSTS; do
    patterns=$(patterns_for "$host")

    # Expand the globs relative to DEPLOY_DIR; a pattern with no match is a
    # config error for this host, not something to skip silently. Each
    # expanded file is stored as '<file>:<mode>:<boot>:<keep>' ('-' = mode
    # not forced; boot/keep = 0/1 for the @boot/@keep suffixes).
    files=
    bad_pattern=
    for pat in $patterns; do
        fboot=0
        fkeep=0
        while :; do
            case $pat in
                *@boot) fboot=1; pat=${pat%@boot} ;;
                *@keep) fkeep=1; pat=${pat%@keep} ;;
                *) break ;;
            esac
        done
        fmode=-
        case $pat in
            *:*)
                fmode=${pat##*:}
                pat=${pat%:*}
                case $fmode in
                    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
                    *) die "invalid mode '$fmode' in pattern '$pat:$fmode' (host $host)" ;;
                esac
                ;;
        esac
        matched=$(cd "$DEPLOY_DIR" && set +f && for f in $pat; do [ -f "$f" ] && echo "$f"; done) || :
        if [ -n "$matched" ]; then
            for m in $matched; do
                files="$files $m:$fmode:$fboot:$fkeep"
            done
        else
            bad_pattern="$bad_pattern $pat"
        fi
    done
    if [ -n "$bad_pattern" ]; then
        echo "FAILED: $host (no files match '${bad_pattern# }' in $DEPLOY_DIR)" >&2
        FAILED="$FAILED $host/pattern"
        continue
    fi

    if [ "$DRY_RUN" = 1 ]; then
        for entry in $files; do
            keep=${entry##*:}
            entry=${entry%:*}
            boot=${entry##*:}
            entry=${entry%:*}
            mode=${entry##*:}
            f=${entry%:*}
            if [ "$mode" = - ]; then
                if [ -x "$DEPLOY_DIR/$f" ]; then mode=755; else mode=644; fi
            fi
            note=
            [ "$boot" = 1 ] && note="$note, startup"
            [ "$keep" = 1 ] && note="$note, keep"
            echo "would deploy: $host $DEPLOY_DIR/$f -> $(dest_for "$f") (mode $mode$note)"
        done
        continue
    fi

    # Probe once so a dead host fails here with a visible ssh error instead
    # of as a chain of per-file failures (also warms up the control master)
    # shellcheck disable=SC2086
    if ! ssh $SSH_OPTS "$host" :; then
        echo "FAILED: $host (ssh connection failed)" >&2
        FAILED="$FAILED $host/connect"
        continue
    fi

    for entry in $files; do
        keep=${entry##*:}
        entry=${entry%:*}
        boot=${entry##*:}
        entry=${entry%:*}
        mode=${entry##*:}
        f=${entry%:*}
        src="$DEPLOY_DIR/$f"
        dest=$(dest_for "$f")
        if [ "$mode" = - ]; then
            if [ -x "$src" ]; then mode=755; else mode=644; fi
        fi

        # Skip the upload when the remote copy is already identical; a
        # missing remote file or a failed check just means "upload". The
        # chmod rides along so a mode change in the config is applied even
        # when the content itself has not changed.
        local_sum=$(local_md5 "$src")
        # the remote path is built locally on purpose (SC2029)
        # shellcheck disable=SC2086,SC2029
        remote_sum=$(ssh $SSH_OPTS "$host" "md5sum < '$dest' && chmod $mode '$dest'" 2>/dev/null) || remote_sum=
        remote_sum=${remote_sum%% *}   # md5sum on stdin prints 'digest  -'
        if [ -n "$remote_sum" ] && [ "$remote_sum" = "$local_sum" ]; then
            vlog "$host: $f unchanged, skipping"
            UNCHANGED=$((UNCHANGED + 1))
        else
            # Stream through ssh into a .part file and mv into place so an
            # interrupted transfer never leaves a truncated script behind
            vlog "$host: $src -> $dest (mode $mode)"
            dest_dir=$(dirname "$dest")
            # shellcheck disable=SC2086,SC2029
            if ssh $SSH_OPTS "$host" "mkdir -p '$dest_dir' \
                    && cat > '$dest.part' \
                    && chmod $mode '$dest.part' \
                    && mv '$dest.part' '$dest'" < "$src"; then
                echo "OK: $host $f -> $dest"
                OK=$((OK + 1))
            else
                echo "FAILED: $host $f" >&2
                FAILED="$FAILED $host/$f"
                continue
            fi
        fi

        # @boot/@keep: make sure the file is registered — checked even when
        # the upload was skipped, the config line may still be missing
        if [ "$boot" = 1 ]; then
            if startup_out=$(ensure_startup "$host" "$dest"); then
                [ -n "$startup_out" ] && echo "OK: $host $dest added to /etc/rc.local"
            else
                echo "FAILED: $host $f (rc.local update)" >&2
                FAILED="$FAILED $host/$f:startup"
            fi
        fi
        if [ "$keep" = 1 ]; then
            if keep_out=$(ensure_keep "$host" "$dest"); then
                [ -n "$keep_out" ] && echo "OK: $host $dest added to /etc/sysupgrade.conf"
            else
                echo "FAILED: $host $f (sysupgrade.conf update)" >&2
                FAILED="$FAILED $host/$f:keep"
            fi
        fi
    done
done

[ "$DRY_RUN" = 0 ] && echo "done: $OK deployed, $UNCHANGED unchanged${FAILED:+, failed:$FAILED}"
[ -z "$FAILED" ]
