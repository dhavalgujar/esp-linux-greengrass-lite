# AWS IoT Greengrass Lite on ESP32-S31 Linux

[AWS IoT Greengrass nucleus lite](https://github.com/aws-greengrass/aws-greengrass-lite)
on the ESP32-S31 Function-CoreBoard with 32 MiB of PSRAM, connected over
Ethernet, built from public sources only. Greengrass Lite runs as upstream
runs it: under systemd, with its own service units, and two small fixes.
Cloud and local deployments, component lifecycle and health, fleet
status, IPC, MQTT to AWS IoT Core and the Token Exchange Service all work.

This repository is a Buildroot `BR2_EXTERNAL` tree on
[espressif/esp-buildroot-external](https://github.com/espressif/esp-buildroot-external):
Espressif's boot stack, kernel and flash packaging, plus Greengrass Lite and
an example component. Every source is pinned (`sources.lock`, the
defconfig) and hash-checked.

For the 16 MiB board, where systemd does not fit, there is an experimental
configuration with a purpose-built service manager in place of systemd:
`docs/16mib.md`.

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
board (`ssh -i ../secrets/ssh/id_ed25519 root@<board-ip>`; it takes about
two minutes to boot over NFS):

```sh
systemctl list-units 'ggl.*'           # the Greengrass units
journalctl -u ggl.core.iotcored        # logs, by unit
```

## Device identity and state

Each board gets its own connection kit, in the image or dropped on its
storage, and `esp32s31-ggl-identity.service` applies it before Greengrass
starts. Everything a device remembers lives in `/var/lib`: a board makes it
persistent by mounting its storage there, and without storage the device
starts fresh at every boot. Here `/var/lib` is a second directory on the
NFS server. Details: `docs/identity.md`.

## What is changed in the public sources, and why

Everything else is built as published. Each change is a file here, applied
by Buildroot:

| Change | Where | Why |
| --- | --- | --- |
| Recognize `riscv32` | Greengrass Lite, patch 0001 | Upstream only knows riscv64: the nucleus does not build for RV32, and platform matching and fleet status would fail. |
| Keep the IoT Jobs ID length on bootstrap resume | Greengrass Lite, patch 0002 | Upstream bug, also on main: a cloud deployment with a bootstrap step never completes. |
| Reset the whole chip on reboot | OpenSBI patch | The public firmware resets CPU core 0 only: `reboot` hangs the board. |
| Describe 32 MiB of PSRAM | kernel device tree patch | The public device tree describes 16 MiB; U-Boot's SPL already detects and maps all of it. |
| One CPU core | kernel fragment | The public kernel now runs Linux on both cores; measured, that costs memory and flash and gains nothing here (`development_tools/results.md`). |
| What systemd needs | kernel fragment | Namespaces, cgroups and tmpfs extended attributes, which the minimal kernel configuration leaves out. |
| glibc | Buildroot toolchain | Buildroot builds systemd only with glibc; Espressif's public toolchain is musl. |

Both Greengrass Lite patches are candidates for upstream.

## Known issues

- **Deployments fail intermittently.** The board does not keep up with
  systemd and Greengrass under deployment load: Greengrass's own 10 s
  core-bus and 25 s D-Bus timeouts fire, and the deployment is reported
  FAILED. In the full end-to-end test, 5 of 14 checks passed
  (`development_tools/results.md`); revising a failed deployment retries
  it. With a fresh build, a cloud deployment left the board answering SSH
  only after 30 to 90 s for the 20 minutes it was watched, and FAILED.
  MemAvailable is about 13 MiB after boot, but a deployment uses most
  of it, and code is read again over the network throughout: keep
  components small (`development_tools/memory-margin.sh` measures what is
  left). The systemd-free configuration on the 16 MiB branch passed the
  same test on this board.
- **Fleet provisioning** fails on this chip: upstream sends the
  certificate request a fixed 5 s after starting, and the TLS connection
  takes longer. Use connection kits; the 16 MiB configuration carries a
  fix (`docs/16mib.md`).
- **A slow name server** (an answer after more than 5 s) fails the HTTP
  request, and the deployment that needed it; upstream does not retry.
  Revising the deployment retries it; the 16 MiB configuration carries a
  fix.

## Repository layout

```text
├── examples/           the example component (esp-linux-examples layout)
├── scripts/            build, flash, AWS setup, NFS root, deploy the example
├── configs/, board/,   the Buildroot tree: defconfig, kernel fragments and
│   package/            patches, root file system overlay, packages
├── aws/, nfs-server/   the template and the NFS server container the
│                       scripts use
├── docs/               identity, architecture, troubleshooting
└── development_tools/  for maintainers: end-to-end board test, memory
                        test, measurements and results
```

## More

- `docs/identity.md`: connection kits, what persists, and why the root
  file system is on NFS here.
- `docs/architecture.md`: how Greengrass Lite runs on the board.
- `docs/16mib.md`: the experimental configuration for the 16 MiB board.
- `docs/troubleshooting.md` and `examples/cloud/greengrass-hello/README.rst`:
  the board, Greengrass and the network, layer by layer.
- `development_tools/`: how this was tested, and the results.

## License

Repository infrastructure and documentation: Apache License 2.0
(`LICENSE`). The example under `examples/`: CC0-1.0, as in
esp-linux-examples. The patches to Greengrass Lite are under its
Apache-2.0 license, the kernel device tree patch under the kernel's
GPL-2.0. Each file states its SPDX identifier.
