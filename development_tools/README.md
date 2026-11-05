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
| `s31-console.py` | Serial console helper (opening the port resets the board) |

The end-to-end test, for the quick start's board:

```sh
development_tools/board-test.sh <board-ip> esp32s31-greengrass --cloud \
    --reset /dev/serial/by-id/<port> <chip-mac>
```

Add `--fresh` after `scripts/nfs-deploy.sh --fresh` (no storage). The test
reboots the board during the run, and resets it through its serial port at
the end. Both tests also run on the experimental 16 MiB configuration,
where Greengrass runs without systemd.
