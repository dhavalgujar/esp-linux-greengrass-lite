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
| `/var/lib/greengrass` | Greengrass's rootPath: credentials, configuration database, deployed components |
| `/var/lib/ggl-svc` | the units deployments linked and enabled (root only) |

A board with persistent storage (an SD card, USB storage, a NAND or flash
partition, NFS) mounts it on `/var/lib` in `/etc/fstab`. Without it,
`/etc/init.d/S95greengrass` mounts a RAM file system there, and the device
starts fresh at every boot.

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

## Alternative: fleet provisioning

With `scripts/aws-provision.sh <fleet>` (no `--device`) and
`scripts/nfs-deploy.sh --claim <fleet>`, the image carries a claim
certificate instead, and a device without credentials provisions itself at
boot with [AWS IoT fleet
provisioning](https://docs.aws.amazon.com/iot/latest/developerguide/provision-wo-cert.html)
(Greengrass Lite's `fleet-provisioning`): a key generated on the device, a
certificate signed by AWS IoT, the Thing `<fleet>-<serial>` registered in
thing group `<fleet>` with a policy scoped to it. The serial is eth0's MAC
address unless `/etc/default/greengrass` sets `GGL_SERIAL`. One image
serves all boards, but anyone holding the claim can register a device in
the fleet (in production, add a pre-provisioning hook that validates the
serial number), and without storage each boot provisions a new certificate,
leaving the previous one registered (`development_tools/aws-clean-certs.sh` removes
them).

## What persists

| | Persistent storage | No storage |
| --- | --- | --- |
| Identity, kit in the image | kept | kept (applied at every boot) |
| Identity, fleet provisioning | kept | a new certificate at every boot |
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

A product would not depend on an NFS server. This board, with the public
sources, cannot hold Greengrass without one, though (measured; details in
`development_tools/results.md`):

- Greengrass needs persistent writable storage for `/var/lib/greengrass`
  (credentials, configuration database, deployed components, the state a
  bootstrap reboot resumes from). The board's flash root partition is a
  read-only ROM mapping (`physmap`, `type=rom`): the public kernel has no
  SPI-NOR write driver and no flash file system. No SD card is fitted.
- The root file system compresses to 8.7 MiB; the flash layout reserves
  4 MiB for it.

A product port therefore needs local writable storage (an SD card or eMMC
on the SDMMC host, whose block driver the kernel already has, or a
writable flash partition with an SPI-NOR driver) and a flash layout with
room for the root.
