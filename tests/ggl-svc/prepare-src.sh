#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Unpack the pinned Greengrass Lite release and apply this repository's
# patches, so that the tests exercise exactly the ggl-svc the image ships:
#
#   tests/ggl-svc/prepare-src.sh <output-dir>
#
#   BR2_DL_DIR   Buildroot download directory (default: $S31_WORK/dl)
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
out=${1:?usage: $0 <output-dir>}
dl=${BR2_DL_DIR:-$work/dl}
version=$(sed -n 's/^AWS_GREENGRASS_LITE_VERSION = //p' \
	"$repo/package/aws-greengrass-lite/aws-greengrass-lite.mk")
tarball=$dl/aws-greengrass-lite/aws-greengrass-lite-$version.tar.gz

test -f "$tarball" || {
	echo "$tarball missing: run scripts/build.sh (or its source step) first" >&2
	exit 1
}
rm -rf "$out"
mkdir -p "$out"
tar -xzf "$tarball" -C "$out" --strip-components=1
for patch in "$repo"/package/aws-greengrass-lite/*.patch; do
	patch -s -p1 -d "$out" <"$patch"
done
echo "$out: aws-greengrass-lite $version with $(ls "$repo"/package/aws-greengrass-lite/*.patch | wc -l) patches"
