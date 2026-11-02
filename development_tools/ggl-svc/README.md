<!--
SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
SPDX-License-Identifier: Apache-2.0
-->

# Testing ggl-svc

`ggl-svc` (patches 0003, 0006 and 0007) is a service manager written for this
repository, standing in for systemd. Besides `development_tools/board-test.sh`, which
runs Greengrass on the board, two workstation tests check it where it is
most likely to be wrong or attackable. Both build ggl-svc from the pinned
Greengrass Lite release with this repository's patches
(`prepare-src.sh`), so they test what the image ships.

## Conformance with systemd

```sh
development_tools/ggl-svc/conformance/run.sh [scenario ...]
```

Runs the same unit files under systemd 255 and under `ggl-svcd`, each as
PID 1 of a privileged Ubuntu 24.04 container (Docker, its own cgroup
namespace), and compares what both report at each checkpoint:
ActiveState, Result and NRestarts (what `gghealthd` derives lifecycle
states from), plus processes left over and the environment a unit runs
with. systemd is the reference: a difference is a bug in ggl-svc, or a
deliberate deviation listed in `conformance/deviations.txt`.

The scenarios (`conformance/scenarios.sh`) cover the units Greengrass Lite
generates and runs: `Type=exec` run phases (exit codes,
`SuccessExitStatus`, crashes, `Restart=` with the start limit
recipe2unit sets, manual restarts), `Type=oneshot` install and bootstrap
phases (`RemainAfterExit`, timeouts), `Type=notify` startup phases
(readiness, never ready, timeout, `NotifyAccess=`), stopping (the whole
cgroup, leftovers, `TimeoutStopSec`), `BindsTo=`/`Wants=`/`After=`, and
`User=`/`WorkingDirectory=`/`Environment=`.

## Fuzzing

```sh
development_tools/ggl-svc/fuzz/run.sh [seconds-per-target]
```

libFuzzer with AddressSanitizer and UndefinedBehaviorSanitizer (clang) on
ggl-svcd's untrusted inputs:

- `fuzz_unit_file`: the unit file parser. Unit files come from
  deployments. Seeds: the core units, a unit recipe2unit generated on the
  board, and the conformance scenarios' units.
- `fuzz_requests`: the control protocol on `/run/ggl-svc.sock`, which any
  local user can connect to. Requests from root and from an unprivileged
  user, against linked units; verbs that would start processes are not
  sent as root.

Both compile `ggl-svcd.c` itself, with its state, cgroup and core unit
directories in `/dev/shm/ggl-svc-fuzz`.

Results are in `development_tools/results.md`.
