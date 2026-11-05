#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Builds the XIP experiment's flash images from a build's images: three
# cramfs images whose program code runs in place from flash, and a Linux
# device tree with an MTD window for each (see README.md):
#
#   development_tools/xip/build.sh <images-dir> <output-dir>
#
#   MKCRAMFS   mkcramfs from cramfs-tools >= 2.1 (with -X); default: built
#              from Buildroot's download directory (BR2_DL_DIR, default
#              $S31_WORK/dl)
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
images=${1:?usage: $0 <images-dir> <output-dir>}
out=${2:?usage: $0 <images-dir> <output-dir>}
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd)

if [ -z "${MKCRAMFS:-}" ]; then
	src=$(ls "${BR2_DL_DIR:-$work/dl}"/cramfs/cramfs-*.tar.gz | tail -n 1)
	rm -rf "$out/cramfs-tools"
	mkdir -p "$out/cramfs-tools"
	tar -xzf "$src" -C "$out/cramfs-tools" --strip-components=1
	make -s -C "$out/cramfs-tools" mkcramfs >/dev/null 2>&1
	MKCRAMFS=$out/cramfs-tools/mkcramfs
fi

root=$out/target
rm -rf "$root"
mkdir -p "$root"
tar -xf "$images/rootfs.tar" -C "$root" 2>/dev/null || true

# Window: CPU address, size (physmap rounds a window down to a power of
# two), MTD name, files. U-Boot's SPL maps flash offset 0x100000 to
# 0x40000000: the windows cover flash 0x870000-0xF70000, after the XIP
# kernel (which ends below 0x870000) and up to the end of the 16 MiB
# flash. The files are ordered by the RAM their code takes when it runs
# from page cache, for its size in flash.
windows='
0x40770000 0x400000 rootfs usr/lib/libcrypto.so.3 usr/bin/ggdeploymentd usr/lib/libevent-2.1.so.7.0.2 lib/libatomic.so.1.2.0
0x40b70000 0x200000 xip2 lib/ld-musl-riscv32-sf.so.1 bin/busybox usr/bin/iotcored usr/bin/ggipcd usr/lib/libz.so.1.3.2 usr/lib/libyaml-0.so.2.0.9 usr/bin/ggconfigd usr/bin/gg-fleet-statusd
0x40d70000 0x100000 xip3 usr/lib/libsqlite3.so.3.50.4 usr/bin/gghealthd usr/bin/ggl-svcd lib/libuuid.so.1.3.0
'
echo "$windows" | while read -r addr size name files; do
	[ -n "$addr" ] || continue
	tree=$out/tree-$name
	rm -rf "$tree"
	for f in $files; do
		mkdir -p "$tree/$(dirname "$f")"
		cp -L --preserve=mode "$root/$f" "$tree/$f"
	done
	# -X twice: page-aligned, as Linux with an MMU maps them.
	"$MKCRAMFS" -X -X -n "$name" "$tree" "$out/$name.cramfs" 2>/dev/null
	bytes=$(stat -c %s "$out/$name.cramfs")
	if [ "$bytes" -gt $((size)) ]; then
		echo "$name.cramfs: $bytes bytes, window $((size))" >&2
		exit 1
	fi
	rm -rf "$tree"
	printf '%s %s %s %s\n' "$addr" "$size" "$name" "$bytes"
done >"$out/windows.txt"
rm -rf "$root"

# The device tree: the BSP's single 4 MiB rootfs window, replaced by these.
dtc -I dtb -O dts -o "$out/base.dts" "$images/esp32s31.dtb" 2>/dev/null
python3 - "$out/base.dts" "$out/windows.txt" "$out/esp32s31-xip.dts" <<'PY'
import sys
base, windows, dst = sys.argv[1:]
s = open(base).read()
start = s.index("\t\tflash@40b00000 {")
end = s.index("};", start) + 2
node = s[start:end]
nodes = []
for line in open(windows):
    addr, size, name, _ = line.split()
    nodes.append(node
        .replace("flash@40b00000", "flash@%08x" % int(addr, 16))
        .replace("reg = <0x40b00000 0x400000>", "reg = <%s %s>" % (addr, size))
        .replace('"rootfs"', '"%s"' % name))
open(dst, "w").write(s[:start] + "\n".join(nodes) + s[end:])
PY
dtc -I dts -O dtb -o "$out/esp32s31-xip.dtb" "$out/esp32s31-xip.dts" 2>/dev/null
rm -f "$out/base.dts"

echo "Flash, after checking the chip (scripts/flash.sh does; esptool read-mac):"
printf '  esptool --chip esp32s31 --port <port> write-flash --flash-mode keep --flash-freq keep --flash-size keep \\\n'
printf '    0x300000 %s' "$out/esp32s31-xip.dtb"
while read -r addr size name bytes; do
	printf ' \\\n    0x%X %s' $((addr - 0x40000000 + 0x100000)) "$out/$name.cramfs"
done <"$out/windows.txt"
printf '\n'
