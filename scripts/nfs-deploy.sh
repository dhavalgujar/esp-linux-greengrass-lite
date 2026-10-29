#!/bin/sh
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
# --clean removes the previous root first, including Greengrass state.
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

if [ "$clean" = --clean ]; then
	docker exec "$container" rm -rf "$target"
fi
docker exec "$container" mkdir -p "$target"
# On a writable root, dropbear's init script turns the /etc/dropbear symlink
# into a directory holding the persistent host keys; keep it once it exists.
keep=
if docker exec "$container" test -d "$target/etc/dropbear" &&
	! docker exec "$container" test -L "$target/etc/dropbear"; then
	keep=--exclude=./etc/dropbear
fi
docker exec -i "$container" tar -C "$target" --overwrite \
	$keep -xpf - <"$rootfs"

uid_of() {
	awk -F: -v u="$1" '$1 == u { print $3 }' "$root/etc/passwd"
}
gid_of() {
	awk -F: -v g="$1" '$1 == g { print $3 }' "$root/etc/group"
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

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
(
	umask 077
	mkdir -p "$stage/etc/greengrass/config.d" \
		"$stage/var/lib/greengrass/credentials" "$stage/root/.ssh"
	cp "$secrets/config.yaml" "$stage/etc/greengrass/config.yaml"
	cp "$secrets/device.pem.crt" "$secrets/private.pem.key" \
		"$secrets/AmazonRootCA1.pem" "$stage/var/lib/greengrass/credentials/"
	cp "$ssh_key.pub" "$stage/root/.ssh/authorized_keys"
)
chmod 0700 "$stage/root/.ssh"
chmod 0755 "$stage/etc/greengrass" "$stage/etc/greengrass/config.d"
chmod 0644 "$stage/etc/greengrass/config.yaml"
chmod 0755 "$stage/var/lib/greengrass"
chmod 0700 "$stage/var/lib/greengrass/credentials"
chmod 0644 "$stage/var/lib/greengrass/credentials/device.pem.crt" \
	"$stage/var/lib/greengrass/credentials/AmazonRootCA1.pem"
chmod 0600 "$stage/var/lib/greengrass/credentials/private.pem.key"

# Name only the leaf directories: tar then leaves the root's own /etc, /var,
# /var/lib and /root (modes and owners) untouched.
tar -C "$stage" -cf - --owner=0 --group=0 etc/greengrass root/.ssh |
	docker exec -i "$container" tar -C "$target" -xpf -
tar -C "$stage" -cf - --owner="$ggcore_uid" --group="$ggcore_gid" \
	--numeric-owner var/lib/greengrass |
	docker exec -i "$container" tar -C "$target" -xpf -

echo "Deployed the root filesystem for $thing to $root"
echo "SSH: ssh -i $ssh_key root@<board-ip>"
