#!/bin/sh
# Flash the boot stack and kernel to an ESP32-S31:
#
#   scripts/flash.sh <serial-port> <expected-chip-mac>
#
# Refuses to write unless the chip on <serial-port> reports
# <expected-chip-mac>: USB serial adapters are easily mixed up on a bench,
# and their names do not identify the chip behind them.
#
#   ESP_ESPTOOL   ESP32-S31-capable esptool (default: from PATH)
#   S31_WORK      work area (default: repo/..)
#   S31_DEFCONFIG defconfig the image was built from (as in build.sh)
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
port=${1:?usage: $0 <serial-port> <expected-chip-mac>}
expected=$(printf '%s' "${2:?usage: $0 <serial-port> <expected-chip-mac>}" |
	tr '[:upper:]' '[:lower:]')
esptool=${ESP_ESPTOOL:-esptool}
name=$(basename "${S31_DEFCONFIG:-esp32s31_fcb_greengrass_defconfig}" _defconfig)
image=$work/out/$name/images/s31_full_flash.bin

test -f "$image"
actual=$("$esptool" --port "$port" read-mac 2>&1 |
	sed -n 's/^MAC: *//p' | head -n 1 | tr '[:upper:]' '[:lower:]')
if [ "$actual" != "$expected" ]; then
	echo "chip on $port reports MAC '$actual', expected '$expected'; refusing" >&2
	exit 1
fi
echo "$(sha256sum "$image")"
exec "$esptool" --chip esp32s31 --port "$port" --baud 921600 \
	write-flash 0x0 "$image"
