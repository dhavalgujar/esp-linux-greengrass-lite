# Results

Board: ESP32-S31 Function-CoreBoard (chip MAC 30:ed:a0:ed:78:74), 16 MiB
PSRAM, 16 MiB NOR flash, Ethernet (YT8531 PHY) at 100 Mb/s full duplex to
an AP/router with Internet access. AWS region us-east-1. Until 2026-10-29
the board used a manually provisioned Thing, `esp32s31-fcb-eth`; since
2026-10-30 it provisions itself as `esp32s31-greengrass-32eda0ed7875` in
fleet `esp32s31-greengrass`. NFS root served from a workstation on the same
subnet. Measured 2026-10-28..30.

## Shipped configuration: `esp32s31_fcb_greengrass_defconfig`

Espressif's public musl toolchain, boot stack and kernel; busybox init;
Greengrass Lite v2.7.0 with `GGL_PORTABLE_CORE` and `ggl-svcd`.

A fresh clone of this repository builds into an empty work area in 18–19
minutes on a 32-core workstation (downloads cached; 31 minutes when the
workstation was shared and loaded). The build is reproducible
(`BR2_REPRODUCIBLE`): a fresh clone of commit `82a6019` builds a
`rootfs.tar` (`04f604d5…`) and an `s31_full_flash.bin` (`37bbe780…`)
byte-for-byte identical to those of the incremental development build in
another directory (as did `ba296a9`, `dedae3d` and `82e02a0` before). The
end-to-end tests below ran on those images. Incremental builds keep files a
change no longer installs (Buildroot does not remove them from its target
directory): the `/data` mount point had to be removed by hand before the
images matched again. Every download (80 files) is
hash-checked with `BR2_DOWNLOAD_FORCE_CHECK_HASHES`; `esp-linux-bsp` is
fetched by esp-buildroot-external from a branch, so its hash fails the
build if that branch moves.

### End-to-end test (`scripts/board-test.sh --cloud --reset`)

On the final image, after a clean deployment and a software reboot, for
every combination of identity and storage:

| Identity | State (`/var/lib`) | Checks |
| --- | --- | ---: |
| Connection kit in the image (`nfs-deploy.sh --kit`, the default) | persistent (NFS) | 14/14 |
| Connection kit in the image | RAM (`--fresh`) | 12/12 |
| Generic image, kit put on the storage (`--kit-on-storage`) | persistent | 14/14 |
| Fleet provisioning (`--claim`) | persistent | 14/14 |
| Fleet provisioning | RAM | 12/12 |

Without storage the bootstrap checks do not apply (a deployment cannot
outlive the reboot it needs), and the cold reset brings back nothing
deployed: with the kit in the image, the same identity; with fleet
provisioning, a new certificate.

The default, kit in the image with persistent storage:

```
PASS  device has its identity, core units active
PASS  Thing esp32s31-greengrass-fcb-eth registered in group esp32s31-greengrass
PASS  cloud removal of the demo SUCCEEDED
PASS  local deployment of the demo, AWS IoT Core round trip
PASS  IPC caller outside any unit refused
PASS  failing component ends BROKEN, removal cleans up
PASS  install and startup phases (systemd-notify) deploy
PASS  local deployment root removed
PASS  cloud deployment with a bootstrap step: reboot, resume, SUCCEEDED
PASS  cloud deployment of the demo SUCCEEDED
PASS  test component removed from the device and the account
PASS  core device HEALTHY, demo RUNNING (Greengrass API)
PASS  after a cold reset: same device, core units and deployed demo back
PASS  core units active, no restarts (end)
0 check(s) failed
```

Kit in the image, no storage:

```
PASS  device has its identity, core units active
PASS  Thing esp32s31-greengrass-fcb-eth registered in group esp32s31-greengrass
PASS  cloud removal of the demo SUCCEEDED
PASS  local deployment of the demo, AWS IoT Core round trip
PASS  IPC caller outside any unit refused
PASS  failing component ends BROKEN, removal cleans up
PASS  install and startup phases (systemd-notify) deploy
PASS  local deployment root removed
PASS  cloud deployment of the demo SUCCEEDED
PASS  core device HEALTHY, demo RUNNING (Greengrass API)
PASS  after a cold reset: same identity (from the image), nothing deployed
PASS  core units active, no restarts (end)
0 check(s) failed
```

### Device identity: connection kits

The kit is the one the AWS IoT console downloads for a nucleus lite core
device, made here by `scripts/aws-provision.sh esp32s31-greengrass
--device fcb-eth`: Thing `esp32s31-greengrass-fcb-eth` registered with
`aws iot register-thing` through the fleet's provisioning template, so in
thing group `esp32s31-greengrass` and with a policy scoped to that Thing
(client ID `esp32s31-greengrass-fcb-eth*`, its own `$aws/things/...` and
`esp32s31/...` topics). RegisterThing does not evaluate the template's
`Fn::Join`, which fleet provisioning does: the script renders it first
(the first attempt failed on that and left an unattached certificate,
since deleted).

| Case | Result |
| --- | --- |
| Same image deployed again | kit not applied again; identity and deployments kept |
| Kit dropped on the storage over an existing identity | "new connection kit …: starting the device over"; applied, then removed; previous deployments gone; same certificate (twice) |
| Generic image, kit on the storage, clean state | applied at boot, removed; 14/14 |

Once, after such a reset, a cloud deployment failed in cloud resolution:
`ggdeploymentd`'s first data plane request returned 200, the next failed
in curl, and every request after it failed too, 4 minutes later as well,
until `ggdeploymentd` was restarted; the next deployment then succeeded.
Four repetitions (two plain reboots, two resets) did not reproduce it. This
libcurl is built without error strings (curl reports only "Error"), so the
cause is not known; `BR2_PACKAGE_LIBCURL_VERBOSE` would name it.

### Device identity: fleet provisioning

| | Measured |
| --- | --- |
| Fresh boot to provisioned and running | provisioning starts ~23 s after reset, takes 37 s; Greengrass runs as the new device at ~60 s uptime |
| First certificate request | sent before the MQTT connection is up (it takes ~11 s): failed without patch 0005, retried 3 s later with it |
| State in RAM (`--fresh`) after provisioning | 56 KB of the 4 MiB tmpfs |
| Persistent storage, cold reset | same certificate, the cloud-deployed demo back |
| No storage, cold reset | a new certificate on the same Thing, nothing deployed |
| Superseded certificates | one per fresh boot; `scripts/aws-clean-certs.sh` removed them, keeping the device's (certificate ID checked against the device's PEM) |
| AWS resources (`scripts/aws-provision.sh`) | thing group, provisioning template and IAM role, claim policy and certificate created; token-exchange role and alias, service role reused. An unrelated `test_fleet_provisioning` template in the account was left alone |

Two pitfalls found on the way: `fleet-provisioning`'s options take
attached values only (`--template-params=JSON`, not `-p JSON`); and the
clean-up must only run for devices without storage, since a device with
storage keeps its first certificate (removing it cut a persistent device
off once during these tests; it was re-provisioned).

### ggl-svc against systemd, and fuzzed (`tests/ggl-svc`)

Conformance (`tests/ggl-svc/conformance/run.sh`): 23 scenarios of the
units Greengrass generates, run under systemd 255 and under ggl-svcd as
PID 1 of identical Ubuntu 24.04 containers, compared at 32 checkpoints
(ActiveState, Result, NRestarts, leftover processes, environment).

The first run differed at 5 checkpoints, all ggl-svc bugs, fixed by patch
0006:

| Found | systemd | ggl-svc before |
| --- | --- | --- |
| A unit stopped right after it started survived the stop until TimeoutStopSec (90 s): before exec the child still ran ggl-svcd's SIGTERM handler, and before joining its cgroup the stop did not reach it | stopped at once | stopped after 90 s, by SIGKILL |
| A stop that needs SIGKILL | `failed timeout` | `inactive success` |
| `systemd-notify --stopping` from a `Type=exec` unit with `NotifyAccess=all` | `deactivating` | ignored (the second review had restricted notifications to `Type=notify`; that was wrong) |
| A run phase failing 3 times (start limit) | `failed exit-code 3` | `failed start-limit-hit 3` (no effect on Greengrass, which decides BROKEN from NRestarts) |
| `USER`/`LOGNAME`/`HOME`/`SHELL` for `User=nobody`, a normal user, no `User=` | per systemd's rules | `HOME=/nonexistent`, no `SHELL`, all four without `User=` |

After the fixes, all 32 checkpoints match, also when ggl-svc is built from
the pinned release with the patch series.

Fuzzing (`tests/ggl-svc/fuzz/run.sh 900`), libFuzzer with
AddressSanitizer and UndefinedBehaviorSanitizer, 15 minutes per target:

| Target | Inputs | Rate | Findings |
| --- | ---: | ---: | ---: |
| Unit file parser | 60.8 million | 67,500/s | 0 |
| Control protocol (root and unprivileged requests against linked units) | 2.24 million | 2,500/s | 0 |

Writing the harness found one hardening issue: linking a FIFO as a unit
file would have blocked ggl-svcd (root only); it is now opened without
blocking and rejected.

The board test on the image with patch 0006, deployed over a provisioned
device (its identity kept): 14/14.

### Independent review of ggl-svc

An independent review of the fork's diff and the scripts found, among
others, four high-severity problems, all fixed and covered by the checks
above:

- `systemctl start --no-block <unit>` (ggdeploymentd's form) treated
  `--no-block` as a unit, so every deployment with an install phase
  failed;
- startup phases could never reach RUNNING: their scripts end with
  `systemd-notify`, which did not exist, and notify units ignored
  `RemainAfterExit`;
- the unit state directory was inside `/var/lib/greengrass`, writable by
  `ggcore`, which could have planted a unit running as root; it is now
  root-only `/var/lib/ggl-svc`;
- a local user could stall ggl-svcd by sending a request one byte at a
  time; requests are now read without blocking.

Also fixed: unit sessions stand in for cgroups (leftover processes are
killed, `whois` matches by session), start/stop timeouts, start limits
over their interval, blocking `systemctl start/stop`, a restart that could
override a later stop, dependents of a failed core daemon waiting forever,
links left by units that failed to load or were removed, and log draining
that could starve the main loop.

A second independent review, of the result, found:

- **IPC identity could be taken over through PID reuse** (high). A unit
  that remains active after its main process exits (a oneshot with
  `RemainAfterExit`, a startup phase's background process) was matched
  by session ID. Once that session emptied, any local process could fork
  until it got the same PID, call `setsid()` and be identified as the
  component. No session- or ancestry-based check closes this without
  cgroups. Units now run in their own cgroup (`CONFIG_CGROUPS`, no
  controllers), which processes cannot leave, as under systemd.
- **A local user could fill the control socket's 8 connection slots**,
  and clients had no timeouts, so `whois` from ggipcd could hang. Now
  there are 16 slots, at most 4 per non-root user, and 10 s client
  timeouts.
- **Notifications were applied to every unit type**, letting a `Type=exec`
  component be marked STOPPING. Now only `Type=notify` units accept them,
  per `NotifyAccess`, as under systemd.
- **Linked unit files stayed in a directory `ggcore` can write** and were
  re-read as root at every boot. The same holds upstream on systemd. Units
  now run from a root-only copy taken by `systemctl link`.
- Leftover processes only ever got SIGTERM (now SIGKILL after
  `TimeoutStopSec`); `BindsTo=` was treated as `Wants=` (now the bound unit
  stops and restarts with its dependency); 48 units at most (now 128);
  `nfs-deploy.sh --clean` also discarded the SSH host keys (now kept).

Only one ESP32-S31 Function-CoreBoard was available, so the cloud checks
cover one core device.

### Reboots and bootstrap deployments

A cloud deployment of a component with a `bootstrap` step makes nucleus
lite reboot the device (`systemctl reboot`) and finish the deployment
after the boot. Two defects in the public sources stopped this:

| Defect | Evidence | Fix |
| --- | --- | --- |
| `reboot` never came back | console: `reboot: Restarting system`, then nothing for 5 min; recovered only by EN | OpenSBI serviced SBI SRST by resetting HP core 0 alone (`LP_AONCLKRST_HPCORE0_RESET_CTRL_REG`). Now uses the ROM's system reset (`LP_SYSTEM_REG_SYS_CTRL_REG.SYS_SW_RST`). |
| The resumed deployment never completed in the cloud | device: `reporting job as SUCCEEDED`, then `Received rejected response ... "code":"InvalidRequest"` with the log line cut at the job ID; job IN_PROGRESS | `retrieve_in_progress_deployment()` never set the jobs ID's length, so the ID was padded with NULs to 64 bytes. Patch 0004, one line; also present on upstream main. |

With both fixes, the stuck job from before the fix completed on the next
boot of the fixed image: bootstrap step, `rst:0x3 (SW_SYS_RESET)`,
deployment resumed, job SUCCEEDED 103 s after the device picked it up.
`board-test.sh --cloud` covers this path. Plain `reboot`: SSH back in
47–57 s.

### Cold boot (hardware reset, no manual steps)

| Milestone | Time |
| --- | --- |
| Kernel DHCP done, NFS root mounted | 4.7 s |
| Clock set (one attempt asks pool.ntp.org and time.google.com) | before Greengrass |
| ggl-svcd starts the core units | 13 s uptime |
| SSH reachable | 20 s after reset |
| All nine core units active, zero restarts | ~45 s uptime |
| Deployed demo component `hello: PASS` (IPC config, local pub/sub, AWS IoT Core round trip) | 48 s uptime |

Identical over consecutive cold boots. Once, right after back-to-back EN
resets, `tes-serverd` timed out writing its version to ggconfigd over the
core bus (`Read timed out`), exited and was restarted by its unit; it
then ran normally (NRestarts 1). The next two cold boots had zero
restarts. An earlier version of the clock
step queried one server per attempt; when the pool returned an
unresponsive server, each attempt cost 10 s and one boot took 106 s to
reach SSH. The step now asks several servers at once and gives up after
three attempts, leaving the ntpd daemon to finish (iotcored reconnects
once the clock is right).

### Memory, steady state

All nine core units plus the deployed demo component, 3 minutes after a
cold boot:

| | kB |
| --- | ---: |
| MemTotal | 14720 |
| MemAvailable | 5640 |
| AnonPages | 3708 |
| Cached | 6460 |

`CONFIG_CGROUPS` costs 8 kB of MemTotal (37 KB of XIP kernel in flash);
before it, MemTotal was 14728 kB and MemAvailable 5680 kB. During a
deployment MemAvailable dips to ~4.7 MiB. Afterwards `ggdeploymentd` keeps
~450 kB more heap (1156 kB vs 708 kB anonymous after two cloud
deployments), so MemAvailable stays ~4.7 MiB until the next boot.

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
| `recipe-runner` started outside any unit claiming the demo component | refused by ggipc-auth (`ggl-svcd` whois, by cgroup) |
| Every unit in its own cgroup (`/sys/fs/cgroup/ggl-svc/<unit>`) | pass |
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

A deployment replaced while the device is still processing it is
completed by nucleus lite anyway, and its report is rejected (the job
is CANCELED). The device then does not start the replacing deployment's
job, which stays QUEUED until the next job notification. Observed once,
when deployments from an interrupted test run were superseded: the
replacing job waited 18 minutes, until the next deployment to the group
canceled it. A later deployment is picked up normally.

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

Re-run from the committed configuration (`docs/systemd-evaluation`, built
with `S31_DEFCONFIG`, flashed with `scripts/flash.sh`, 2026-10-29): no SSH
within 7 minutes; the sampler on the NFS root recorded

| Uptime | MemAvailable | AnonPages | `workingset_refault_file` |
| --- | ---: | ---: | ---: |
| 195 s | 3004 kB | 4988 kB | 25,784 |
| 354 s | 2160 kB | 5676 kB | 55,075 |

with PID 1 in uninterruptible sleep, and its own 10 s sampling interval
stretched to 160 s.

## Public baseline (unmodified `espressif_esp32s31_function_core_board_nor_defconfig`)

- Boots to a shell from NOR; `eth0` links at 100 Mb/s, DHCP and Internet
  reachability work.
- MemTotal 14732 kB, MemAvailable 11760 kB at an idle shell.
- The `esp32s31_minimal` kernel has no NFS client, and the image has no
  time synchronisation (the clock starts at 1970, which breaks TLS
  certificate validation). This repository adds both.

## Why there is no flash-only configuration

Measured on the board and the final image:

| | |
| --- | --- |
| Flash root partition (`mtd0`, `physmap` at `0x40b00000`) | 4 MiB, `type=rom`, `flags=0x0`: read-only |
| Flash write path in the public kernel | none (`MTD_ROM`, `MTD_PHYSMAP`; no SPI-NOR, JFFS2 or UBIFS) |
| SD card / eMMC | SDMMC host probes, no card fitted |
| Root file system | 15.4 MiB, 8.7 MiB gzip -9 |

The largest items are `libcrypto` (3.8 MB), `libstdc++` (1.7 MB), the
`sqlite3` shell (1.2 MB) and the external toolchain's loaders for two other
ABIs (`ld-musl-riscv32-sf`, `ld-musl-riscv64`, 1.5 MB). Trimming would not
make 4 MiB, and without writable storage nucleus lite would lose its
configuration and every deployment at each boot, so a flash-only image
was not built.

## Findings worth keeping

- **`reboot` on the public ESP32-S31 OpenSBI hangs the chip**: it resets
  CPU core 0 only. See "Reboots and bootstrap deployments".
- **Nucleus lite recipes for the cloud need `runtime: "*"`** (or
  `aws_nucleus_lite`) in the manifest platform: the cloud resolves
  components for `{os=linux, runtime=aws_nucleus_lite,
  architecture=riscv32}`, and a manifest without `runtime` fails with
  "doesn't claim platform ... compatibility".

- **`swiotlb=128` must stay on the command line.** The public device tree
  passes it; a forced `CONFIG_CMDLINE` that drops it lets the kernel
  reserve an ~8 MiB bounce buffer, leaving Linux 6.7 MiB instead of
  14.7 MiB.
- **Never rewrite the NFS root in place under a running board.** Deleting
  and re-extracting the tree left the running board's `/proc`, `/sys` and
  `/dev` mounts on deleted directories: twice its userspace wedged (SSH
  connects but never completes its banner), and only EN brought it back.
  `nfs-deploy.sh` now assembles the new root next to the current one and
  swaps the directories by renaming them. NFS file handles follow inodes
  (`no_subtree_check`), so the board keeps running from the old tree
  until it reboots.
- **An SSH session to a board that resets hangs indefinitely** without
  keepalives (still open 225 s after an EN reset, when it was killed).
  With `ServerAliveInterval=10`, `ServerAliveCountMax=3`, as
  `board-test.sh` uses, it failed 9 s after the reset.
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
