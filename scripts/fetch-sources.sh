#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Check out the pinned Buildroot and esp-buildroot-external revisions
# (shallow) into $S31_WORK/deps.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
. "$repo/sources.lock"

fetch() {
	dir=$1 url=$2 rev=$3
	if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$rev" ]; then
		echo "$dir: $rev"
		return
	fi
	mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" fetch -q --depth 1 "$url" "$rev"
	git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
	echo "$dir: $(git -C "$dir" rev-parse HEAD)"
}

fetch "$work/deps/buildroot" "$BUILDROOT_URL" "$BUILDROOT_REV"
fetch "$work/deps/esp-buildroot-external" \
	"$ESP_BUILDROOT_EXTERNAL_URL" "$ESP_BUILDROOT_EXTERNAL_REV"
