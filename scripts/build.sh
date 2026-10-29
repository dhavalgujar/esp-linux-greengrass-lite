#!/bin/sh
# Build the image: scripts/build.sh [make targets...]
#
#   S31_WORK         work area holding deps/, dl/ and out/ (default: repo/..)
#   S31_NFS_SERVER   NFS server the board mounts its root from
#   S31_NFS_EXPORT   exported directory (default: /srv/nfs/ggl)
#   S31_NFS_ROOT     root directory inside the export (default: rootfs)
#   S31_DEFCONFIG    defconfig file (default:
#                    configs/esp32s31_fcb_greengrass_defconfig)
#   ESP_ESPTOOL      ESP32-S31-capable esptool (default: from PATH)
#
# Output: $S31_WORK/out/<defconfig name>/images/s31_full_flash.bin (boot
# stack + XIP kernel) and rootfs.tar (the NFS root).
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
nfs_server=${S31_NFS_SERVER:?set S31_NFS_SERVER to the NFS server address on the board network}
nfs_export=${S31_NFS_EXPORT:-/srv/nfs/ggl}
nfs_root=${S31_NFS_ROOT:-rootfs}
defconfig=${S31_DEFCONFIG:-$repo/configs/esp32s31_fcb_greengrass_defconfig}
name=$(basename "$defconfig" _defconfig)
out=$work/out/$name
export BR2_DL_DIR=${BR2_DL_DIR:-$work/dl}

"$repo/scripts/fetch-sources.sh"
br=$work/deps/buildroot
externals=$work/deps/esp-buildroot-external:$repo

# Re-apply the defconfig every time so that edits to it take effect.
make -C "$br" BR2_EXTERNAL="$externals" O="$out" \
	BR2_DEFCONFIG="$defconfig" defconfig

# The kernel command line carries the NFS root location. Rewrite it only when
# it changes, and then force the kernel to be reconfigured: Buildroot does
# not track fragment contents.
# Keep the public device tree's swiotlb=128 (256 KiB): without it the kernel
# reserves the largest power-of-two bounce buffer that fits, ~8 MiB of the
# board's 16 MiB.
cmdline="earlycon=sbi console=ttyS0 swiotlb=128 ip=dhcp root=/dev/nfs"
cmdline="$cmdline nfsroot=$nfs_server:$nfs_export/$nfs_root,vers=3,tcp,nolock rw"
fragment=$out/nfsroot-cmdline.fragment
new=$(printf 'CONFIG_CMDLINE="%s"\n' "$cmdline")
if [ ! -f "$fragment" ] || [ "$(cat "$fragment")" != "$new" ]; then
	printf '%s\n' "$new" >"$fragment"
	if [ -f "$out/build/linux-custom/.stamp_configured" ]; then
		make -C "$br" O="$out" linux-reconfigure
	fi
fi

exec make -C "$br" O="$out" "$@"
