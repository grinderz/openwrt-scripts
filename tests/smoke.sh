#!/bin/sh
# Smoke test of the dry-run paths: everything that needs neither ssh nor a
# device. Configs are generated in a temp dir; the scripts must plan the
# right actions, refuse broken input and leave the filesystem alone.
#
# Usage: tests/smoke.sh    (from any cwd; make test)
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# $1 = file, $2 = expected count, $3 = grep pattern
expect_count() {
    n=$(grep -c -- "$3" "$1" || :)
    [ "$n" = "$2" ] || fail "expected $2 lines matching '$3', got $n:
$(cat "$1")"
}

echo "== deploy.sh -n"
cat > "$TMP/deploy.conf" <<CONF
DEPLOY="
rtr1        *@boot@keep etc/hotplug.d/*/*
root@rtr2   patch-fw4-offload.sh:700 etc/sysctl.d/*   # mode override, root fs mirror
"
CONF
# run with a bare relative config name: '.' must source it from the cwd
(cd "$TMP" && "$ROOT/deploy.sh" -n -c deploy.conf) > "$TMP/deploy.out" || fail "deploy.sh -n exited $?"
expect_count "$TMP/deploy.out" 1 '^would deploy: rtr1 .*/setup-clash-cache.sh -> /usr/bin/setup-clash-cache.sh (mode 755, startup, keep)$'
expect_count "$TMP/deploy.out" 1 '^would deploy: rtr1 .*/etc/hotplug.d/usb/99-modems -> /etc/hotplug.d/usb/99-modems (mode 644)$'
expect_count "$TMP/deploy.out" 1 '^would deploy: root@rtr2 .*/patch-fw4-offload.sh -> /usr/bin/patch-fw4-offload.sh (mode 700)$'
expect_count "$TMP/deploy.out" 1 '^would deploy: root@rtr2 .*/etc/sysctl.d/12-tcp-tuning.conf -> /etc/sysctl.d/12-tcp-tuning.conf (mode 644)$'
expect_count "$TMP/deploy.out" 0 'OK:'
# a pattern without a match is a config error for that host
echo 'DEPLOY="rtr1 no-such-file*"' > "$TMP/deploy-bad.conf"
"$ROOT/deploy.sh" -n -c "$TMP/deploy-bad.conf" >/dev/null 2>&1 && fail "deploy.sh -n accepted an unmatched pattern"
"$ROOT/deploy.sh" -n -c "$TMP/deploy.conf" nope >/dev/null 2>&1 && fail "deploy.sh -n accepted a host missing from the map"

echo "== backup-openwrt.sh -n"
mkdir -p "$TMP/bk/rtr1"
for t in 20250101-000000 20250201-000000 20250301-000000; do
    : > "$TMP/bk/rtr1/rtr1-sysupgrade-$t.tar.gz"
done
printf 'HOSTS="rtr1 root@rtr2"\nBACKUP_DIR="%s"\nTYPES="sysupgrade packages"\nKEEP=2\n' "$TMP/bk" > "$TMP/backup.conf"
"$ROOT/backup-openwrt.sh" -n -c "$TMP/backup.conf" > "$TMP/backup.out" || fail "backup-openwrt.sh -n exited $?"
expect_count "$TMP/backup.out" 4 '^would back up: '
expect_count "$TMP/backup.out" 2 '^would back up: root@rtr2 .* -> .*/bk/rtr2/rtr2-'
# KEEP=2 with three old archives plus the planned one: the two oldest go
expect_count "$TMP/backup.out" 2 '^would prune: '
expect_count "$TMP/backup.out" 1 '^would prune: .*/rtr1-sysupgrade-20250101-000000.tar.gz$'
expect_count "$TMP/backup.out" 1 '^would prune: .*/rtr1-sysupgrade-20250201-000000.tar.gz$'
[ -e "$TMP/bk/rtr1/rtr1-sysupgrade-20250101-000000.tar.gz" ] || fail "dry run pruned a file"
[ ! -e "$TMP/bk/rtr2" ] || fail "dry run created a host directory"
"$ROOT/backup-openwrt.sh" -n -t bogus -c "$TMP/backup.conf" >/dev/null 2>&1 && fail "backup-openwrt.sh -n accepted an unknown type"

echo "== usage errors"
"$ROOT/unpack-firmware.sh" -n >/dev/null 2>&1 && fail "unpack-firmware.sh -n ran without an image"
"$ROOT/list-user-packages.sh" >/dev/null 2>&1 && fail "list-user-packages.sh ran without -m"
"$ROOT/deploy.sh" -c "$TMP/does-not-exist.conf" >/dev/null 2>&1 && fail "deploy.sh ran with a missing config"

echo "OK"
