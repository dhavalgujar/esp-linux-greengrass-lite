<!--
SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
SPDX-License-Identifier: Apache-2.0
-->

# Development tools

What it takes to maintain and verify this repository; none of it is
needed to build or use it.

| | |
| --- | --- |
| `results.md` | Everything measured: test results, memory, boot times, the dependency update and SMP, findings worth keeping |
| `board-test.sh` | End-to-end checks of a running board: identity, core units, local and cloud deployments, failure handling, IPC caller identity, a deployment that reboots the device, a cold reset. It reboots the board and creates (and deletes) AWS test components. |
| `memory-margin.sh` | How much memory a running board can really spare: takes memory away step by step and deploys a component at each step, until deployments fail |
| `board-console.py` | Runs commands in the board's serial console for `board-test.sh --console`, or by hand: one server holds the port for a session (opening it resets the board) |

The end-to-end test, for the quick start's board:

```sh
development_tools/board-test.sh <board-ip> esp32s31-greengrass --cloud \
    --console /dev/serial/by-id/<port> <chip-mac>
```

`--console` runs the board commands in the serial console rather than over
SSH: a command costs the board a shell instead of an SSH server and a key
exchange (about 0.7 s against 1.3 s on an idle board), and a busy board is
slow rather than unreachable. The test then starts from a fresh boot.
`--reset <port> <chip-mac>` keeps SSH and only uses the port for the final
cold reset.

Add `--fresh` after `scripts/nfs-deploy.sh --fresh` (no storage). The test
reboots the board during the run, and resets it through its serial port at
the end. Both tests also run on the experimental 16 MiB configuration,
where Greengrass runs without systemd.
