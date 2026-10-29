#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Install the built root filesystem into the NFS export, with the fleet's
# Greengrass configuration and claim certificate (scripts/aws-provision.sh)
# and a development SSH key:
#
#   scripts/nfs-deploy.sh <fleet-name> [--clean] [--fresh]
#
#   S31_WORK         work area (default: repo/..)
#   S31_NFS_DIR      host directory exported as $S31_NFS_EXPORT (default:
#                    $S31_WORK/nfs)
#   S31_NFS_ROOT     root directory inside the export (default: rootfs)
#   S31_DEFCONFIG    defconfig the image was built from (selects the
#                    output directory, as in scripts/build.sh)
#   S31_NFS_CONTAINER  NFS server container (default: s31-ggl-nfs); files are
#                    written through it so that ownership is preserved
#                    without host root.
#
# The new root is assembled next to the current one and then swapped in by
# renaming the directories. A board running from the export keeps using its
# previous tree, now <root>.old, until it reboots; reboot it to switch, and
# before deploying again (the next deployment deletes <root>.old).
#
# The SSH host keys (/etc/dropbear) are carried over.
#
# The device's own state (its credentials once provisioned, configuration
# database, deployed components) is not part of the root: S95greengrass
# keeps it under /data. Here the board's persistent storage is a second
# directory in the export, <root>-data, mounted on /data through /etc/fstab.
#   --fresh  no /data mount: the device keeps its state in RAM, so it is
#            provisioned anew at every boot, as a board without storage
#   --clean  start the device over: its state is set aside (<root>-data.old)
#            and it is provisioned again at its next boot
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
fleet=${1:?usage: $0 <fleet-name> [--clean] [--fresh]}
shift
clean=
fresh=
for arg; do
	case $arg in
	--clean) clean=1 ;;
	--fresh) fresh=1 ;;
	*) echo "unknown option $arg" >&2; exit 2 ;;
	esac
done
container=${S31_NFS_CONTAINER:-s31-ggl-nfs}
nfs_dir=${S31_NFS_DIR:-$work/nfs}
export_dir=${S31_NFS_EXPORT:-/srv/nfs/ggl}
name=$(basename "${S31_DEFCONFIG:-esp32s31_fcb_greengrass_defconfig}" _defconfig)
rootfs=$work/out/$name/images/rootfs.tar
secrets=$work/secrets/$fleet
nfs_root=${S31_NFS_ROOT:-rootfs}
root=$nfs_dir/$nfs_root
target=$export_dir/$nfs_root
data=$target-data
fragment=$work/out/$name/nfsroot-cmdline.fragment

test -f "$rootfs"
test -f "$secrets/config.yaml"
test -f "$secrets/claim/claim.pem.crt"
docker inspect -f '{{.State.Running}}' "$container" | grep -qx true
# The NFS server the kernel mounts its root from (scripts/build.sh).
server=$(sed -n 's/.*nfsroot=\([^:]*\):.*/\1/p' "$fragment")
test -n "$server"

new=$target.new
docker exec "$container" rm -rf "$new" "$target.old"
docker exec "$container" mkdir -p "$new"
docker exec -i "$container" tar -C "$new" -xpf - <"$rootfs"

# On a writable root, dropbear's init script turns the /etc/dropbear symlink
# into a directory holding the persistent host keys: carry it over, so that
# the board keeps its SSH identity.
docker exec "$container" sh -c '
	if [ -d "$1/etc/dropbear" ] && [ ! -L "$1/etc/dropbear" ]; then
		rm -rf "$2/etc/dropbear"
		cp -a "$1/etc/dropbear" "$2/etc/dropbear"
	fi' sh "$target" "$new"

# The board's persistent storage. Set aside, not deleted, with --clean: a
# running board keeps using it until it reboots.
if [ -n "$clean" ]; then
	docker exec "$container" sh -c '
		rm -rf "$1.old"
		if [ -d "$1" ]; then mv "$1" "$1.old"; fi' sh "$data"
fi
docker exec "$container" mkdir -p "$data"
if [ -z "$fresh" ]; then
	printf '%s:%s\t/data\tnfs\tvers=3,proto=tcp,nolock,addr=%s\t0\t0\n' \
		"$server" "$data" "$server" |
		docker exec -i "$container" sh -c 'cat >>"$1/etc/fstab"' sh "$new"
fi

# A development key for SSH as root; generated once, never committed.
ssh_key=$work/secrets/ssh/id_ed25519
if [ ! -f "$ssh_key" ]; then
	(umask 077 && mkdir -p "${ssh_key%/*}")
	ssh-keygen -q -t ed25519 -N '' -C "s31-ggl-dev" -f "$ssh_key"
fi

files=$(mktemp -d)
trap 'rm -rf "$files"' EXIT
(
	umask 077
	mkdir -p "$files/etc/greengrass/config.d" "$files/etc/greengrass/claim" \
		"$files/root/.ssh"
	cp "$secrets/config.yaml" "$files/etc/greengrass/config.yaml"
	cp "$secrets/claim/claim.pem.crt" "$secrets/claim/claim.pem.key" \
		"$secrets/claim/AmazonRootCA1.pem" "$files/etc/greengrass/claim/"
	cp "$ssh_key.pub" "$files/root/.ssh/authorized_keys"
)
chmod 0700 "$files/root/.ssh"
chmod 0755 "$files/etc/greengrass" "$files/etc/greengrass/config.d"
chmod 0644 "$files/etc/greengrass/config.yaml"
# Only fleet-provisioning, which runs as root, reads the claim.
chmod 0700 "$files/etc/greengrass/claim"
chmod 0600 "$files/etc/greengrass/claim/claim.pem.key"
chmod 0644 "$files/etc/greengrass/claim/claim.pem.crt" \
	"$files/etc/greengrass/claim/AmazonRootCA1.pem"

# Name only the leaf directories: tar then leaves the root's own /etc and
# /root (modes and owners) untouched.
tar -C "$files" -cf - --owner=0 --group=0 etc/greengrass root/.ssh |
	docker exec -i "$container" tar -C "$new" -xpf -

# Swap: NFS file handles follow the inodes (no_subtree_check), so a running
# board is unaffected by the rename.
docker exec "$container" sh -c '
	if [ -d "$1" ]; then mv "$1" "$1.old"; fi
	mv "$1.new" "$1"' sh "$target"

if [ -n "$fresh" ]; then
	echo "Deployed the root filesystem for $fleet to $root (state in RAM)"
else
	echo "Deployed the root filesystem for $fleet to $root (state: $data)"
fi
echo "SSH: ssh -i $ssh_key root@<board-ip>"
