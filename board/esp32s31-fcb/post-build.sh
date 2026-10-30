#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Remove what the image does not use and that would otherwise keep it from
# being reproducible (these embed build paths): the command-line tools of
# libzip and liburiparser (Greengrass links the libraries only) and
# libstdc++'s gdb pretty-printer loader.
set -eu
target=${1:?usage: $0 TARGET_DIR}
rm -f "$target/usr/bin/uriparse" "$target/usr/bin/zipcmp" \
	"$target/usr/bin/zipmerge" "$target/usr/bin/ziptool"
rm -f "$target"/lib/libstdc++.so.*-gdb.py "$target"/usr/lib/libstdc++.so.*-gdb.py
