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
| `sd_pid_get_unit` (`ggipcd` authentication) | `ggipc-auth` asks `ggl-svcd` (`whois <pid>`), which answers from the caller's cgroup (`/proc/<pid>/cgroup`) |
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
- ordering: `After=` and `Wants=` between `ggl.*` units, and `BindsTo=`
  (used for TES and for HARD component dependencies): a unit is stopped
  when the unit it is bound to stops or fails, and restarted with it;
- `Type=notify` with `NotifyAccess=main|all`; other unit types ignore
  notifications, as under systemd;
- the properties `gghealthd` reads: `ActiveState`, `Result`, `NRestarts`
  (reset by a manual start, as in systemd) and
  `InactiveEnterTimestampMonotonic`.

As under systemd, each unit runs in its own cgroup,
`/sys/fs/cgroup/ggl-svc/<unit>` (cgroup v2 process grouping only, no
controllers: the kernel needs `CONFIG_CGROUPS`). The child joins it before
it executes anything. A process cannot leave it for another unit's cgroup,
which belongs to root, and stays in it when it forks, starts a new session
or is reparented. So the cgroup is what identifies a unit's processes:
`whois <pid>` answers from `/proc/<pid>/cgroup`, and `ggipc-auth` uses it
to identify IPC callers. Stopping a unit sends SIGTERM to every process
in its cgroup and SIGKILL (`cgroup.kill`) after `TimeoutStopSec`, which
is systemd's `KillMode=control-group`. Processes a unit leaves behind when
its main process exits are treated the same way, unless the unit remains
active (`RemainAfterExit`, or a startup phase's background process).
`systemd-notify`, which recipe-runner calls at the end of every startup
phase, is provided and notifies the caller's own unit.

An earlier version used a session per unit instead of a cgroup. An
independent review showed why that is not enough. Once a session's last
process exits, a new process can obtain the same ID and take over the
session, and so the identity of the unit (PID reuse). No other
unforgeable process grouping exists without cgroups.

`systemctl start`, `restart` and `stop` wait for the job to finish unless
`--no-block` is given, and fail if the start failed, as with systemd.

Units linked and enabled by deployments persist in `/var/lib/ggl-svc`,
which only root can write, so deployed components start again at boot,
like `greengrass-lite.target` on systemd. `systemctl link` also copies the
unit file there, and the unit runs from that copy. `ggdeploymentd` writes
unit files into `/var/lib/greengrass`, which the `ggcore` user can write.
Running from the copy keeps `ggcore` from replacing a linked unit file
later with one that runs as root. Every deployment links its units again
before starting them, so the copy is always current. Systemd hosts read the
linked file itself.

Control is a line protocol on `/run/ggl-svc.sock` (`ggl/svc.h`). Requests
are read without blocking the service manager, and a non-root user can
hold at most 4 of its 16 connection slots, so it cannot lock root or
other users out. Clients give up on a request after 10 s. Only root may
change state; other users may query a unit, look up a process's unit, and
notify their own unit.

## Reboots

`ggdeploymentd` reboots the device (`systemctl reboot`) once a
deployment's bootstrap steps have run, and resumes the deployment after the
boot. Two fixes outside ggl-svc make this work on the board:

- the public OpenSBI serviced reboot by resetting CPU core 0 only, and
  the chip never came back. The patch in `board/esp32s31-fcb/patches/opensbi`
  uses the digital-system reset the boot ROM's `software_reset()` uses.
  The ROM then reports `rst:0x3 (SW_SYS_RESET)` and the board is back on
  the network in under a minute;
- upstream Greengrass Lite resumed the deployment with a NUL-padded IoT
  Jobs ID, which AWS IoT Jobs rejects, so the cloud deployment never
  completed (patch 0004).

Upstream resumes only cloud deployments after the reboot: the saved
state requires the IoT Jobs ID. A local (`ggl-cli`) deployment with a
bootstrap step stops at the reboot.

Privileges follow the upstream units: `ggconfigd`, `ggpubsubd`, `ggipcd`,
`iotcored`, `tesd`, `tes-serverd` and `gg-fleet-statusd` run as `ggcore`;
`ggdeploymentd` and `gghealthd` as root with group `ggcore`; components as
`gg_component`.

## Not covered

- resource limits (systemd slices and cgroup controllers) for
  components;
- when a component is removed, upstream disables only its run unit and
  reloads before it deletes the unit files. Under systemd this leaves
  dangling links for the install and bootstrap units. Here those
  finished units stay loaded, inactive and disabled, until the next
  `daemon-reload` or boot drops them.
