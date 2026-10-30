#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Install the built root filesystem into the NFS export, with the device's
# identity and a development SSH key:
#
#   scripts/nfs-deploy.sh [--kit <connection-kit>] [--claim <fleet>]
#       [--kit-on-storage <connection-kit>] [--clean] [--fresh]
#
#   --kit <connection-kit>   the device's identity in the image: a connection
#                            kit (the .zip the AWS IoT console downloads for a
#                            nucleus lite core device, or one from
#                            scripts/aws-provision.sh --device; or a directory
#                            with its files), installed in
#                            /etc/greengrass/connection-kit
#   --claim <fleet>          fleet provisioning: the fleet's claim and
#                            config.yaml (scripts/aws-provision.sh <fleet>)
#   --kit-on-storage <kit>   a generic image, and the connection kit put on the
#                            board's storage (/var/lib/greengrass/connection-kit)
#                            for the device to apply at its next boot
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
# The device's state (credentials, configuration database, deployed
# components) is not part of the root: it lives in /var/lib (see
# S95greengrass). Here the board's persistent storage is a second directory
# in the export, <root>-data, mounted on /var/lib through /etc/fstab.
#   --fresh  no /var/lib mount: the device keeps its state in RAM, as a board
#            without storage
#   --clean  start the device over: its state is set aside
#            (<root>-data.old), and it takes its identity again at its next
#            boot
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
usage="usage: $0 [--kit <kit>] [--claim <fleet>] [--kit-on-storage <kit>] [--clean] [--fresh]"
kit=
fleet=
storage_kit=
clean=
fresh=
while [ $# -gt 0 ]; do
	case $1 in
	--kit) kit=${2:?$usage}; shift 2 ;;
	--claim) fleet=${2:?$usage}; shift 2 ;;
	--kit-on-storage) storage_kit=${2:?$usage}; shift 2 ;;
	--clean) clean=1; shift ;;
	--fresh) fresh=1; shift ;;
	*) echo "$usage" >&2; exit 2 ;;
	esac
done
if [ -n "$kit" ] && [ -n "$fleet" ]; then
	echo "--kit and --claim are alternatives" >&2
	exit 2
fi
container=${S31_NFS_CONTAINER:-s31-ggl-nfs}
nfs_dir=${S31_NFS_DIR:-$work/nfs}
export_dir=${S31_NFS_EXPORT:-/srv/nfs/ggl}
name=$(basename "${S31_DEFCONFIG:-esp32s31_fcb_greengrass_defconfig}" _defconfig)
rootfs=$work/out/$name/images/rootfs.tar
nfs_root=${S31_NFS_ROOT:-rootfs}
root=$nfs_dir/$nfs_root
target=$export_dir/$nfs_root
data=$target-data
fragment=$work/out/$name/nfsroot-cmdline.fragment

test -f "$rootfs"
if [ -n "$fleet" ]; then
	secrets=$work/secrets/$fleet
	test -f "$secrets/config.yaml"
	test -f "$secrets/claim/claim.pem.crt"
fi
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
	printf '%s:%s\t/var/lib\tnfs\tvers=3,proto=tcp,nolock,addr=%s\t0\t0\n' \
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

# A connection kit's four files, from a .zip or a directory.
unpack_kit() {
	(umask 077 && mkdir -p "$2")
	if [ -d "$1" ]; then
		cp "$1/config.yaml" "$1/device.pem.crt" "$1/private.pem.key" \
			"$1/AmazonRootCA1.pem" "$2/"
	else
		unzip -qjo "$1" config.yaml device.pem.crt private.pem.key \
			AmazonRootCA1.pem -d "$2"
	fi
	chmod 0640 "$2"/*
}

# Read the ids from the tree just written through the container, so they
# match whatever the export actually holds.
id_of() {
	docker exec "$container" cat "$new/etc/$1" |
		awk -F: -v n="$2" '$1 == n { print $3 }'
}
ggcore_uid=$(id_of passwd ggcore)
ggcore_gid=$(id_of group ggcore)
test -n "$ggcore_uid" && test -n "$ggcore_gid"

(
	umask 077
	mkdir -p "$files/root/.ssh"
	cp "$ssh_key.pub" "$files/root/.ssh/authorized_keys"
)
chmod 0700 "$files/root/.ssh"
tar -C "$files" -cf - --owner=0 --group=0 root/.ssh |
	docker exec -i "$container" tar -C "$new" -xpf -

if [ -n "$fleet" ]; then
	(
		umask 077
		mkdir -p "$files/claim/etc/greengrass/claim"
		cp "$secrets/config.yaml" "$files/claim/etc/greengrass/config.yaml"
		cp "$secrets/claim/claim.pem.crt" "$secrets/claim/claim.pem.key" \
			"$secrets/claim/AmazonRootCA1.pem" \
			"$files/claim/etc/greengrass/claim/"
	)
	chmod 0644 "$files/claim/etc/greengrass/config.yaml" \
		"$files/claim/etc/greengrass/claim/claim.pem.crt" \
		"$files/claim/etc/greengrass/claim/AmazonRootCA1.pem"
	# Only fleet-provisioning, which runs as root, reads the claim.
	chmod 0700 "$files/claim/etc/greengrass/claim"
	# Name only the files and the leaf directory: tar then leaves /etc and
	# /etc/greengrass (modes, owners, the config.d link) untouched.
	tar -C "$files/claim" -cf - --owner=0 --group=0 \
		etc/greengrass/config.yaml etc/greengrass/claim |
		docker exec -i "$container" tar -C "$new" -xpf -
fi

if [ -n "$kit" ]; then
	unpack_kit "$kit" "$files/kit/etc/greengrass/connection-kit"
	# S95greengrass applies the kit as ggcore.
	chmod 0750 "$files/kit/etc/greengrass/connection-kit"
	tar -C "$files/kit" -cf - --owner=0 --group="$ggcore_gid" --numeric-owner \
		etc/greengrass/connection-kit |
		docker exec -i "$container" tar -C "$new" -xpf -
fi

if [ -n "$storage_kit" ]; then
	unpack_kit "$storage_kit" "$files/storage/greengrass/connection-kit"
	chmod 0750 "$files/storage/greengrass/connection-kit"
	docker exec "$container" sh -c 'mkdir -p "$1/greengrass" &&
		chown "$2:$3" "$1/greengrass"' sh "$data" "$ggcore_uid" "$ggcore_gid"
	tar -C "$files/storage" -cf - --owner="$ggcore_uid" \
		--group="$ggcore_gid" --numeric-owner greengrass/connection-kit |
		docker exec -i "$container" tar -C "$data" -xpf -
fi

# Swap: NFS file handles follow the inodes (no_subtree_check), so a running
# board is unaffected by the rename.
docker exec "$container" sh -c '
	if [ -d "$1" ]; then mv "$1" "$1.old"; fi
	mv "$1.new" "$1"' sh "$target"

identity="no identity"
[ -n "$kit" ] && identity="connection kit $kit"
[ -n "$fleet" ] && identity="fleet $fleet (claim)"
[ -n "$storage_kit" ] && identity="$identity; on storage: $storage_kit"
if [ -n "$fresh" ]; then
	echo "Deployed the root filesystem to $root ($identity; state in RAM)"
else
	echo "Deployed the root filesystem to $root ($identity; state: $data)"
fi
echo "SSH: ssh -i $ssh_key root@<board-ip>"
