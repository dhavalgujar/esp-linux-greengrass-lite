#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Fuzz ggl-svcd's untrusted inputs with libFuzzer, AddressSanitizer and
# UndefinedBehaviorSanitizer:
#   fuzz_unit_file  the unit file parser (unit files come from deployments)
#   fuzz_requests   the control protocol (any local user can connect)
#
#   tests/ggl-svc/fuzz/run.sh [seconds-per-target]   (default 300)
#
#   GGL_SRC   fuzz this aws-greengrass-lite tree instead of the pinned
#             release with this repository's patches
#   CC        a clang with libFuzzer (default: clang)
#
# Findings (crashing inputs) land in $FUZZ_OUT (default: a new temporary
# directory, printed). Exit status: the number of targets that found one.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
seconds=${1:-300}
cc=${CC:-clang}
out=${FUZZ_OUT:-$(mktemp -d)}
mkdir -p "$out"

if [ -n "${GGL_SRC:-}" ]; then
	src=$GGL_SRC
else
	src=$out/src
	"$here/../prepare-src.sh" "$src" >/dev/null
fi
svc=$src/modules/ggl-svc

# In RAM: every request input links units, which writes and syncs files.
dir=/dev/shm/ggl-svc-fuzz
rm -rf "$dir"
flags="-g -O1 -std=gnu11 -D_GNU_SOURCE
	-fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined
	-DFUZZ_DIR=\"$dir\" -DSTATE_DIR=\"$dir/state\"
	-DGGL_SVC_CORE_DIR=\"$dir/core\" -DCGROUP_ROOT=\"$dir/cgroup\"
	-I$svc/include -I$svc/bin"
failures=0
for target in fuzz_unit_file fuzz_requests; do
	# shellcheck disable=SC2086
	"$cc" $flags -o "$out/$target" "$here/$target.c"
	seeds=$here/seeds/unit
	dict=
	if [ "$target" = fuzz_requests ]; then
		seeds=$here/seeds/requests
		dict=-dict=$here/requests.dict
	fi
	mkdir -p "$out/$target-corpus" "$out/$target-findings"
	echo "== $target, $seconds s"
	if ! "$out/$target" -max_total_time="$seconds" -max_len=4096 \
		-timeout=10 -print_final_stats=1 $dict \
		-artifact_prefix="$out/$target-findings/" \
		"$out/$target-corpus" "$seeds" >"$out/$target.log" 2>&1; then
		failures=$((failures + 1))
		tail -n 40 "$out/$target.log"
	fi
	grep -E "^stat::(number_of_executed_units|peak_rss_mb)|^#[0-9]+.*DONE" \
		"$out/$target.log" | tail -n 3
	echo "corpus: $(ls "$out/$target-corpus" | wc -l) inputs, findings: $(ls "$out/$target-findings" | wc -l)"
done
echo "results: $out"
exit "$failures"
