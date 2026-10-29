# AWS IoT Greengrass Lite on ESP32-S31 Linux

[AWS IoT Greengrass nucleus lite](https://github.com/aws-greengrass/aws-greengrass-lite)
on the ESP32-S31 Function-CoreBoard, connected over Ethernet, built from
public sources only. The complete nucleus runs: cloud and local
deployments, component lifecycle and health, fleet status, IPC, MQTT to
AWS IoT Core and the Token Exchange Service, in 16 MiB of RAM.

| Source | Pin |
| --- | --- |
| [Buildroot](https://gitlab.com/buildroot.org/buildroot) 2025.02.x LTS | `sources.lock` |
| [espressif/esp-buildroot-external](https://github.com/espressif/esp-buildroot-external) (`buildroot/v2025.02-esp32s31`) | `sources.lock` |
| [espressif/linux](https://github.com/espressif/linux) (`integration/v6.18-esp32s31`) | defconfig |
| [espressif/u-boot](https://github.com/espressif/u-boot) (`integration/v2024.07-esp32s31`) | defconfig |
| [espressif/opensbi](https://github.com/espressif/opensbi) (`integration/v1.6-esp32s31`) | defconfig |
| [espressif/esp-linux-bsp](https://github.com/espressif/esp-linux-bsp) (`integration/v1.0-esp32s31`) | via esp-buildroot-external |
| [aws-greengrass-lite](https://github.com/aws-greengrass/aws-greengrass-lite) v2.7.0 + `package/aws-greengrass-lite/*.patch` | package .mk |

This repository is a Buildroot `BR2_EXTERNAL` tree layered on top of
`esp-buildroot-external`. It uses Espressif's toolchain (musl), boot stack,
kernel and flash packaging, and adds:

- `package/aws-greengrass-lite`: Greengrass Lite v2.7.0 with four patches
  (developed on the `esp32s31/v2.7.0` branch of a local fork);
- `package/esp32s31-ggl-hello`: a native demo component;
- `configs/esp32s31_fcb_greengrass_defconfig` and `board/esp32s31-fcb`:
  kernel options, one OpenSBI patch, time synchronisation and the
  Greengrass init script.

## What is changed in the public sources, and why

Everything else is built as published. Each change is a patch file in this
repository, applied by Buildroot at build time:

| Change | Where | Why it is needed |
| --- | --- | --- |
| Recognize `riscv32` (+4 lines) | Greengrass Lite, patch 0001 | Upstream only knows riscv64: recipe platform matching and fleet status fail on this RV32 chip. |
| Build without systemd (`GGL_PORTABLE_CORE`, 6 files) | Greengrass Lite, patch 0002 | systemd does not fit in 16 MiB (below). Only affects builds with the option on. |
| `ggl-svc` service manager; non-systemd backends in `gghealthd` and `ggipc-auth` | Greengrass Lite, patch 0003 | Upstream runs every component as a systemd unit, reads health over D-Bus and authorizes IPC callers by their systemd cgroup; these are the places that talk to systemd. `ggl-svc` (new module) provides the same behaviour. Only built with `GGL_PORTABLE_CORE`. |
| Keep the IoT Jobs ID length on bootstrap resume (1 line) | Greengrass Lite, patch 0004 | Upstream bug, also on upstream main: every cloud deployment with a bootstrap step stays IN_PROGRESS forever after the device reboots. |
| Reset the whole chip on SBI reboot | OpenSBI, `board/esp32s31-fcb/patches/opensbi` | The public firmware reset only CPU core 0, so `reboot` hung the board until EN was pulsed; Greengrass reboots the device itself to finish bootstrap steps. |
| `CONFIG_CGROUPS=y` (no controllers) | kernel, `linux-ggl-svc.fragment` | `ggl-svc` puts each unit in its own cgroup, as systemd does, to tie processes to components for IPC authorization and stop. Costs ~37 KB of flash and ~8 KB of RAM. |
| NFS root, IP autoconfiguration | kernel, `linux-nfsroot.fragment` | Development setup (below). |

Patches 0001, 0002 and 0004 are independent of this board and are
candidates for upstream Greengrass Lite; 0003 is the bulk of the work and
only matters for systemd-free systems.

## Why no systemd

Greengrass Lite is built as a set of systemd services, but the ESP32-S31
gives Linux about 14.7 MiB. A glibc/systemd image of the same stack was
built and booted: it thrashes before Greengrass starts and takes over 12
minutes to reach a login (`docs/results.md`; the configuration is kept,
reproducibly, in `docs/systemd-evaluation`). The busybox image runs the
complete Greengrass Lite daemon set with ~5.7 MiB to spare. How the
systemd dependencies are replaced: `docs/architecture.md`.

## Development setup: NFS root

The boot stack and the XIP kernel are flashed to the 16 MiB NOR flash; the
root filesystem is mounted over NFSv3 from a workstation on the same
network (the kernel does DHCP itself: `ip=dhcp root=/dev/nfs`). Rebuilds
and redeployments need no reflashing.

A product would not depend on an NFS server: it would boot a
self-contained root from flash and keep `/var/lib/greengrass`
(credentials, configuration database, deployed components) on local
persistent storage, such as an SD card, eMMC, or a writable partition in a
larger flash.

## Usage

Prerequisites: Docker (NFS server), the AWS CLI with credentials, an
ESP32-S31-capable `esptool`, and the usual Buildroot host packages.

```sh
# 1. Build (fetches the pinned sources into ../deps; output in
#    ../out/esp32s31_fcb_greengrass). S31_NFS_SERVER is the workstation's
#    address on the board's network.
S31_NFS_SERVER=192.168.0.126 ESP_ESPTOOL=/path/to/esptool scripts/build.sh

# 2. Provision an AWS IoT Thing; credentials and the device config.yaml
#    go to ../secrets/<thing> (mode 0700), never into this repository.
scripts/aws-provision.sh esp32s31-fcb-eth

# 3. Start the NFS server and install the root filesystem, the device
#    credentials and a development SSH key into its export.
S31_NFS_CLIENT_NET=192.168.0.0/24 scripts/nfs-server.sh
scripts/nfs-deploy.sh esp32s31-fcb-eth
#    Redeploying to a running board is safe: it keeps its current tree
#    until it reboots. Stop Greengrass on it first, then reboot it.

# 4. Flash, after checking which chip is on the port.
ESP_ESPTOOL=/path/to/esptool scripts/flash.sh /dev/serial/by-id/<port> <chip-mac>

# 5. Deploy the demo component from the cloud (to the thing group
#    <thing>-group, created if needed).
scripts/aws-deploy-hello.sh esp32s31-fcb-eth

# 6. Check everything end to end: core units, local and cloud deployments,
#    removal, failure handling, IPC caller identity, a deployment that
#    reboots the device (bootstrap step) and a cold reset.
scripts/board-test.sh <board-ip> esp32s31-fcb-eth --cloud --reset <port> <chip-mac>
```

The board appears as a Greengrass core device (`linux`/`riscv32`) in the
AWS IoT Greengrass console. The demo component reads its configuration
over IPC, round-trips a message through local pub/sub and through AWS IoT
Core, and then publishes a heartbeat every 30 s on
`esp32s31/<thing>/heartbeat` (watch it in the AWS IoT MQTT test client).

On the board (`ssh -i ../secrets/ssh/id_ed25519 root@<board-ip>`):

```sh
/etc/init.d/S95greengrass status     # every unit: state, result, restarts
grep core.iotcored /var/log/messages # logs, by unit
ggl-cli deploy -r /usr/share/esp32s31-ggl-hello \
    -c com.espressif.esp32s31.Hello=1.0.0   # local deployment
```

Recipes given to `ggl-cli deploy -r` are copied with their file mode, and
components run as `gg_component`: keep them world-readable.

AWS prerequisites (one-time per account and region): a Token Exchange role
and IoT role alias (`GG_ROLE_ALIAS`, default
`ESP32S31GreengrassTokenExchangeAlias`), and a Greengrass service role
associated with the account. Without the service role association,
deployments are recorded but never reach the device.

Dropbear (SSH) is in the image for development and for
`scripts/board-test.sh` only; Greengrass does not use it. The serial
console is not a substitute here: opening the port resets the board.

The NFS export holds the device's private key: keep it restricted to the
board's subnet. Opening the board's USB-UART resets it (its CP2102N drives
EN); use SSH for inspection, and `tools/s31-console.py` when a console is
needed.

## Results

`docs/results.md`.
