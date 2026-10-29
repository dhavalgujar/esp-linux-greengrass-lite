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
kernel and flash packaging.

## Repository layout

```text
esp32s31-greengrass-lite/
├── configs/        Buildroot defconfig
├── board/          kernel fragments, OpenSBI patch, root filesystem overlay
├── package/        Greengrass Lite (v2.7.0 + 5 patches), demo component
├── examples/       the demo component, as a self-contained example
├── scripts/        build, flash, NFS deployment, AWS setup, board tests
├── nfs-server/     container for the NFS root server
├── aws/            device configuration and IoT policy templates
├── docs/           architecture, results, the rejected systemd evaluation
└── tools/          serial console helper
```

- `package/aws-greengrass-lite`: Greengrass Lite v2.7.0 with five patches
  (developed on the `esp32s31/v2.7.0` branch of a local fork);
- `examples/cloud/greengrass-hello`: the demo component
  (`com.espressif.esp32s31.Hello`), laid out as the examples in
  [espressif/esp-linux-examples](https://github.com/espressif/esp-linux-examples)
  are: its own README with troubleshooting, Makefile and recipe. The
  Buildroot package `package/esp32s31-ggl-hello` builds it with that
  Makefile;
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
| Retry the fleet provisioning certificate request until connected | Greengrass Lite, patch 0005 | Upstream waits a fixed 5 s for its MQTT connection before the request; the TLS connection takes ~11 s on this chip, so provisioning always failed. |
| Reset the whole chip on SBI reboot | OpenSBI, `board/esp32s31-fcb/patches/opensbi` | The public firmware reset only CPU core 0, so `reboot` hung the board until EN was pulsed; Greengrass reboots the device itself to finish bootstrap steps. |
| `CONFIG_CGROUPS=y` (no controllers) | kernel, `linux-ggl-svc.fragment` | `ggl-svc` puts each unit in its own cgroup, as systemd does, to tie processes to components for IPC authorization and stop. Costs ~37 KB of flash and ~8 KB of RAM. |
| NFS root, IP autoconfiguration | kernel, `linux-nfsroot.fragment` | Development setup (below). |

Patches 0001, 0002, 0004 and 0005 are independent of this board and are
candidates for upstream Greengrass Lite; 0003 is the bulk of the work and
only matters for systemd-free systems.

## Why no systemd

Greengrass Lite is built as a set of systemd services, but the ESP32-S31
gives Linux about 14.7 MiB. A glibc/systemd image of the same stack was
built and booted: it thrashes before Greengrass starts and takes over 12
minutes to reach a login (`docs/results.md`; the configuration is kept,
reproducibly, in `docs/systemd-evaluation`). The busybox image runs the
complete Greengrass Lite daemon set with ~5.5 MiB to spare. How the
systemd dependencies are replaced: `docs/architecture.md`.

## ggl-svc: why a purpose-built service manager

`ggl-svc` (patch 0003) is not a replacement init system: busybox init
runs the system, and `/etc/init.d/S95greengrass` starts `ggl-svcd`, which
runs only Greengrass's units. It implements the part of systemd that
Greengrass Lite depends on, and nothing else:

1. a `systemctl` that `ggdeploymentd` drives (`link`, `enable`,
   `start --no-block`, `stop`, `disable`, `daemon-reload`,
   `reset-failed`, `reboot`);
2. systemd unit files generated at deployment time by `recipe2unit`
   (`Type=oneshot|notify|exec`, `RemainAfterExit`, `Restart`, start
   limits, `After=`/`BindsTo=`, `User=`), read as they are;
3. the unit state `gghealthd` turns into lifecycle states (ActiveState,
   Result, NRestarts, inactive timestamp, change notifications), which
   decide between RUNNING, ERRORED and BROKEN;
4. which component a process belongs to, which IPC authorization relies
   on (`sd_pid_get_unit` upstream; a cgroup per unit here);
5. `systemd-notify`, which every startup phase script calls.

Existing supervisors were considered:

| | In Buildroot | What it would still leave to custom code |
| --- | --- | --- |
| busybox init, runit-style `runsv` | yes | almost everything: ordering, oneshot/remain-active units, readiness, start limits, restart counts, process grouping |
| s6 / s6-rc | yes | s6-rc compiles its service set ahead of time, which units created by deployments do not fit; no Result, restart counter or start-limit model |
| OpenRC | yes, as the system init | replaces busybox init; no notification or unit state model |
| dinit | no | the closest fit (dependencies, restart limits, readiness, cgroups), but it would need packaging, a unit translator and its own state mapping |
| supervisor, monit | yes | Python, or polling: too heavy, or the wrong model |

With any of them, items 1, 3, 4 and 5 stay custom: a `systemctl`
translating systemd units, a `gghealthd` backend and the IPC identity
lookup. That is about half of `ggl-svc`. The other half (spawning,
restarts, timeouts, ordering, cgroups) is what an existing supervisor
could take over, and the translation would then have to rebuild the
parts it lacks. So `ggl-svc` implements both halves directly, against
systemd's documented semantics: a 34 KB binary using ~140 kB of RAM, about
1,600 lines of C in the daemon (2,850 lines in the patch, with the
front ends and backends).

The cost is that this is security-relevant code maintained here, not
upstream. It has had two independent reviews (findings and fixes in
`docs/results.md`), and `scripts/board-test.sh` exercises it on every run.
On a board with enough memory for systemd (32 MiB, as the July proof
of this stack showed), upstream's systemd build would need no ggl-svc.
Of the source changes it would keep patches 0001 and 0004 and the
OpenSBI reboot fix, plus systemd's own requirements: its kernel options
(`docs/systemd-evaluation/linux-systemd.fragment`) and a `/run` large
enough for `systemctl daemon-reload`, which refuses below 16 MiB free.

## Device identity and state: `/data`

The image carries no device identity. Everything a device must remember
lives under `/data`, which is all a board has to provide to make it
persistent:

| | |
| --- | --- |
| `/data/greengrass` | credentials, configuration database, deployed components (bind-mounted on `/var/lib/greengrass`) |
| `/data/ggl-svc` | the units deployments linked and enabled (on `/var/lib/ggl-svc`) |

At boot, `/etc/init.d/S95greengrass`:

1. uses `/data` if the board mounted something there (`/etc/fstab`: an SD
   card, USB storage, NAND or flash partition, NFS); otherwise mounts a
   RAM file system there;
2. if `/data/greengrass` holds device credentials, starts Greengrass as
   that device, with its configuration and components;
3. otherwise, if `/etc/greengrass/claim` holds a claim certificate,
   provisions the device with [AWS IoT fleet
   provisioning](https://docs.aws.amazon.com/iot/latest/developerguide/provision-wo-cert.html)
   (Greengrass Lite's `fleet-provisioning`): a key generated on the device,
   a certificate signed by AWS IoT, the Thing `<fleet>-<serial>` registered
   in thing group `<fleet>`, and a policy scoped to that Thing. The serial
   is eth0's MAC address unless `/etc/default/greengrass` sets
   `GGL_SERIAL`. It then starts Greengrass;
4. otherwise, does not start Greengrass.

With persistent storage, a device provisions itself once and keeps its
identity, configuration and deployments. Without it, every boot is a fresh
device: provisioned again (a new certificate, the same Thing), with nothing
deployed. The thing group's deployments are not sent again to a device
that has completed them, and a deployment with a bootstrap step cannot
outlive the reboot it needs. So on a board without storage, deploy what it
must always run from the image (for example a local deployment at boot),
and treat cloud deployments as lasting until the next reboot.

The claim lets anyone who holds it register a device in the fleet, and
each fresh boot leaves the previous certificate registered (unused: its key
is gone). For production, add a pre-provisioning hook that validates the
serial number, and clean up superseded certificates.

## Development setup: NFS root

The boot stack and the XIP kernel are flashed to the 16 MiB NOR flash; the
root filesystem is mounted over NFSv3 from a workstation on the same
network (the kernel does DHCP itself: `ip=dhcp root=/dev/nfs`). Rebuilds
and redeployments need no reflashing.

A product would not depend on an NFS server. This board, with the public
sources, cannot hold Greengrass without one, though (measured; details in
`docs/results.md`):

- Greengrass needs persistent writable storage for `/var/lib/greengrass`
  (credentials, configuration database, deployed components, the state a
  bootstrap reboot resumes from). The board's flash root partition is a
  read-only ROM mapping (`physmap`, `type=rom`): the public kernel has no
  SPI-NOR write driver and no flash file system. No SD card is fitted.
- The root file system compresses to 8.7 MiB; the flash layout reserves
  4 MiB for it.

A product port therefore needs local writable storage (an SD card or eMMC
on the SDMMC host, whose block driver the kernel already has, or a
writable flash partition with an SPI-NOR driver) and a flash layout with
room for the root.

## Usage

Prerequisites: Docker (NFS server), the AWS CLI with credentials, an
ESP32-S31-capable `esptool`, and the usual Buildroot host packages.

```sh
# 1. Build (fetches the pinned sources into ../deps; output in
#    ../out/esp32s31_fcb_greengrass). S31_NFS_SERVER is the workstation's
#    address on the board's network.
S31_NFS_SERVER=192.168.0.126 ESP_ESPTOOL=/path/to/esptool scripts/build.sh

# 2. Set up fleet provisioning in the AWS account (creates what is missing:
#    thing group, provisioning template and role, claim policy and claim
#    certificate). The claim and the device config.yaml go to
#    ../secrets/<fleet> (mode 0700), never into this repository.
scripts/aws-provision.sh esp32s31-greengrass

# 3. Start the NFS server and install the root filesystem, the claim and a
#    development SSH key into its export. The device's state goes to a
#    second directory, mounted on /data (--fresh: keep it in RAM instead).
S31_NFS_CLIENT_NET=192.168.0.0/24 scripts/nfs-server.sh
scripts/nfs-deploy.sh esp32s31-greengrass
#    Redeploying to a running board is safe: it keeps its current tree
#    until it reboots. Stop Greengrass on it first, then reboot it.

# 4. Flash, after checking which chip is on the port.
ESP_ESPTOOL=/path/to/esptool scripts/flash.sh /dev/serial/by-id/<port> <chip-mac>

# 5. At its first boot the board provisions itself as Thing
#    esp32s31-greengrass-<serial> in thing group esp32s31-greengrass.
#    Deploy the demo component from the cloud to that group.
scripts/aws-deploy-hello.sh esp32s31-greengrass

# 6. Check everything end to end: provisioning, core units, local and cloud
#    deployments, removal, failure handling, IPC caller identity, a
#    deployment that reboots the device (bootstrap step) and a cold reset
#    (--fresh after a --fresh deployment).
scripts/board-test.sh <board-ip> esp32s31-greengrass --cloud --reset <port> <chip-mac>
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

The NFS export holds the claim certificate and the device's private key:
keep it restricted to the board's subnet. Opening the board's USB-UART resets it (its CP2102N drives
EN); use SSH for inspection, and `tools/s31-console.py` when a console is
needed.

## Troubleshooting

The component, Greengrass and the network, layer by layer:
`examples/cloud/greengrass-hello/README.rst`. The board itself:

- **SSH times out, the board answers no ARP:** it may sit in the ROM's
  download mode (a tool that opened its serial port can put it there).
  `esptool --port <port> --before no-reset --after no-reset read-mac`
  answering with its MAC confirms it. Pulse EN with RTS while keeping DTR
  released to boot it; `--after hard-reset` can leave it in download
  mode.
- **`reboot` never comes back:** the image lacks the OpenSBI patch in
  `board/esp32s31-fcb/patches/opensbi`.
- **SSH connects but never completes, `/proc` is missing:** the root was
  rewritten underneath the running board by something other than
  `scripts/nfs-deploy.sh`; reset it.

## Results

`docs/results.md`.

## License

Repository infrastructure and documentation: Apache License 2.0
(`LICENSE`). The example under `examples/` (source, recipe and build
files): CC0-1.0, as in esp-linux-examples. The patches to Greengrass Lite
are under its Apache-2.0 license. Each file states its SPDX identifier.
