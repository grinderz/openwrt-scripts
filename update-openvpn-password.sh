#!/bin/sh
# Updates the OpenVPN password of a luci-proto-openvpn interface on a remote
# OpenWrt device and restarts the interface. The credential location is
# detected automatically:
#   uci    — option 'username'/'password' of the interface in
#            /etc/config/network (native luci-proto-openvpn fields)
#   inline — <auth-user-pass> block inside the .ovpn file referenced by
#            option 'config' (username on the first line, password on the
#            second)
#   file   — separate credentials file referenced by an 'auth-user-pass PATH'
#            directive inside the .ovpn file
#
# Usage:   ./update-openvpn-password.sh [-v] [-n] [-u username] [-p password] [-c config] [ssh options...]
# Example: ./update-openvpn-password.sh -c update-openvpn-password.conf
#
#   -c file      config file, shell KEY=VALUE format, see
#                update-openvpn-password.conf.example; default when omitted:
#                $XDG_CONFIG_HOME/openwrt-scripts/update-openvpn-password.conf. Recognized keys:
#                  HOST      [user@]host of the device (required)
#                  IFACE     interface name with proto 'openvpn' (required)
#                  USERNAME  also update the username (optional)
#                  PASSWORD_CMD  shell command that prints the new password
#                            on its first stdout line, e.g. a password
#                            manager lookup: PASSWORD_CMD="pass show vpn/rtr1"
#                            (optional; -p takes precedence)
#                  WAIT      seconds to wait for the interface to come up
#                            after the restart, 0 disables the check
#                            (optional, default 30)
#   -p password  new password. Without -p it comes from PASSWORD_CMD if set,
#                otherwise from stdin: either interactively (silent prompt)
#                or piped, e.g.:
#                  pass show vpn/rtr1 | ./update-openvpn-password.sh -c rtr1.conf
#   -u username  also update the username (overrides USERNAME from config)
#   -n           dry run: show what would be changed, do not modify anything
#   -v           verbose output to stderr
#
# The password never appears on a command line (local or remote): it travels
# base64-encoded over the ssh stdin, so it is not visible in ps on either side.

set -eu

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
    echo "Usage: $0 [-v] [-n] [-u username] [-p password] [-c config] [ssh options...]" >&2
    exit 1
}

VERBOSE=0
DRYRUN=0
CONFIG=
PASSWORD=
USERNAME_ARG=
while getopts "vnc:p:u:" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        n) DRYRUN=1 ;;
        c) CONFIG=$OPTARG ;;
        p) PASSWORD=$OPTARG ;;
        u) USERNAME_ARG=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

# --- config -------------------------------------------------------------------

[ -n "$CONFIG" ] || CONFIG=$(default_config update-openvpn-password)

HOST=
IFACE=
USERNAME=
PASSWORD_CMD=
WAIT=30
load_config "$CONFIG"

[ -n "$HOST" ]  || die "HOST is not set in $CONFIG"
[ -n "$IFACE" ] || die "IFACE is not set in $CONFIG"
check_uint WAIT "$WAIT"
[ -n "$USERNAME_ARG" ] && USERNAME=$USERNAME_ARG

vlog "config: $CONFIG (host: $HOST, interface: $IFACE)"

# --- password -----------------------------------------------------------------

if [ -z "$PASSWORD" ] && [ -n "$PASSWORD_CMD" ]; then
    # First stdout line of the command; its own newline is stripped by read
    vlog "password: running PASSWORD_CMD"
    PASSWORD=$(eval "$PASSWORD_CMD") || die "PASSWORD_CMD failed: $PASSWORD_CMD"
    PASSWORD=${PASSWORD%%
*}
    [ -n "$PASSWORD" ] || die "PASSWORD_CMD produced no output: $PASSWORD_CMD"
fi

if [ -z "$PASSWORD" ]; then
    if [ -t 0 ]; then
        # Interactive: silent prompt, echo disabled for the duration of read
        printf 'New OpenVPN password for %s on %s: ' "$IFACE" "$HOST" >&2
        stty -echo
        trap 'stty echo' EXIT INT TERM
        IFS= read -r PASSWORD
        stty echo
        trap - EXIT INT TERM
        echo >&2
    else
        # Piped: first line of stdin (trailing newline stripped by read)
        IFS= read -r PASSWORD || true
    fi
fi
[ -n "$PASSWORD" ] || die "password is empty"

# base64 makes the values safe to embed into the remote script regardless of
# quotes/newlines in the password, and keeps them off the ssh command line
PW_B64=$(printf '%s' "$PASSWORD" | base64 | tr -d '\n')
USER_B64=
[ -n "$USERNAME" ] && USER_B64=$(printf '%s' "$USERNAME" | base64 | tr -d '\n')

# --- remote update ------------------------------------------------------------

# Everything runs on the device in a single ssh call. The variable block is
# prepended to the script and both travel over stdin, so no secret ever
# becomes a command-line argument.
{
    printf "VERBOSE='%s' DRYRUN='%s' HOST='%s' IFACE='%s' WAIT='%s'\n" \
        "$VERBOSE" "$DRYRUN" "$HOST" "$IFACE" "$WAIT"
    printf "PW_B64='%s' USER_B64='%s'\n" "$PW_B64" "$USER_B64"
    cat <<'REMOTE'
set -eu

vlog() {
    if [ "$VERBOSE" = 1 ]; then
        echo "# $*" >&2
    fi
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

vlog "host: $(uname -n), $(. /etc/openwrt_release 2>/dev/null && echo "$DISTRIB_DESCRIPTION" || echo unknown)"

proto=$(uci -q get "network.$IFACE.proto") \
    || die "interface '$IFACE' not found in /etc/config/network"
[ "$proto" = openvpn ] \
    || die "interface '$IFACE' has proto '$proto', expected 'openvpn' (luci-proto-openvpn)"

pw=$(echo "$PW_B64" | base64 -d)
user=
[ -n "$USER_B64" ] && user=$(echo "$USER_B64" | base64 -d)

# --- detect where the credentials live ---
ovpn=$(uci -q get "network.$IFACE.config" || echo '')
mode=
auth_file=
if uci -q get "network.$IFACE.password" >/dev/null \
   || uci -q get "network.$IFACE.username" >/dev/null; then
    mode=uci
elif [ -n "$ovpn" ] && [ -f "$ovpn" ] && grep -q '^<auth-user-pass>' "$ovpn"; then
    mode=inline
elif [ -n "$ovpn" ] && [ -f "$ovpn" ]; then
    # 'auth-user-pass PATH' directive pointing to a separate credentials file
    auth_file=$(sed -n 's/^auth-user-pass[ 	][ 	]*//p' "$ovpn" | head -n 1)
    [ -n "$auth_file" ] && mode=file
fi
[ -n "$mode" ] || die "cannot find credentials for '$IFACE': no username/password
       in uci, and the .ovpn file ('$ovpn') has no <auth-user-pass> block or
       'auth-user-pass PATH' directive. Set the credentials once in LuCI first."
vlog "credentials location: $mode${ovpn:+ (config: $ovpn)}${auth_file:+ -> $auth_file}"

if [ "$DRYRUN" = 1 ]; then
    # HOST is the name from the config, uname -n is what the device calls itself
    echo "dry run: $HOST ($(uname -n)), interface '$IFACE', credentials: $mode"
    case $mode in
        uci)    echo "dry run [$mode]: would set network.$IFACE.password (${#pw} chars)" ;;
        inline) echo "dry run [$mode]: would replace password inside <auth-user-pass> block of $ovpn (${#pw} chars)" ;;
        file)   echo "dry run [$mode]: would rewrite $auth_file (${#pw} chars)" ;;
    esac
    [ -n "$user" ] && echo "dry run [$mode]: would set username '$user'"
    exit 0
fi

case $mode in
uci)
    # uci set takes the whole assignment as a single argument, so the
    # password needs no extra quoting or escaping here
    uci set "network.$IFACE.password=$pw"
    [ -n "$user" ] && uci set "network.$IFACE.username=$user"
    uci commit network
    vlog "committed network.$IFACE"
    ;;
inline)
    # Replace the 2nd line of the <auth-user-pass> block (password) and,
    # if given, the 1st (username). Values are passed via the environment:
    # awk -v would mangle backslashes in the password.
    tmp="$ovpn.tmp.$$"
    pw="$pw" user="$user" awk '
        /^<auth-user-pass>/  { print; inblk = 1; ln = 0; next }
        /^<\/auth-user-pass>/ { inblk = 0; print; next }
        inblk {
            ln++
            if (ln == 1 && ENVIRON["user"] != "") { print ENVIRON["user"]; next }
            if (ln == 2)                          { print ENVIRON["pw"];   next }
        }
        { print }
    ' "$ovpn" > "$tmp"
    # cat instead of mv keeps the original file's owner and permissions
    cat "$tmp" > "$ovpn"
    rm -f "$tmp"
    vlog "updated <auth-user-pass> block in $ovpn"
    ;;
file)
    # Standard auth-user-pass file: username on line 1, password on line 2
    if [ -z "$user" ]; then
        user=$(head -n 1 "$auth_file" 2>/dev/null || echo '')
        [ -n "$user" ] || die "credentials file '$auth_file' is missing or empty and no username was given (-u)"
    fi
    umask 077
    printf '%s\n%s\n' "$user" "$pw" > "$auth_file"
    vlog "rewrote $auth_file"
    ;;
esac

vlog "restarting interface"
ifup "$IFACE"

[ "$WAIT" = 0 ] && exit 0

# Wait for the interface to come up: a wrong password shows up as the
# interface staying down (openvpn keeps retrying after AUTH_FAILED)
i=0
while [ "$i" -lt "$WAIT" ]; do
    sleep 1
    i=$((i + 1))
    up=$(ubus call "network.interface.$IFACE" status 2>/dev/null \
        | jsonfilter -e '@.up' 2>/dev/null) || up=
    if [ "$up" = true ]; then
        echo "OK: interface '$IFACE' is up (${i}s)"
        exit 0
    fi
done
echo "WARNING: interface '$IFACE' did not come up within ${WAIT}s" >&2
echo "         check the password and 'logread -e openvpn' on the device" >&2
exit 2
REMOTE
} | ssh "$@" "$HOST" sh -s

if [ "$DRYRUN" = 0 ]; then
    echo "password updated on $HOST ($IFACE)"
fi
