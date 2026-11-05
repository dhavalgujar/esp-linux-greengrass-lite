<!--
SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
SPDX-License-Identifier: Apache-2.0
-->

# How Greengrass Lite runs on the board

Greengrass nucleus lite is built around systemd: each daemon is a systemd
service started through socket activation, `greengrass-lite.target` groups
them, deployed components become generated unit files that
`ggdeploymentd` links and starts with `systemctl`, `gghealthd` derives
component lifecycle states from systemd's D-Bus API, and `ggipcd`
identifies IPC callers by their systemd unit. This image runs it exactly
so: upstream's units, as upstream installs them
(`package/aws-greengrass-lite`), under systemd.

## What the board adds

Around Greengrass, not in it (`board/esp32s31-fcb/rootfs_overlay`):

| | Why |
| --- | --- |
| `esp32s31-ggl-identity.service` | Before Greengrass starts: sets up `/var/lib`, applies a connection kit, and reloads systemd so that the units of deployed components, linked from `/var/lib`, resolve (`docs/identity.md`) |
| `esp32s31-run-tmpfs.service` | `systemctl daemon-reload` refuses to run with less than 16 MiB free under `/run`, and Buildroot sizes `/run` at 20 % of RAM; it raises the cap to 32 MiB (pages are still allocated on demand) |
| journald in RAM, 2 MiB at most | no storage for a persistent journal; keeps it small |
| systemd-timesyncd | TLS needs the time; the board has no battery-backed clock |

The kernel gets its root file system over NFS (`ip=dhcp root=/dev/nfs`),
and `/var/lib` from a second NFS directory through `/etc/fstab`
(`scripts/nfs-deploy.sh`).

## Boot

From reset (`development_tools/results.md`): the kernel has its NFS root
after about 5 s; systemd reaches multi-user (SSH) after about 2 to 2.5
minutes; the identity service and the Greengrass daemons follow, and the
TLS connection to AWS IoT Core takes 10 to 15 s more. Code is read over
NFS while it runs, which dominates.

## Memory

The board gives Linux 31 MiB. With all Greengrass daemons running,
MemAvailable is about 13 MiB, and anonymous memory about 8.5 MiB, of which
systemd, journald and D-Bus are a large part. MemAvailable counts the page
cache that holds program code (glibc, systemd's 3 MB shared library,
Greengrass), which the board needs again: while a deployment runs, systemd
reloads its units and the working set grows by about 5 MiB, so code is
evicted and read again, and deployments take minutes. Under that load,
Greengrass's own timeouts fire (10 s on the core bus between its daemons,
25 s on D-Bus to systemd) and deployments fail intermittently: 5 of 14
checks passed in the full end-to-end test (`development_tools/results.md`).
Components should be small; `development_tools/memory-margin.sh` measures
what is left.

On the 16 MiB board, the same systemd stack does not fit: it thrashes
before it reaches a login. An experimental configuration for that board,
with a purpose-built service manager in place of systemd, is under review
separately (branch `esp32s31-greengrass-lite-16mib`).

## One CPU core

Espressif's kernel runs Linux on both cores since its November 2026
integration branch. Measured on this board, SMP costs 336 kB of RAM, about
1 MB of available memory, and 0.4 MB more kernel in flash, and did not
make Greengrass faster; `linux-uniprocessor.fragment` keeps one core.

## Reboots

`ggdeploymentd` reboots the device once a deployment's bootstrap steps have
run, and resumes the deployment after the boot. Two fixes make this work:

- the public OpenSBI serviced reboot by resetting CPU core 0 only, and
  the chip never came back. The patch in `board/esp32s31-fcb/patches/opensbi`
  uses the digital-system reset the boot ROM's `software_reset()` uses;
- upstream Greengrass Lite resumed the deployment with a NUL-padded IoT
  Jobs ID, which AWS IoT Jobs rejects, so the cloud deployment never
  completed (patch 0002).

Upstream resumes only cloud deployments after the reboot: the saved
state requires the IoT Jobs ID. A local (`ggl-cli`) deployment with a
bootstrap step stops at the reboot.

## Not covered

- resource limits for components: the kernel has the cgroup pids
  controller but no memory controller, which would cost RAM;
- fleet provisioning (`docs/identity.md`).
