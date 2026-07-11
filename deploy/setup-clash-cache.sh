#!/bin/sh
# Keeps the clash cache.db on tmpfs: replaces cache.db in the clash dir with
# a symlink into /tmp, so the frequent runtime writes do not wear the flash.
# Runs on the device; idempotent, safe to re-run. /tmp is cleared on reboot,
# so run it on boot before clash starts (e.g. from rc.local or the clash
# init script) to recreate the tmpfs directory.
set -eu

CLASH_DIR="/opt/clash"
CLASH_TMPFS="/tmp/clash"
CACHE_LINK="$CLASH_DIR/cache.db"
CACHE_TMPFS="$CLASH_TMPFS/cache.db"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

mkdir -p "$CLASH_TMPFS" || die "cannot create directory $CLASH_TMPFS"

# Replace whatever sits at CACHE_LINK (an old real cache file or a stale
# link) with the tmpfs symlink; nothing to do when it already points there
if [ "$(readlink "$CACHE_LINK" 2>/dev/null)" != "$CACHE_TMPFS" ]; then
    rm -rf "$CACHE_LINK"
    ln -s "$CACHE_TMPFS" "$CACHE_LINK" || die "cannot create symlink $CACHE_LINK -> $CACHE_TMPFS"
    echo "created symlink $CACHE_LINK -> $CACHE_TMPFS"
fi
