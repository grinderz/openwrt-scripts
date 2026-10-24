#!/bin/sh
# Extracts the root filesystem from an OpenWrt firmware image: finds the
# SquashFS offset with binwalk, carves the filesystem out and unpacks it
# with unsquashfs. Needs binwalk and squashfs-tools locally.
#
# Usage:   ./unpack-firmware.sh [-v] [-n] firmware.bin
# Output:  <firmware>-root/ (extension stripped) next to the image
#
#   -n        dry run: locate the SquashFS and report the output directory,
#             extract nothing
#   -v        verbose output to stderr

set -eu

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
    echo "Usage: $0 [-v] [-n] firmware.bin" >&2
    exit 1
}

VERBOSE=0
DRY_RUN=0
while getopts "vn" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        n) DRY_RUN=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[ $# -eq 1 ] || usage
img=$1

[ -f "$img" ] || die "image '$img' not found"
command -v binwalk     >/dev/null 2>&1 || die "binwalk is required"
command -v unsquashfs  >/dev/null 2>&1 || die "unsquashfs is required (squashfs-tools)"

out="${img%.*}-root"
[ -e "$out" ] && die "output directory '$out' already exists"

# First SquashFS signature in the image (binwalk column 1 = decimal offset);
# the match is case-insensitive, binwalk versions spell it differently.
# awk reads the whole output on purpose: an early exit closes the pipe and
# newer (rust) binwalk panics on the resulting EPIPE
off=$(binwalk "$img" | awk '!found && tolower($0) ~ /squashfs/ {print $1; found=1}')
[ -n "$off" ] || die "no SquashFS filesystem found in '$img'"
vlog "SquashFS at offset $off"

if [ "$DRY_RUN" = 1 ]; then
    echo "dry run: SquashFS at offset $off in $img, would extract to $out"
    exit 0
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# tail instead of dd: the offset is not necessarily block-aligned
tail -c "+$((off + 1))" "$img" > "$TMP_DIR/rootfs.squashfs"
unsquashfs -d "$out" "$TMP_DIR/rootfs.squashfs"
echo "extracted to $out"
