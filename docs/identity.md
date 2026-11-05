<!--
SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
SPDX-License-Identifier: Apache-2.0
-->

# Device identity and state

Everything a device must remember lives in `/var/lib`, the standard place
for state that persists across reboots. Making that persistent is all a
board has to do:

| | |
| --- | --- |
| `/var/lib/greengrass` | Greengrass's rootPath: credentials, configuration database, deployed components, the unit files of deployed components |

A board with persistent storage (an SD card, USB storage, a NAND or flash
partition, NFS) mounts it on `/var/lib` in `/etc/fstab`. Without it,
`esp32s31-ggl-identity.service` mounts a RAM file system there, and the
device starts fresh at every boot.

That service (`/usr/libexec/esp32s31-ggl/identity`) runs once at boot,
after `/var/lib` is mounted and before any Greengrass unit starts. It sets
up the state directory, applies a connection kit if there is a new one,
and then has systemd load the unit files again: Greengrass links the units
of deployed components from `/var/lib/greengrass` into
`/etc/systemd/system`, and when `/var/lib` is a separate mount, as here,
systemd first loads them before it is mounted and finds nothing. Without
this, deployed components would not start again after a reboot.

## Identity: a connection kit per board (default)

As in upstream's manual provisioning and AWS's Greengrass Lite demo images,
each board gets a **connection kit**: the `.zip` the AWS IoT console
downloads under *Greengrass devices → Core devices → Set up one core
device* for nucleus lite (`device.pem.crt`, `private.pem.key`,
`AmazonRootCA1.pem`, `config.yaml`). `scripts/aws-provision.sh <fleet>
--device <name>` makes the same kit from the command line, registering
Thing `<fleet>-<name>` in thing group `<fleet>` with a policy scoped to it;
its key is created on the workstation.

The kit reaches the device in one of two ways:

- **in the image** (`/etc/greengrass/connection-kit`;
  `scripts/nfs-deploy.sh --kit`): one image per board. Without storage, the
  board still keeps its identity across reboots;
- **on the storage** (`/var/lib/greengrass/connection-kit`;
  `scripts/nfs-deploy.sh --kit-on-storage`): one image for all boards; the
  kit is applied at the next boot, then removed, as AWS's demo images do
  with a kit copied to the SD card.

Applying a kit puts its credentials in `/var/lib/greengrass/credentials`
and its configuration in `/var/lib/greengrass/config.d`
(`/etc/greengrass/config.d` links there); `/etc/greengrass/config.yaml`
holds only what every device has in common. A kit in the image is applied
when it differs from the one last applied, so flashing an image with a new
kit changes the identity once, and reflashing the same one changes nothing.
A kit for a different device starts the device over: its configuration and
deployments go, as they belong to the previous identity.

## Fleet provisioning: not on this board yet

Greengrass Lite can also provision a device itself at boot, from a claim
certificate in the image, with [AWS IoT fleet
provisioning](https://docs.aws.amazon.com/iot/latest/developerguide/provision-wo-cert.html).
On this chip, upstream's `fleet-provisioning` sends its certificate request
before its TLS connection to AWS IoT is up, and fails. A fix, and the
image support for a claim, are under review separately (branch
`esp32s31-greengrass-lite-16mib`).

## What persists

| | Persistent storage | No storage |
| --- | --- | --- |
| Identity, kit in the image | kept | kept (applied at every boot) |
| Configuration, deployed components | kept | lost at every reboot |

Without storage, a thing group's deployments are not sent again to a
device that has completed them, and a deployment with a bootstrap step
cannot outlive the reboot it needs. So deploy what such a board must
always run from the image (for example a local deployment at boot), and
treat cloud deployments as lasting until the next reboot.

## Why an NFS root, and what a product needs

The boot stack and the XIP kernel are flashed to the 16 MiB NOR flash; the
root filesystem is mounted over NFSv3 from a workstation on the same
network (the kernel does DHCP itself: `ip=dhcp root=/dev/nfs`). Rebuilds
and redeployments need no reflashing.

A product would not depend on an NFS server, and it would not keep its
root file system in this board's flash either:

- Greengrass needs persistent writable storage for `/var/lib/greengrass`
  (credentials, configuration database, deployed components, the state a
  bootstrap reboot resumes from). The board's flash root partition is a
  read-only ROM mapping (`physmap`, `type=rom`): the public kernel has no
  SPI-NOR write driver and no flash file system, and the kernel executes
  in place from the same flash.
- The root file system, with glibc and systemd, is about 50 MB; the flash
  layout reserves 4 MiB for it.

A product port therefore needs an SD card or eMMC. Espressif's BSP now
supports an ext4 root file system on an SD card
(`espressif_esp32s31_function_core_board_nor_sd_rootfs_defconfig`), which
would also hold `/var/lib`; the Function-CoreBoard has no card slot, so
this repository keeps the NFS root.
