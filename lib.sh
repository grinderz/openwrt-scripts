# Shared helpers for the scripts in this repo — source, do not execute:
#   . "$(dirname "$0")/lib.sh"
# Note: the remote heredoc parts of the scripts run on the device where this
# file does not exist, so they carry their own copies of vlog/die.
# shellcheck shell=sh

vlog() {
    if [ "${VERBOSE:-0}" = 1 ]; then
        echo "# $*" >&2
    fi
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Default config of a script when -c is not given:
# $XDG_CONFIG_HOME/openwrt-scripts/<name>.conf (dotfiles renders these from
# the router inventory in its private toml); $1 = name without .conf
default_config() {
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/openwrt-scripts/$1.conf"
}

# Check that a config file exists and source it; $1 = path
load_config() {
    [ -f "$1" ] || die "config file '$1' not found"
    # shellcheck disable=SC1090
    . "$1"
}

# Ensure the value is a non-negative integer; $1 = name for the error message,
# $2 = value
check_uint() {
    case $2 in
        ''|*[!0-9]*) die "$1 must be a number (got '$2')" ;;
    esac
}
