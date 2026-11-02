<!--
SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
SPDX-License-Identifier: Apache-2.0
-->

# Troubleshooting

The component, Greengrass and the network, layer by layer:
`examples/cloud/greengrass-hello/README.rst`.

## The board

- **SSH times out, the board answers no ARP:** it may sit in the ROM's
  download mode (a tool that opened its serial port can put it there).
  `esptool --port <port> --before no-reset --after no-reset read-mac`
  answering with its MAC confirms it. Pulse EN with RTS while keeping DTR
  released to boot it; `--after hard-reset` can leave it in download
  mode.
- **`reboot` never comes back:** the image lacks the OpenSBI patch in
  `board/esp32s31-fcb/patches/opensbi`.
- **SSH connects but never completes, `/proc` is missing:** the root was
  rewritten underneath the running board by something other than
  `scripts/nfs-deploy.sh`; reset it.

## Access and recipes

- Dropbear (SSH) is in the image for development and for
  `development_tools/board-test.sh` only; Greengrass does not use it.
  Opening the board's USB-UART resets it (its CP2102N drives EN): use SSH
  for inspection, and `development_tools/s31-console.py` when a console is
  needed.
- Recipes given to `ggl-cli deploy -r` are copied with their file mode, and
  components run as `gg_component`: keep them world-readable.
- Without the account's Greengrass service role association, deployments
  are recorded but never reach the device.
- **A cloud deployment FAILED with "Curl request failed":** the log names
  curl's error (`grep "Curl request failed" /var/log/messages`). HTTP
  requests are retried with backoff on timeouts, failed connections and
  host names that did not resolve (patch 0008); other errors fail the
  deployment, and revising the deployment retries it.
