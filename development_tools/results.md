# Results

Board: ESP32-S31 Function-CoreBoard (chip MAC 30:ed:a0:ed:78:74), 16 MiB
PSRAM, 16 MiB NOR flash, Ethernet (YT8531 PHY) at 100 Mb/s full duplex to
an AP/router with Internet access. AWS region us-east-1. Until 2026-10-29
the board used a manually provisioned Thing, `esp32s31-fcb-eth`; since
2026-10-30 it provisions itself as `esp32s31-greengrass-32eda0ed7875` in
fleet `esp32s31-greengrass`. NFS root served from a workstation on the same
subnet. Measured 2026-10-28..11-02.

## Shipped configuration: `esp32s31_fcb_greengrass_defconfig`

Espressif's public musl toolchain, boot stack and kernel; busybox init;
Greengrass Lite v2.7.0 with `GGL_PORTABLE_CORE` and `ggl-svcd`.

A fresh clone of this repository builds into an empty work area in 18–19
minutes on a 32-core workstation (downloads cached; 31 minutes when the
workstation was shared and loaded). The build is reproducible
(`BR2_REPRODUCIBLE`): a fresh clone of commit `eaf4e65` builds a
`rootfs.tar` (`217f4e84…`) and an `s31_full_flash.bin` (`37bbe780…`)
byte-for-byte identical to those of the incremental development build in
another directory, in 23 minutes (as did `be19859`, `a1ded3e`, `609a1cb`,
`228aa46` and `1190daa` before; until `be19859` the root file system was
`04f604d5…`). The
end-to-end tests below ran on those images. (These commits were later
rebased onto an empty review base; that changed their hashes, not their
trees, and the hashes here are the rebased ones.) Incremental builds keep files a
change no longer installs (Buildroot does not remove them from its target
directory): the `/data` mount point had to be removed by hand before the
images matched again. Every download (80 files) is
hash-checked with `BR2_DOWNLOAD_FORCE_CHECK_HASHES`; `esp-linux-bsp` is
fetched by esp-buildroot-external from a branch, so its hash fails the
build if that branch moves.

### End-to-end test (`development_tools/board-test.sh --cloud --reset`)

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
Four repetitions (two plain reboots, two resets) did not reproduce it.

On 2026-11-02 a similar failure ended two of three end-to-end runs at
10/14 (the default configuration). Each time, it hit the first cloud
deployment after the bootstrap reboot: `ggdeploymentd`'s data plane
request returned 200, then `tesd`'s single request for TES credentials
failed in curl ~6 s after it started. Upstream retries only timeouts and
connection, TLS-connect and transfer errors, and `ggdeploymentd` does not
ask again, so the deployment failed. The removal, health and cold-reset
checks that need the demo deployed then failed with it. Neither DNS (400
lookups of both endpoints on the board through musl's resolver, none
failed or slow) nor the endpoint (the same request from the workstation
with the device's certificate: 200, three times) showed a fault.

That libcurl was built without error strings (curl reported only "Error").
The image now enables `BR2_PACKAGE_LIBCURL_VERBOSE`, which names the error
in the log (`Curl request failed due to error: …`). It costs ~36 kB of
MemAvailable (5604 kB vs 5640 kB, 3 minutes after a cold boot) and changes
`rootfs.tar` only (to `217f4e84…`; the flash image is unchanged). With it,
five consecutive end-to-end runs passed 14/14, and the failure did not
recur.

The cause was a slow name server, which upstream does not retry (patch
0008). The board's lookup test above asked within the endpoints' 60 s DNS
TTL, so mostly the router's cache answered. Every credentials or data
plane request on the device comes minutes after the previous one, so it
asks the router's upstream again. Querying the router once a minute
(past the TTL) for both endpoints for 3 hours: median 13 ms, and one
answer took 5039 ms, longer than musl's resolver waits (5 s). That fits
a failure ~6 s into the request. Reproduced on the board: with lookups
made to time out for 15 s (`resolv.conf` pointing at an address that
does not answer) as a cloud deployment arrived, `ggdeploymentd` logged
`Curl request failed due to error: Could not resolve hostname` and the
deployment FAILED. With patch 0008, which retries this error as upstream
retries a failed connection (backoff from 1 s), the same test ended in
SUCCEEDED, 5 s after the name server answered again.

Also seen once in nine runs on 2026-11-03: a local deployment failed
because `ggconfigd` answered a request from `ggdeploymentd` after 18 s,
past the core bus's 10 s timeout. NFS showed no retransmissions (round
trips ~10–35 ms); SQLite takes ~94 ms per transaction on this CPU even in
RAM, and a deployment reads evicted program code again (see "Memory
margin"), which is the likely reason. Not reproduced.

### Device identity: fleet provisioning

| | Measured |
| --- | --- |
| Fresh boot to provisioned and running | provisioning starts ~23 s after reset, takes 37 s; Greengrass runs as the new device at ~60 s uptime |
| First certificate request | sent before the MQTT connection is up (it takes ~11 s): failed without patch 0005, retried 3 s later with it |
| State in RAM (`--fresh`) after provisioning | 56 KB of the 4 MiB tmpfs |
| Persistent storage, cold reset | same certificate, the cloud-deployed demo back |
| No storage, cold reset | a new certificate on the same Thing, nothing deployed |
| Superseded certificates | one per fresh boot; `development_tools/aws-clean-certs.sh` removed them, keeping the device's (certificate ID checked against the device's PEM) |
| AWS resources (`scripts/aws-provision.sh`) | thing group, provisioning template and IAM role, claim policy and certificate created; token-exchange role and alias, service role reused. An unrelated `test_fleet_provisioning` template in the account was left alone |

Two pitfalls found on the way: `fleet-provisioning`'s options take
attached values only (`--template-params=JSON`, not `-p JSON`); and the
clean-up must only run for devices without storage, since a device with
storage keeps its first certificate (removing it cut a persistent device
off once during these tests; it was re-provisioned).

### ggl-svc against systemd, and fuzzed (`development_tools/ggl-svc`)

Conformance (`development_tools/ggl-svc/conformance/run.sh`): 23 scenarios of the
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
the pinned release with the patch series. Three scenarios added with the
security review (below: a very long unit file line, a working directory
only root can reach, the signals a unit starts with) bring it to 26
scenarios and 35 checkpoints. The third showed one more difference:
systemd starts services with SIGPIPE ignored (`IgnoreSIGPIPE=`, true by
default), ggl-svcd did not; patch 0007 fixes it, and all 35 match.

Fuzzing (`development_tools/ggl-svc/fuzz/run.sh 900`), libFuzzer with
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

### Security review of ggl-svc

A third independent review treated ggl-svc as a security boundary, with
three attackers: a deployed component (`gg_component`), a compromised
`ggcore` daemon, and any local user. It built ggl-svcd natively and
confirmed findings with proofs of concept in privileged containers. One
premise frames the ratings: a recipe may ask to run as root
(`RequiresPrivilege`), and `ggcore` writes the unit files deployments
link, so neither the recipe author nor `ggcore` is less than root, on
systemd as here. No critical or high findings.

| Severity | Finding | Fixed in patch 0007 | Verified |
| --- | --- | --- | --- |
| Medium | A unit file line longer than the 768-byte read buffer was parsed in two pieces, the second as a setting of its own: a long `ComponentDescription` could add `X-GGL-ReadySocket=<path>`, which root unlinked at every start (PoC: root deleted a 0600 root file) | Lines fit the whole unit file; a line or value that does not fit fails the unit; only core units may name a readiness socket, removed only if it is a socket | PoC: file kept, unit runs; conformance `long_line` |
| Medium | Unit output went through `syslog()`, which blocks once syslogd falls behind: a component writing fast enough stalled ggl-svcd and every IPC authentication (`whois` 6.5 s with a 1 ms/message syslogd) | Non-blocking log socket; while syslogd is behind, a unit's output waits in its pipe (the unit is slowed, nothing is lost); 1000 lines per 30 s per unit; requests served before output | PoC: `whois` 0.2 ms; on the board, see below |
| Low | `X-GGL-ReadySocket` honoured for any unit, and its path unlinked whatever it was | As above | PoC |
| Low | `whois` read `/proc/<pid>/cgroup` in 224-byte pieces and could match the rest of a long line (PoC, with a delegated cgroup; the board has no delegation) | Only whole lines match | PoC: `no unit` |
| Low | No resource limits per unit; ggl-svcd could be OOM-killed | ggl-svcd exempt from the OOM killer, as PID 1 under systemd; units are not. Limits: not covered (`docs/architecture.md`) | On the board: `oom_score_adj` -1000 / 0 |
| Low | `WorkingDirectory` entered as root, before dropping privileges (PoC: a unit read under a root-only directory) | Entered as the unit's user, as systemd | PoC; conformance `workdir_as_user` |
| Low | Units inherited signals ggl-svcd was started with as ignored (SIGQUIT, from the init script's background job) | Every signal reset | PoC; on the board: `SigIgn` 0 |
| Info | A linked unit could carry a core unit's name; a stale comment on caller identity; the docs overstated what running units from a copy protects | Refused at load; comment and `docs/architecture.md` corrected | |
| Info | Caller identity looked up by PID after connect (as `sd_pid_get_unit()`); `signal_cgroup` SIGTERMs PIDs one by one (SIGKILL uses `cgroup.kill`); components share one user and can read each other's IPC tokens (upstream default) | Not changed; documented under "Not covered" | |

The review also traced a possible injection through a configuration
variable in a recipe's `Timeout`. It is not reachable in v2.7.0:
`ggl-recipe` accepts `Timeout` only as an integer, or a string that
parses as one, and rewrites it as digits before the unit file is
written.

On the board, with the image that has patch 0007 (one unit owned by
`gg_component`, busybox syslogd):

| | Before | After |
| --- | --- | --- |
| Burst of 100 / 300 / 1000 lines (`seq`) | (blocking `syslog()`) | all logged, none dropped |
| First version of the fix, dropping on a full socket after 100 ms | | 3–4 %, 17 %, 15–19 % dropped: on one CPU core, syslogd cannot run while ggl-svcd sends, hence the change to hold output back |
| `yes` writing as fast as it can | | 1000 lines per 30 s logged, rest counted as suppressed, none dropped; `systemctl show` 200 ms on average (87 ms idle), max 250 ms |

Rebuilt with the changes, the fuzzers ran 15 minutes per target without
findings (unit file parser: 43.6 million inputs; control protocol: 2.74
million), and all 35 conformance checkpoints match.

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

### Memory margin

`MemAvailable` overstates what is free: it counts page cache that holds
program code, and the root file system is on NFS, so code evicted from
RAM is read again over the network. The real margin was measured by
taking memory away with an unswappable tmpfs balloon and, at each size,
deploying and removing a small local component (`ggl-cli`), counting
`workingset_refault_file` (file pages read again after eviction). Image
with patch 0007, demo deployed, after the earlier tests of that boot
(`Mapped` 4868 kB, `AnonPages` 4584 kB):

| Balloon | MemAvailable before | lowest | File pages read again | Deploy | Remove | SSH command |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 4396 kB | 4088 kB | 3,597 (14 MiB) | 47 s | 34 s | 0.24 s |
| 1 MiB | 3568 kB | 2124 kB | 24,137 (94 MiB) | 78 s | 113 s | 0.19 s |
| 2 MiB | 2496 kB | 1048 kB | 452,030 (1.7 GiB) | 2094 s | `ggl-cli` failed | 23 s |

So components have about 1 MiB: with 1 MiB taken, deployments slow down
by half; with 2 MiB, the board thrashes (and recovers once the memory is
returned). Even with nothing taken, a deployment reads code again. This
also settles the systemd question: a trimmed systemd (no D-Bus daemon,
udev or timesyncd; journald with no storage) would need an estimated 1.5
to 2.5 MiB more than ggl-svc.

The lever is the code itself: `Mapped` (file pages mapped by processes,
mostly program code) is 4.3 to 5.4 MiB. Running it in place from NOR
flash (cramfs XIP, which the kernel supports) would take it out of RAM,
but the runtime files need about 7 MiB of flash in that form, against
4 MiB for the root file system in the public flash layout.

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

Re-run from the committed configuration (`development_tools/systemd-evaluation`, built
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
