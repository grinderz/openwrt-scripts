#!/bin/sh
# Patches 3ginfo-lite (/usr/share/3ginfo-lite/3ginfo.sh) to strip all control
# characters from modem responses instead of just CR/LF: raw AT output can
# carry stray control bytes that break the JSON in LuCI. Two changes:
#   tr -d '\r\n'  ->  tr -d '\000-\037'      (global response cleanup)
#   sanitize_number() additionally pipes through the same tr
# Runs on the device; idempotent, exits silently when the package is not
# installed and refuses to touch the file when the expected upstream code
# is not there. A package upgrade brings the stock file back — keep it in
# the boot sequence (@boot@keep in deploy.conf) to re-apply.
set -eu

F=/usr/share/3ginfo-lite/3ginfo.sh
TAG=3ginfo-patch

# Literal strings for grep -F (the shell turns \\ into \)
OLD_PATTERN="tr -d '\\r\\n'"
NEW_PATTERN="tr -d '\\000-\\037'"
SANITIZE_PATCHED="echo \"\$1\" | tr -d '\\000-\\037'"

log() {
    logger -t "$TAG" "$*"
    echo "$*" >&2
}

die() {
    log "$*"
    exit 1
}

# Both changes must be present for the file to count as patched
is_patched() {
    grep -qF "$NEW_PATTERN" "$1" && grep -qF "$SANITIZE_PATCHED" "$1"
}

[ -f "$F" ] || exit 0            # package not installed
is_patched "$F" && exit 0        # already fully patched

# Target code missing (upstream changed) — leave the file alone
grep -qF "$OLD_PATTERN" "$F" || die "WARNING: target pattern not found in $F, patch NOT applied"

# Patch a copy and validate it before it replaces the original
TMP=$(mktemp) || die "ERROR: mktemp failed"
trap 'rm -f "$TMP"' EXIT
cp "$F" "$TMP"

sed -i "s/tr -d '\\\\r\\\\n'/tr -d '\\\\000-\\\\037'/" "$TMP"
sed -i "/^sanitize_number() {/{n;s/echo \"\$1\"\$/echo \"\$1\" | tr -d '\\\\000-\\\\037'/;}" "$TMP"

# Validate: syntax intact AND both changes actually applied
sh -n "$TMP" 2>/dev/null || die "ERROR: patch broke syntax, original untouched"
is_patched "$TMP"        || die "ERROR: patch incomplete, original untouched"

# cat instead of mv keeps the original owner and permissions
cat "$TMP" > "$F" || die "ERROR: write to $F failed, file may be corrupted"
log "patch applied"
