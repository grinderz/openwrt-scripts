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
"$ROOT/backup-openwrt.sh" -c "$TMP/does-not-exist.conf" >/dev/null 2>&1 && fail "backup-openwrt.sh ran with a missing config"

echo "OK"
