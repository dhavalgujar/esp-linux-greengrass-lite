# Greengrass Lite without systemd

Greengrass nucleus lite is designed around systemd: each daemon is a
systemd service started through socket activation, deployed components
become generated unit files that `ggdeploymentd` manages with `systemctl`,
`gghealthd` derives component lifecycle states from systemd's D-Bus API,
and `ggipcd` identifies IPC callers by their systemd unit.

On the ESP32-S31 Function-CoreBoard (16 MiB PSRAM, ~14.7 MiB for Linux)
systemd does not fit: a glibc/systemd image thrashes before Greengrass even
starts (see `results.md`). This repository therefore builds Greengrass Lite
for Espressif's public musl/busybox image with `GGL_PORTABLE_CORE=ON`,
which replaces exactly those four systemd dependencies:

| systemd role | Replacement (`package/aws-greengrass-lite/*.patch`) |
| --- | --- |
| Service manager, socket activation | `ggl-svcd`: runs the core daemon units in `/usr/lib/ggl-svc` and every unit a deployment generates; a core daemon is "active" once its core-bus socket exists (`X-GGL-ReadySocket`) |
| `systemctl` | `/usr/bin/systemctl` front end for the commands `ggdeploymentd` issues: `link`, `enable`, `disable`, `start`, `stop`, `restart`, `daemon-reload`, `reset-failed`, `reboot` |
| systemd D-Bus API (`gghealthd`) | `gghealthd` portable backend: unit state and change notifications from `ggl-svcd`, with the same mapping to Greengrass lifecycle states |
| `sd_pid_get_unit` (`ggipcd` authentication) | `GGL_COMPONENT_NAME`, set by `ggl-svcd` for every process it starts and read from `/proc/<pid>/environ` |
| journald | `ggl-svcd` forwards each unit's output, line by line and tagged with the unit, to busybox syslogd (`/var/log/messages`, rotated) |

Everything above the service manager is upstream Greengrass Lite: the same
deployment daemon, recipe-to-unit generator, recipe runner, IPC, MQTT, TES
and fleet-status code. Deployments from the AWS console or from
`ggl-cli` behave as they do on a systemd host.

## ggl-svcd

A single-threaded C program (`modules/ggl-svc` in the patch series). It
implements the subset of systemd unit semantics that Greengrass Lite's
generated units use:

- `Type=exec|simple|oneshot|notify`, `ExecStart`, `User`, `Group`,
  `WorkingDirectory`, `Environment`;
- `Restart=no|on-failure|always`, `RestartSec`, `RemainAfterExit`,
  `SuccessExitStatus`, start limits (`StartLimitIntervalSec`,
  `StartLimitBurst`) and start/stop timeouts (`TimeoutStartSec`,
  `TimeoutStopSec`, `TimeoutSec`), with systemd's defaults;
- ordering: `After=`, `Wants=` and `BindsTo=` between `ggl.*` units;
- the properties `gghealthd` reads: `ActiveState`, `Result`, `NRestarts`
  (reset by a manual start, as in systemd) and
  `InactiveEnterTimestampMonotonic`.

Each unit runs in its own session, which stands in for its cgroup: the
processes a unit leaves behind are terminated when it stops or exits
(unless it remains active), and a process is mapped to its unit by session
or ancestry, which cannot be forged. `ggipc-auth` uses that mapping
(`whois`) to identify IPC callers. `systemd-notify`, which recipe-runner
calls at the end of every startup phase, is provided and notifies the
caller's own unit.

`systemctl start`, `restart` and `stop` wait for the job to finish unless
`--no-block` is given, and fail if the start failed, as with systemd.

Units linked and enabled by deployments persist in `/var/lib/ggl-svc`,
which only root can write, so deployed components start again at boot,
like `greengrass-lite.target` on systemd.

Control is a line protocol on `/run/ggl-svc.sock` (`ggl/svc.h`). Requests
are read without blocking the service manager. Only root may change
state; other users may query a unit, look up a process's unit, and notify
their own unit.

Privileges follow the upstream units: `ggconfigd`, `ggpubsubd`, `ggipcd`,
`iotcored`, `tesd`, `tes-serverd` and `gg-fleet-statusd` run as `ggcore`;
`ggdeploymentd` and `gghealthd` as root with group `ggcore`; components as
`gg_component`.

## Not covered

- cgroup resource limits (systemd slices) for components;
- a process that leaves its unit's session and is re-parented to init is
  no longer attributed to the unit (systemd keeps it in the cgroup);
- `ggdeploymentd` bootstrap phases that require a reboot are run
  (`systemctl start` blocks until they finish, then `systemctl reboot`) but
  have not been exercised on the board.
