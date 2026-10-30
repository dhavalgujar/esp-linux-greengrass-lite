# AWS IoT Greengrass Lite on ESP32-S31 Linux

[AWS IoT Greengrass nucleus lite](https://github.com/aws-greengrass/aws-greengrass-lite)
on the ESP32-S31 Function-CoreBoard, connected over Ethernet, built from
public sources only. The complete nucleus runs in 16 MiB of RAM, with
~5.5 MiB to spare: cloud and local deployments, component lifecycle and
health, fleet status, IPC, MQTT to AWS IoT Core and the Token Exchange
Service.

This repository is a Buildroot `BR2_EXTERNAL` tree on
[espressif/esp-buildroot-external](https://github.com/espressif/esp-buildroot-external):
Espressif's toolchain, boot stack, kernel and flash packaging, plus
Greengrass Lite and an example component. Every source is pinned
(`sources.lock`, the defconfig) and hash-checked, and a fresh clone builds
byte-identical images.

## Quick start

Prerequisites: Docker (for the NFS server), the AWS CLI with credentials,
an ESP32-S31-capable `esptool`, the usual Buildroot host packages, and the
AWS account's one-time Greengrass setup: a Token Exchange role and IoT role
alias (`GG_ROLE_ALIAS`, default `ESP32S31GreengrassTokenExchangeAlias`) and
the Greengrass service role associated with the account.

```sh
# 1. Build. S31_NFS_SERVER is the workstation's address on the board's
#    network (the board mounts its root file system from it).
S31_NFS_SERVER=192.168.0.126 ESP_ESPTOOL=/path/to/esptool scripts/build.sh

# 2. Register the board and get its connection kit, the same .zip the AWS
#    IoT console downloads for a nucleus lite core device. Secrets go to
#    ../secrets, never into this repository.
scripts/aws-provision.sh esp32s31-greengrass --device fcb-eth

# 3. Serve the root file system, with the kit in it.
S31_NFS_CLIENT_NET=192.168.0.0/24 scripts/nfs-server.sh
scripts/nfs-deploy.sh --kit ../secrets/esp32s31-greengrass/devices/esp32s31-greengrass-fcb-eth-connectionKit.zip
#    The export now holds the device's private key: keep it restricted to
#    the board's subnet.

# 4. Flash the boot stack and kernel (checks which chip is on the port).
ESP_ESPTOOL=/path/to/esptool scripts/flash.sh /dev/serial/by-id/<port> <chip-mac>

# 5. The board boots as Thing esp32s31-greengrass-fcb-eth in thing group
#    esp32s31-greengrass. Deploy the example component to it.
scripts/aws-deploy-hello.sh esp32s31-greengrass
```

The board appears as a Greengrass core device (`linux`/`riscv32`) in the
AWS IoT Greengrass console. The example reads its configuration over IPC,
round-trips a message through local pub/sub and AWS IoT Core, then
publishes a heartbeat every 30 s on `esp32s31/<thing>/heartbeat`. On the
board (`ssh -i ../secrets/ssh/id_ed25519 root@<board-ip>`):

```sh
/etc/init.d/S95greengrass status       # every unit: state, result, restarts
grep core.iotcored /var/log/messages   # logs, by unit
```

## Device identity and state

Each board gets its own connection kit, in the image or dropped on its
storage; AWS IoT fleet provisioning is the alternative (`aws-provision.sh
<fleet>`, `nfs-deploy.sh --claim`). Everything a device remembers lives in
`/var/lib`: a board makes it persistent by mounting its storage there,
and without storage the device starts fresh at every boot. Here `/var/lib`
is a second directory on the NFS server. Details: `docs/identity.md`.

## What is changed in the public sources, and why

Everything else is built as published. Each change is a patch file here,
applied by Buildroot:

| Change | Where | Why |
| --- | --- | --- |
| Recognize `riscv32` | Greengrass Lite, patch 0001 | Upstream only knows riscv64: platform matching and fleet status fail on RV32. |
| Build without systemd (`GGL_PORTABLE_CORE`) | patch 0002 | systemd does not fit in 16 MiB (measured: no login after 12 minutes). |
| `ggl-svc`, a service manager for the units Greengrass generates | patches 0003, 0006 | Upstream runs components as systemd units, reads their health over D-Bus and identifies IPC callers by their systemd cgroup. Why not an existing supervisor: `docs/architecture.md`. |
| Keep the IoT Jobs ID length on bootstrap resume | patch 0004 | Upstream bug, also on main: a cloud deployment with a bootstrap step never completes. |
| Retry the fleet provisioning certificate request | patch 0005 | Upstream sends it after a fixed 5 s; the TLS connection takes ~11 s on this chip. |
| Reset the whole chip on reboot | OpenSBI patch | The public firmware resets CPU core 0 only: `reboot` hangs the board. |
| `CONFIG_CGROUPS=y` (no controllers) | kernel fragment | `ggl-svc` runs each unit in its own cgroup, as systemd does. |

Patches 0001, 0002, 0004 and 0005 are candidates for upstream Greengrass
Lite.

## Repository layout

```text
├── examples/           the example component (esp-linux-examples layout)
├── scripts/            build, flash, AWS setup, NFS root, deploy the example
├── configs/, board/,   the Buildroot tree: defconfig, kernel fragments,
│   package/            OpenSBI patch, root file system overlay, packages
├── aws/, nfs-server/   templates and the NFS server container the scripts use
├── docs/               identity, architecture, troubleshooting
└── development_tools/  for maintainers: end-to-end board test, ggl-svc
                        conformance and fuzzing, measurements and results
```

## More

- `docs/identity.md`: connection kits, fleet provisioning, what persists,
  and why the root file system is on NFS here.
- `docs/architecture.md`: Greengrass Lite without systemd, and `ggl-svc`.
- `docs/troubleshooting.md` and `examples/cloud/greengrass-hello/README.rst`:
  the board, Greengrass and the network, layer by layer.
- `development_tools/`: how this was tested, and the results.

## License

Repository infrastructure and documentation: Apache License 2.0
(`LICENSE`). The example under `examples/`: CC0-1.0, as in
esp-linux-examples. The patches to Greengrass Lite are under its
Apache-2.0 license. Each file states its SPDX identifier.
