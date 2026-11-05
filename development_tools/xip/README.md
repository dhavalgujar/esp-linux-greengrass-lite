<!--
SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
SPDX-License-Identifier: Apache-2.0
-->

# Executing program code from flash (XIP)

An experiment, not part of the shipped configuration. It measures what
running program code in place from the NOR flash frees, instead of from
page cache copies of the root file system in RAM. Results: "Executing
program code from flash (XIP)" in `../results.md`.

Linux maps code in place from a cramfs image on a memory-mapped MTD
device (`CONFIG_CRAMFS_MTD`, the `mtd-rom` physmap driver), both in
Espressif's kernel configuration. The pieces this needs:

- `mkcramfs -X -X` (cramfs-tools >= 2.1): a single `-X` aligns segments
  for Linux without an MMU, and the kernel then copies them to RAM after
  all ("data is not page aligned");
- an MTD window per image: physmap rounds a window down to a power of
  two, so the flash after the kernel (0x870000 to 0xF70000) is covered by
  windows of 4, 2 and 1 MiB, in a modified device tree;
- the images' files bound over the root file system's before Greengrass
  starts (`S94xip`).

```sh
# 1. Images and device tree from a build's images.
development_tools/xip/build.sh out/<config>/images /tmp/xip

# 2. Flash them with the esptool command build.sh prints, after checking
#    the chip's MAC (esptool read-mac). The XIP windows are flash the
#    image does not use; the device tree replaces the one at 0x300000.

# 3. On the board's root, install the boot script, and reboot.
scp development_tools/xip/S94xip root@<board-ip>:/etc/init.d/S94xip

# 4. Check: the code mappings carry "mm" (mixed map) with no Rss.
ssh root@<board-ip> 'grep -A20 " r-xp .*libcrypto" /proc/$(pidof ggdeploymentd)/smaps | grep -E "^Rss|VmFlags"'

# 5. Measure (fresh boot), with and without /etc/init.d/S94xip.
development_tools/memory-margin.sh <board-ip>
```

To undo: remove `/etc/init.d/S94xip` and flash the build's own
`esp32s31.dtb` at 0x300000 (or the whole image with `scripts/flash.sh`).
