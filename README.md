# openwrt-scripts

A small collection of POSIX shell scripts for managing OpenWrt devices over
ssh. Nothing needs to be installed on the devices (one exception: `nand`
backups need `nand-utils`); everything runs from your workstation and talks
to the routers through plain `ssh`.

Common conventions:

- Scripts that take a config use plain shell `KEY=VALUE` files; a commented
  `*.conf.example` ships next to each script. Real `*.conf` files are
  git-ignored.
- Hosts are anything ssh accepts, including `~/.ssh/config` aliases and
  `user@host`.
- `-v` on any script prints verbose diagnostics to stderr.
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
./backup-openwrt.sh -c backup-openwrt.conf           # back up everything
./backup-openwrt.sh -c backup-openwrt.conf rtr1      # only this host
./backup-openwrt.sh -v -t "sysupgrade emmc" -c backup-openwrt.conf rtr1
```

Backups land in `BACKUP_DIR/<host>/<host>-<type>-<timestamp>.<ext>`.

## deploy.sh

Deploys files from a local `deploy/` directory to the devices. Which files
go to which host is defined by the `DEPLOY` map in the config. Files stream
through ssh (no scp/sftp server needed on the device), land atomically and
are skipped when the remote copy is already identical (md5 match).

```sh
cp deploy.conf.example deploy.conf                   # edit the DEPLOY map
./deploy.sh -n -c deploy.conf                        # dry run: show the plan
./deploy.sh -c deploy.conf                           # deploy everything
./deploy.sh -c deploy.conf rtr1-gl-mt6000            # only this host
```

The map is one line per host:
`<[user@]host> <file|glob>[:mode][@boot][@keep]...`, with globs relative
to `DEPLOY_DIR`, an optional octal mode per pattern and optional
`@boot`/`@keep` flags:

```sh
DEPLOY="
rtr1-gl-mt6000  setup-clash-cache.sh@boot@keep patch-fw4-offload.sh@boot@keep
rtr2            *                # everything from DEPLOY_DIR
root@10.0.0.3   patch-fw4-offload.sh@boot@keep etc/config/*:600
"
```

Without `:mode` the local executable bit decides: executable → 755,
otherwise 644. A mode change alone (same content) is applied via chmod
without re-uploading. `@boot` registers the deployed file in
`/etc/rc.local` so it runs at boot (inserted once before the final
`exit 0`; re-deploys do not duplicate the line). `@keep` adds it to
`/etc/sysupgrade.conf` so it is included in sysupgrade backups and
survives firmware upgrades — for `@boot` scripts outside `/etc` you
usually want `@boot@keep`, otherwise the rc.local entry survives the
upgrade but the script does not. Top-level files go to `DEST_DIR`
(default `/usr/bin`); files in subdirectories mirror the device root fs
instead: `deploy/etc/config/foo` → `/etc/config/foo`.

Device-side scripts shipped in `deploy/`:

| File | Purpose |
|---|---|
| `setup-clash-cache.sh` | keep the clash cache.db on tmpfs (symlink into /tmp) to spare the flash |
| `patch-fw4-offload.sh` | patch firewall4 so flow offload starts only after 30 packets |
| `patch-3ginfo.sh` | patch 3ginfo-lite to strip all control chars from modem responses |
| `modem-reset.sh` | hard-reset the modem via its reset GPIO (stops smstools3 first) |
| `modem-init.sh` | per-model USB modem init (qmi_wwan binding, Dell USB config, option ids) |
| `etc/hotplug.d/iface/99-clash-modem.sh` | (re)start clash once the modem interface has real connectivity |
| `etc/hotplug.d/usb/99-modems` | on modem add/remove: run modem-init, start/stop smstools3 |
| `etc/hotplug.d/net/30-irq-affinity` | per-board IRQ affinity profiles (one hot IRQ source per core) |

## list-user-packages.sh

Lists packages installed by the user on a device, i.e. not part of the
flashed image. Works with both opkg and apk firmwares. Comparison modes
(`-m`, required):

| Mode | How it decides |
|---|---|
| `rom` | diff against the package database in `/rom` (squashfs images) |
| `time` | `Installed-Time` heuristic — packages newer than the firmware build time (opkg only) |
| `rom-manifest` | packages baked into a custom image on top of the default set (`/rom` vs the official image manifest) |
| `time+rom-manifest` | union of the two: installed after flashing plus baked into the image |

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
```
