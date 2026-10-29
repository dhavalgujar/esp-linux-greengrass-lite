#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Install the built root filesystem into the NFS export, plus the device's
# Greengrass credentials and a development SSH key:
#
#   scripts/nfs-deploy.sh <thing-name> [--clean]
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
# The SSH host keys (/etc/dropbear) are carried over, and so is the
# Greengrass state (/var/lib/greengrass, /var/lib/ggl-svc) unless --clean
# is given. For a consistent copy of that state, stop Greengrass on the
# board first (/etc/init.d/S95greengrass stop).
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
thing=${1:?usage: $0 <thing-name> [--clean]}
clean=${2:-}
container=${S31_NFS_CONTAINER:-s31-ggl-nfs}
nfs_dir=${S31_NFS_DIR:-$work/nfs}
export_dir=${S31_NFS_EXPORT:-/srv/nfs/ggl}
name=$(basename "${S31_DEFCONFIG:-esp32s31_fcb_greengrass_defconfig}" _defconfig)
rootfs=$work/out/$name/images/rootfs.tar
secrets=$work/secrets/$thing
nfs_root=${S31_NFS_ROOT:-rootfs}
root=$nfs_dir/$nfs_root
target=$export_dir/$nfs_root

test -f "$rootfs"
test -f "$secrets/config.yaml"
docker inspect -f '{{.State.Running}}' "$container" | grep -qx true

new=$target.new
docker exec "$container" rm -rf "$new" "$target.old"
docker exec "$container" mkdir -p "$new"
docker exec -i "$container" tar -C "$new" -xpf - <"$rootfs"

# On a writable root, dropbear's init script turns the /etc/dropbear symlink
# into a directory holding the persistent host keys: carry it over, so that
# the board keeps its SSH identity.
keep=etc/dropbear
if [ "$clean" != --clean ]; then
	keep="$keep var/lib/greengrass var/lib/ggl-svc"
fi
docker exec "$container" sh -c '
	old=$1 new=$2
	shift 2
	for dir in "$@"; do
		if [ -d "$old/$dir" ] && [ ! -L "$old/$dir" ]; then
			rm -rf "${new:?}/$dir"
			cp -a "$old/$dir" "$new/$dir"
		fi
	done' sh "$target" "$new" $keep

# Read the ids from the tree just written through the container, so they
# match whatever the export actually holds.
uid_of() {
	docker exec "$container" cat "$new/etc/passwd" |
		awk -F: -v u="$1" '$1 == u { print $3 }'
}
gid_of() {
	docker exec "$container" cat "$new/etc/group" |
		awk -F: -v g="$1" '$1 == g { print $3 }'
}
ggcore_uid=$(uid_of ggcore)
ggcore_gid=$(gid_of ggcore)
test -n "$ggcore_uid" && test -n "$ggcore_gid"

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
	mkdir -p "$files/etc/greengrass/config.d" \
		"$files/var/lib/greengrass/credentials" "$files/root/.ssh"
	cp "$secrets/config.yaml" "$files/etc/greengrass/config.yaml"
	cp "$secrets/device.pem.crt" "$secrets/private.pem.key" \
		"$secrets/AmazonRootCA1.pem" "$files/var/lib/greengrass/credentials/"
	cp "$ssh_key.pub" "$files/root/.ssh/authorized_keys"
)
chmod 0700 "$files/root/.ssh"
chmod 0755 "$files/etc/greengrass" "$files/etc/greengrass/config.d"
chmod 0644 "$files/etc/greengrass/config.yaml"
chmod 0755 "$files/var/lib/greengrass"
chmod 0700 "$files/var/lib/greengrass/credentials"
chmod 0644 "$files/var/lib/greengrass/credentials/device.pem.crt" \
	"$files/var/lib/greengrass/credentials/AmazonRootCA1.pem"
chmod 0600 "$files/var/lib/greengrass/credentials/private.pem.key"

# Name only the leaf directories: tar then leaves the root's own /etc, /var,
# /var/lib and /root (modes and owners) untouched.
tar -C "$files" -cf - --owner=0 --group=0 etc/greengrass root/.ssh |
	docker exec -i "$container" tar -C "$new" -xpf -
tar -C "$files" -cf - --owner="$ggcore_uid" --group="$ggcore_gid" \
	--numeric-owner var/lib/greengrass |
	docker exec -i "$container" tar -C "$new" -xpf -

# Swap: NFS file handles follow the inodes (no_subtree_check), so a running
# board is unaffected by the rename.
docker exec "$container" sh -c '
	if [ -d "$1" ]; then mv "$1" "$1.old"; fi
	mv "$1.new" "$1"' sh "$target"

echo "Deployed the root filesystem for $thing to $root"
echo "SSH: ssh -i $ssh_key root@<board-ip>"
