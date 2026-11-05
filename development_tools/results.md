# Results

Board: ESP32-S31 Function-CoreBoard with 32 MiB of PSRAM (chip MAC
30:ed:a0:ed:6d:c8), 16 MiB NOR flash, Ethernet (YT8531 PHY) at 100 Mb/s
full duplex to an AP/router with Internet access. AWS region us-east-1,
Thing `esp32s31-greengrass-fcb-eth` in thing group `esp32s31-greengrass`.
NFS root served from a workstation on the same subnet. Measured
2026-11-04..06; earlier results on a 16 MiB board are on the
`esp32s31-greengrass-lite-16mib` branch.

## Shipped configuration: `esp32s31_fcb_greengrass_defconfig`

Espressif's public boot stack and kernel (single core), a glibc toolchain
built by Buildroot, systemd, Greengrass Lite v2.7.0 with its upstream units
and patches 0001 (riscv32) and 0002 (bootstrap Jobs ID).

### End-to-end test (`development_tools/board-test.sh --cloud --reset`)

| State (`/var/lib`) | Checks passed |
| --- | ---: |
| persistent (NFS) | 5/14 |
| RAM (`--fresh`) | 5/12 |

Passed: the device's identity and core units, the Thing in its group,
cloud removal of the demo, removal of the local deployment root, the test
component removed from the device and the account, and (in RAM) IPC
refusing a caller outside any unit. Failed: every other deployment (the
local demo with its AWS IoT Core round trip, the failing component ending
BROKEN, install and startup phases, the bootstrap deployment, the cloud
demo deployment), the Greengrass API's health report, and the demo after
a cold reset.

The deployments fail on Greengrass's own timeouts, because the board does
not keep up:

- the core bus's 10 s: `ggdeploymentd` writes component information to
  `ggconfigd`, which answers too late ("Read timed out", then "Failed to
  write component info … to config"); also `gg-fleet-statusd` and
  `tes-serverd`;
- D-Bus's 25 s: `gghealthd` asks systemd for a component's unit while
  systemd reloads its units (`DBus.Error.Timeout`);
- `systemctl daemon-reload` and `enable` during a deployment took up to
  1 min 47 s, systemd (PID 1) busy throughout;
- the board then answered SSH too slowly for the IPC check.

With Greengrass's state in RAM instead of on NFS, the core-bus timeouts
fell from 11 to 3 in the run, and the failures remained: NFS makes it
worse, it is not the cause. Program code is still read over NFS in both
runs; a root file system on an SD card would make re-reading it cheaper
(not measurable here: the board has no card slot).

An earlier run of the same configuration (before the board test's
log reading was made cheaper, 2026-11-04) passed 11 of 13 checks: the
outcome varies with load. On the same board and network, the systemd-free
configuration of the 16 MiB branch passed 14/14 with 32 MiB.

### Boot

| | |
| --- | --- |
| Kernel has its NFS root | ~5 s |
| SSH | 125–150 s |
| `systemctl is-system-running` = running | ~6 min |
| Greengrass connected to AWS IoT Core | TLS after ~10 s more |

On a fresh boot, `ggdeploymentd` and `tes-serverd` each exited once on a
core-bus timeout while all daemons started at once (systemd restarted
them). The identity service's `systemctl daemon-reload` took 32 s; it now
reloads only when deployed components have linked units.

### Memory

| | kB |
| --- | ---: |
| MemTotal | 31048 |
| MemAvailable, 5 min after boot | 13060–13924 |
| AnonPages | 8260–8536 |

`development_tools/memory-margin.sh`, from a fresh boot, nothing taken:
deploying and removing a small local component took 1333 s and 660 s,
re-reading 190,393 file pages; MemAvailable fell from 13.8 MiB to
3.9 MiB during it. Anonymous memory grows by about 5 MiB while a
deployment runs (systemd reloading its units, with D-Bus and journald),
and the code that must stay resident (glibc, systemd's 3 MB shared
library, D-Bus, Greengrass) no longer fits in what is left. The systemd-free
configuration, on the same board: 37 s and 21 s, nothing re-read, 12 MiB
of real margin.

### The July 2026 proof

The same stack (systemd 256.7, glibc, NFS root, Greengrass Lite 2.6.0)
was first run on a 32 MiB board on 2026-07-20: systemd running with no
failed units, the core device HEALTHY in AWS, one cloud group deployment
SUCCEEDED, its component back after a cold boot, 13364 KiB available
after startup, about 2.5 minutes to SSH. Software reboot then stalled
(fixed since by the OpenSBI patch). Deployment times and memory margin
were not measured.

## Dependencies: Espressif's November 2026 branches

Kernel `1962979` (from `b3bd414`), U-Boot `e5dff8d` (from `333c7a3`),
esp-buildroot-external `d75370b` (from `a652ea9`); OpenSBI and
esp-linux-bsp unchanged. The kernel's integration branch runs Linux on
both cores (SMP), and adds SD card root file systems, a common clock tree
and XIP kernel fixes.

SMP, measured with the systemd-free image:

| | MemTotal | Result |
| --- | ---: | --- |
| 16 MiB, one core (old and new kernel) | 14720 / 14712 kB | board test 14/14; real margin 1 MiB |
| 16 MiB, SMP | 14384 kB | board test 13/14 (a `ggconfigd` timeout); with nothing taken, a deployment took 115 s, re-read 16,294 pages, the removal FAILED |
| 32 MiB, SMP | 30740 kB | 11 checks run, all passed (stopped there) |

SMP costs 336 kB of MemTotal, about 1 MB of MemAvailable and 0.4 MB of
kernel in flash (3.96 MB vs 3.56 MB). It was dropped for both sizes
(`board/esp32s31-fcb/linux-uniprocessor.fragment`); the device tree still
describes both cores, which a single-core kernel ignores.

## 32 MiB of PSRAM

U-Boot's SPL reads the PSRAM's density register (4 to 64 MiB) and maps all
of it (`board/espressif/esp32s31/spl_psram.c`); Linux takes its memory
from the device tree. With 32 MiB in the device tree, Linux reports
`Memory: 30800K/32768K available`. A 12 MiB tmpfs file of random data
read back three times with the checksum it was written with. The
systemd-free image on 32 MiB: board test 14/14.

## Flashing over USB-DBG

The Function-CoreBoard's USB-DBG port is the chip's USB Serial/JTAG
(`/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_<MAC>-if00`).
Writing the full image (9 MB) took 35–37 s (about 2 Mbit/s) against about
60 s through the CP2102N UART at 921600 baud. Reading flash over USB-DBG
stalled reproducibly between 0x500000 and 0x900000 ("Packet content
transfer stopped"); the UART read that range (0.6 Mbit/s).

## Known issues, with evidence

- **Fleet provisioning** (measured on the 16 MiB branch): upstream sends
  the certificate request a fixed 5 s after starting, before its TLS
  connection (~11 s) is up, and fails; the branch carries a retry.
- **A slow name server**: querying the router once a minute (past the
  endpoints' 60 s DNS TTL) for 3 hours, one answer took 5039 ms, longer
  than the resolver waits. Reproduced by making lookups time out for 15 s
  as a cloud deployment arrived: `Curl request failed due to error: Could
  not resolve hostname`, deployment FAILED. Upstream retries timeouts and
  failed connections, not this; the 16 MiB branch carries a retry, with
  which the same test SUCCEEDED.
- **Core-bus and D-Bus timeouts** under load: see the end-to-end test.

## Public baseline (unmodified `espressif_esp32s31_function_core_board_nor_defconfig`)

- Boots to a shell from NOR; `eth0` links at 100 Mb/s, DHCP and Internet
  reachability work.
- The `esp32s31_minimal` kernel has no NFS client, and the image has no
  time synchronisation (the clock starts at 1970, which breaks TLS
  certificate validation). This repository adds both.

## Findings worth keeping

- **`reboot` on the public ESP32-S31 OpenSBI hangs the chip**: it resets
  CPU core 0 only.
- **`systemctl daemon-reload` needs 16 MiB free under `/run`**; Buildroot
  sizes `/run` at 20 % of RAM.
- **systemd loads unit files before a separately mounted `/var/lib`**:
  the units Greengrass links from `/var/lib/greengrass` are "not found"
  after a reboot until systemd reloads (the identity service does).
- **Nucleus lite recipes for the cloud need `runtime: "*"`** (or
  `aws_nucleus_lite`) in the manifest platform: the cloud resolves
  components for `{os=linux, runtime=aws_nucleus_lite,
  architecture=riscv32}`.
- **Deployments must target a thing group.** For a single core device,
  Greengrass writes the deployment into a named shadow
  (`AWSManagedGreengrassV2Deployment`) that nucleus lite v2.7.0 does not
  read: it stays IN_PROGRESS forever.
- **A deployment replaced while the device processes it** is completed
  anyway, and its report rejected (the job is CANCELED); the replacing job
  can wait until the next job notification.
- **`swiotlb=128` must stay on the command line.** Without it the kernel
  reserves an ~8 MiB bounce buffer.
- **Never rewrite the NFS root in place under a running board**:
  `nfs-deploy.sh` assembles the new root next to the current one and swaps
  the directories.
- **Never run a userspace DHCP client on `eth0` with an NFS root**: the
  kernel configured it (`ip=dhcp`).
- **Export the NFS root `async`.** With `sync`, each SQLite commit by
  ggconfigd waits for the server's disk.
- **Buildroot's `BUILD_SHARED_LIBS=ON` breaks Greengrass Lite**: the
  vendored gg-sdk would export nothing; the package links it statically.
- **Recipe lifecycle keys are case sensitive** in nucleus lite
  (`run:`/`Script:`).
- **Components can start before iotcored is connected**; IoT Core
  subscriptions then fail with `MQTTStatusNotConnected`. Components must
  retry.
- Buildroot's glibc package downloads its complete git history unless
  `BR2_PRIMARY_SITE` (Buildroot's source mirror) is tried first.
- The Function-CoreBoard's CP2102N resets the board whenever its port is
  opened, regardless of DTR/RTS; use SSH for repeated inspection.
- **The workstation must stay on the board's network**: when its Wi-Fi
  adapter moved to another network, the board stopped at "VFS: Unable to
  mount root fs via NFS".
