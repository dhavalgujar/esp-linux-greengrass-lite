# Results

Board: ESP32-S31 Function-CoreBoard (chip MAC 30:ed:a0:ed:78:74), 16 MiB
PSRAM, 16 MiB NOR flash, Ethernet (YT8531 PHY) at 100 Mb/s full duplex to
an AP/router with Internet access. AWS region us-east-1, Thing
`esp32s31-fcb-eth`. NFS root served from a workstation on the same subnet.
Measured 2026-10-28/29.

## Shipped configuration: `esp32s31_fcb_greengrass_defconfig`

Espressif's public musl toolchain, boot stack and kernel; busybox init;
Greengrass Lite v2.7.0 with `GGL_PORTABLE_CORE` and `ggl-svcd`.

A clean build from this repository into an empty output directory takes
15 minutes on a 32-core workstation (downloads cached).

### Cold boot (hardware reset, no manual steps)

| Milestone | Time |
| --- | --- |
| Kernel DHCP done, NFS root mounted | 4.7 s |
| SSH reachable | 18–21 s after reset |
| All nine core units active, zero restarts | ~45 s uptime |
| Deployed demo component `hello: PASS` (IPC config, local pub/sub, AWS IoT Core round trip) | ~46 s uptime |

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
