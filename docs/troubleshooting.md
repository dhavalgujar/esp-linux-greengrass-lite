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
- **No SSH, the console ends in "VFS: Unable to mount root fs via NFS":**
  the board cannot reach the NFS server: check that the workstation is on
  the board's network at the address the image was built for
  (`S31_NFS_SERVER`).
- **SSH takes two minutes or more after a reset:** that is systemd's boot
  over NFS on this board; the first connection may also time out during
  the banner exchange while the boot finishes.

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
  curl's error (`journalctl -b | grep "Curl request failed"`). Greengrass
  retries timeouts and failed connections, not a host name that did not
  resolve: a name server slower than 5 s fails the deployment. Revising
  the deployment retries it.
- **A deployment FAILED after "Read timed out":** a core daemon, usually
  `ggconfigd`, missed the core bus's 10 s timeout. Revise the deployment.
- **A deployed component does not start after a reboot:**
  `systemctl status esp32s31-ggl-identity` must have finished: it reloads
  systemd once `/var/lib` is mounted (`docs/identity.md`).
