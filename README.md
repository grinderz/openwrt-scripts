# openwrt-scripts

A small collection of POSIX shell scripts for managing OpenWrt devices over
ssh. Nothing needs to be installed on the devices (one exception: `nand`
backups need `nand-utils`); everything runs from your workstation and talks
to the routers through plain `ssh`.

Common conventions:

- Scripts that take a config use plain shell `KEY=VALUE` files; a commented
  `*.conf.example` ships next to each script. Without `-c` a script reads
  `~/.config/openwrt-scripts/<script>.conf` (`$XDG_CONFIG_HOME` honoured);
  the dotfiles repo renders those from one router inventory. Real `*.conf`
  files in the repo are git-ignored.
- Hosts are anything ssh accepts, including `~/.ssh/config` aliases and
  `user@host`.
- `-v` on any script prints verbose diagnostics to stderr.
- `-n` on any workstation script that changes something (`backup-openwrt.sh`,
  `update-openvpn-password.sh`, `unpack-firmware.sh`) is a dry run: it
  prints what would be done and changes nothing.
- `lib.sh` holds shared helpers (`vlog`, `die`, config loading) — it is
  sourced by the other scripts, not run directly.

## backup-openwrt.sh

Backs up a list of OpenWrt devices in one pass. A failure on one host does
not stop the others; a summary is printed at the end. Backups are verified,
written atomically (`.part` + `mv`) and optionally rotated (`KEEP`).

Backup types (per host, extensible — see the script header):

| Type | Contents |
|---|---|
| `sysupgrade` | standard config backup (`sysupgrade -b`), restorable via `sysupgrade -r` or LuCI |
| `packages` | list of installed packages (opkg or apk) |
| `user-packages` | packages installed by the user (via `list-user-packages.sh`) |
| `overlay` | full copy of the writable overlay (`/overlay/upper`) |
| `nor` | raw dump of all mtd partitions (NOR flash); off by default |
| `nand` | same for NAND, needs `nand-utils` on the device; off by default |
| `emmc` | raw dump of all eMMC partitions, gzipped on the device; off by default |

The raw dump types are off by default because the images contain secrets
(keys, passwords) and radio calibration data.

```sh
cp backup-openwrt.conf.example backup-openwrt.conf   # edit HOSTS, BACKUP_DIR, TYPES
./backup-openwrt.sh -n -c backup-openwrt.conf        # dry run: what would be written/pruned
./backup-openwrt.sh -c backup-openwrt.conf           # back up everything
./backup-openwrt.sh -c backup-openwrt.conf rtr1      # only this host
./backup-openwrt.sh -v -t "sysupgrade emmc" -c backup-openwrt.conf rtr1
```

Backups land in `BACKUP_DIR/<host>/<host>-<type>-<timestamp>.<ext>`.

## Device files

What used to be deployed from here (`deploy.sh`, the `deploy/` tree with
the patches, hotplug hooks, modem scripts, sysctl and the adblock feed list)
lives in the dotfiles repo now: `infra/files/openwrt/`, shipped by the
pyinfra deploys `openwrt-files` and `openwrt-adblock` from the same router
inventory that renders the configs of these scripts.

## list-user-packages.sh

Lists packages installed by the user on a device, i.e. not part of the
flashed image. Works with both opkg and apk firmwares. Comparison modes
(`-m`, required):

| Mode | How it decides |
|---|---|
| `rom` | diff against the package database in `/rom` (squashfs images) |
| `time` | `Installed-Time` heuristic — packages newer than the firmware build time (opkg only) |
| `rom-manifest` | packages baked into a custom image on top of the default set (`/rom` vs the official image manifest) |
| `time+rom-manifest` | union of the two: installed after flashing plus baked into the image (apk: the `/rom` diff stands in for `time`) |

Useful options: `-f top` keeps only packages nothing else depends on (what
was installed by hand); `-u` drops packages listed in the official image
manifest (hides stock packages that were merely upgraded); `-b file`
supplies the manifest for custom builds instead of downloading it.

```sh
./list-user-packages.sh -m rom root@192.168.1.1
./list-user-packages.sh -v -m rom -f top rtr1            # hand-installed only
./list-user-packages.sh -m time -u rtr2                  # non-squashfs image
./list-user-packages.sh -m rom-manifest -i -b custom.manifest rtr3
```

Output is one package name per line — feed it to `opkg install`/`apk add`
after a clean flash to rebuild the device.

## update-openvpn-password.sh

Updates the OpenVPN password (and optionally the username) of a
luci-proto-openvpn interface on a device and restarts the interface. The
credential location is detected automatically: uci options in
`/etc/config/network`, an inline `<auth-user-pass>` block in the `.ovpn`
file, or a separate `auth-user-pass PATH` credentials file. After the
restart it waits for the interface to come up, so a wrong password is
reported instead of silently retrying.

The password never appears on a command line (local or remote): it travels
base64-encoded over the ssh stdin. It comes from `-p`, from `PASSWORD_CMD`
in the config (e.g. a password manager lookup), or from stdin — an
interactive silent prompt or a pipe.

```sh
cp update-openvpn-password.conf.example rtr1-vpn.conf   # edit HOST, IFACE
./update-openvpn-password.sh -n -c rtr1-vpn.conf        # dry run
./update-openvpn-password.sh -c rtr1-vpn.conf           # prompts for the password
pass show vpn/rtr1 | ./update-openvpn-password.sh -c rtr1-vpn.conf
```

## unpack-firmware.sh

Extracts the root filesystem from a firmware image: finds the SquashFS
offset with `binwalk`, carves it out with `dd` and unpacks it with
`unsquashfs`. Needs `binwalk` and `squashfs-tools` locally.

```sh
./unpack-firmware.sh openwrt-24.10.2-ath79-generic-tl-wdr4300-v1-squashfs-sysupgrade.bin
# -> ./<image-name>-root/ with the unpacked root fs
./unpack-firmware.sh -n image.bin      # dry run: only report the SquashFS offset and target dir
```

## Development

`make lint` runs shellcheck over every script (POSIX sh dialect, the config
examples included) and the pre-commit hooks via `uvx pre-commit`;
`make test` runs `tests/smoke.sh`: the dry-run paths of the scripts against
generated configs, no ssh and no device needed. CI
(`.github/workflows/ci.yml`) runs the same two targets on every push and
pull request; Renovate keeps the action and hook pins current.
