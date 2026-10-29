# Results

Board: ESP32-S31 Function-CoreBoard (chip MAC 30:ed:a0:ed:78:74), 16 MiB
PSRAM, 16 MiB NOR flash, Ethernet (YT8531 PHY) at 100 Mb/s full duplex to
an AP/router with Internet access. AWS region us-east-1, Thing
`esp32s31-fcb-eth`. NFS root served from a workstation on the same subnet.
Measured 2026-10-28/29.

## Shipped configuration: `esp32s31_fcb_greengrass_defconfig`

Espressif's public musl toolchain, boot stack and kernel; busybox init;
Greengrass Lite v2.7.0 with `GGL_PORTABLE_CORE` and `ggl-svcd`.

A fresh clone of this repository builds into an empty work area in 18
minutes on a 32-core workstation (downloads cached). The build is
reproducible (`BR2_REPRODUCIBLE`): the fresh clone's `rootfs.tar` and
`s31_full_flash.bin` are byte-for-byte identical to those of an
independent build in another directory. Every download (80 files) is
hash-checked with `BR2_DOWNLOAD_FORCE_CHECK_HASHES`; `esp-linux-bsp` is
fetched by esp-buildroot-external from a branch, so its hash fails the
build if that branch moves.

### End-to-end test (`scripts/board-test.sh --cloud --reset`)

On the reproducible image, flashed with `scripts/flash.sh`: 10/10 checks
pass in about 6 minutes.

```
PASS  core units active, no restarts
PASS  cloud removal of the demo SUCCEEDED
PASS  local deployment of the demo, AWS IoT Core round trip
PASS  IPC caller outside any unit refused
PASS  failing component ends BROKEN, removal cleans up
PASS  local deployment root removed
PASS  cloud deployment of the demo SUCCEEDED
PASS  core device HEALTHY, demo RUNNING (Greengrass API)
PASS  after a cold reset: core units and deployed demo back
PASS  core units active, no restarts (end)
0 check(s) failed
```

Only one ESP32-S31 Function-CoreBoard was available, so the cloud checks
cover one core device.

### Cold boot (hardware reset, no manual steps)

| Milestone | Time |
| --- | --- |
| Kernel DHCP done, NFS root mounted | 4.7 s |
| Clock set (one attempt asks pool.ntp.org and time.google.com) | before Greengrass |
| ggl-svcd starts the core units | 13 s uptime |
| SSH reachable | 20 s after reset |
| All nine core units active, zero restarts | ~45 s uptime |
| Deployed demo component `hello: PASS` (IPC config, local pub/sub, AWS IoT Core round trip) | 48 s uptime |

Identical over consecutive cold boots. An earlier version of the clock
step queried one server per attempt; when the pool returned an
unresponsive server, each attempt cost 10 s and one boot took 106 s to
reach SSH. The step now asks several servers at once and gives up after
three attempts, leaving the ntpd daemon to finish (iotcored reconnects
once the clock is right).

### Memory, steady state

All nine core units plus the deployed demo component:

| | kB |
| --- | ---: |
| MemTotal | 14728 |
| MemAvailable | 5680 |
| AnonPages | 3684 |
| Cached | 6456 |

During a deployment MemAvailable dips to ~4.7 MiB.

### Functional checks

| Check | Result |
| --- | --- |
| iotcored connects to AWS IoT Core (mutual TLS) | pass |
| gg-fleet-statusd publishes fleet status | pass |
| Local deployment (`ggl-cli deploy`) of `com.espressif.esp32s31.Hello` | SUCCEEDED; unit generated, linked, enabled and started through `systemctl` → `ggl-svcd`; RUNNING reported by `gghealthd` |
| Component runs as `gg_component` with TES credentials and SVCUID | pass |
| Deployed component restarts after a cold reset | pass |
| Removal deployment (`ggl-cli deploy -d`) | SUCCEEDED; unit stopped, disabled, unit file removed |
| Component that always fails | restarted 3 times, then `failed (start-limit-hit)`, reported BROKEN |
| `recipe-runner` started outside any unit claiming the demo component | refused by ggipc-auth (`ggl-svcd` whois) |
| Forged SVCUID | refused by ggipcd |
| Core daemons run as `ggcore`; `ggdeploymentd`, `gghealthd` as root | pass |
| Unit output in `/var/log/messages`, tagged by unit, rotated by syslogd | pass |

A failing component can briefly look RUNNING between restarts, and a
deployment that samples it then reports SUCCEEDED; systemd hosts behave
the same (`Type=exec` units are active as soon as they start).

### Cloud (AWS IoT Greengrass API)

| Check | Result |
| --- | --- |
| Core device registered from fleet status | `esp32s31-fcb-eth`: HEALTHY, `linux`/`riscv32`, nucleus 2.7.0 |
| Cloud deployment of `com.espressif.esp32s31.Hello` to thing group `esp32s31-fcb-eth-group` (`scripts/aws-deploy-hello.sh`) | IoT job created ~10 s after the deployment; received on `$aws/things/<thing>/jobs/notify-next-namespace-aws-gg-deployment` 1 s after queueing; job SUCCEEDED 23 s after creation |
| Installed components (cloud view) | `com.espressif.esp32s31.Hello` 1.0.0 RUNNING, root component |
| Core device status after the deployment | HEALTHY, refreshed by the device at completion |
| Cloud configuration update (merge `message`, `heartbeatSeconds: 20`) | SUCCEEDED in 68 s; component restarted with the new message and a 20 s heartbeat |
| Cloud removal (thing-group deployment without the component) | SUCCEEDED; unit stopped, link and unit file removed, cloud lists 0 installed components |
| Restore with `scripts/aws-deploy-hello.sh` | SUCCEEDED in 27 s; RUNNING, `hello: PASS` |

A component deployed both from the cloud and locally (`ggl-cli`) stays
installed until it is removed from both: nucleus lite keeps it while any
deployment group, including the local one, lists it as a root.

Deployments must target a thing group. For a deployment that targets a
single core device, Greengrass does not create an IoT job: it writes the
deployment into the device's named shadow `AWSManagedGreengrassV2Deployment`
(observed: desired `fleetConfig`/`desiredStatus`, never reported).
Greengrass nucleus lite v2.7.0 has no support for that shadow (no
reference in its sources), so such deployments stay IN_PROGRESS forever;
thing-group deployments are delivered through IoT Jobs, which it
implements.

## Rejected configuration: glibc + systemd

The same Greengrass Lite with its normal systemd service model, glibc
toolchain built by Buildroot, NFS root. It builds and boots, but **does not
fit in 16 MiB**: program text is evicted and re-read over NFS
(`workingset_refault_file` 18,000–25,000 pages by 160–200 s), MemAvailable
falls to 2.2–2.6 MiB with 5 MiB of anonymous memory, every unit start
takes seconds to minutes (the `ggl.*` socket units ~5 min 20 s), and SSH
was still not reachable after 12 minutes. The refaults start during
systemd's own early boot (tmpfiles, udev), before Greengrass. Compressed
RAM swap (zram, `vm.swappiness=100`) and removing ifupdown's
`network.service` did not change the outcome. The July 2026 proof of this
stack ran on a 32 MiB board.

## Public baseline (unmodified `espressif_esp32s31_function_core_board_nor_defconfig`)

- Boots to a shell from NOR; `eth0` links at 100 Mb/s, DHCP and Internet
  reachability work.
- MemTotal 14732 kB, MemAvailable 11760 kB at an idle shell.
- The `esp32s31_minimal` kernel has no NFS client, and the image has no
  time synchronisation (the clock starts at 1970, which breaks TLS
  certificate validation). This repository adds both.

## Findings worth keeping

- **`swiotlb=128` must stay on the command line.** The public device tree
  passes it; a forced `CONFIG_CMDLINE` that drops it lets the kernel
  reserve an ~8 MiB bounce buffer, leaving Linux 6.7 MiB instead of
  14.7 MiB.
- **Never run a userspace DHCP client on `eth0` with an NFS root.** The
  kernel configured it (`ip=dhcp`); a deconfigure would pull the root
  filesystem away. DNS comes from `/proc/net/pnp`.
- **Export the NFS root `async`.** With `sync`, each SQLite commit by
  ggconfigd waits for the server's disk; on a busy workstation ggconfigd
  took over a minute to listen.
- **Buildroot's `BUILD_SHARED_LIBS=ON` breaks Greengrass Lite**: the
  vendored gg-sdk becomes a shared library built with `-fvisibility=hidden`
  and exports nothing. The package forces static linking, as upstream does.
- **Recipe lifecycle keys are case sensitive** in nucleus lite
  (`run:`/`Script:`); `recipe-runner` accepts `Run:` but the unit generator
  then finds no lifecycle step.
- **Components can start before iotcored is connected**; IoT Core
  subscriptions then fail with `MQTTStatusNotConnected`. Components must
  retry.
- Buildroot's glibc package downloads its complete git history unless
  `BR2_PRIMARY_SITE` (Buildroot's source mirror) is tried first; same for a
  `CUSTOM_GIT` kernel (8 GiB). The defconfig pins tarballs instead.
- The Function-CoreBoard's CP2102N resets the board whenever its port is
  opened, regardless of DTR/RTS; use SSH for repeated inspection.
