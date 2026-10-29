#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Conformance of ggl-svc against systemd: runs the same unit scenarios
# (scenarios.sh) under systemd and under ggl-svcd, each as PID 1 of a
# container with the same userland, and compares what both report.
#
#   tests/ggl-svc/conformance/run.sh [scenario ...]
#
#   GGL_SRC   test this aws-greengrass-lite tree instead of the pinned
#             release with this repository's patches
#
# Needs Docker (privileged containers with their own cgroup namespace) and
# the Buildroot download directory (see ../prepare-src.sh). Prints both
# results side by side where they differ; differences listed in
# deviations.txt are deliberate and reported, not failed. Exit status: the
# number of other differences.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ctx=$(mktemp -d)
trap 'rm -rf "$ctx"; for i in systemd ggl-svc; do docker rm -f "ggl-svc-conformance-$i" >/dev/null 2>&1 || true; done' EXIT

# GGL_SRC: an aws-greengrass-lite tree to test instead (e.g. the fork).
if [ -n "${GGL_SRC:-}" ]; then
	cp -r "$GGL_SRC/modules/ggl-svc" "$ctx/ggl-svc"
else
	"$here/../prepare-src.sh" "$ctx/ggl" >/dev/null
	cp -r "$ctx/ggl/modules/ggl-svc" "$ctx/ggl-svc"
fi
for impl in systemd ggl-svc; do
	docker build -q -t "ggl-svc-conformance-$impl" \
		-f "$here/Containerfile.$impl" "$ctx" >/dev/null
done

for impl in systemd ggl-svc; do
	name=ggl-svc-conformance-$impl
	docker rm -f "$name" >/dev/null 2>&1 || true
	docker run -d --name "$name" --privileged --cgroupns=private \
		--tmpfs /run --tmpfs /tmp "$name" >/dev/null
	# Ready: the manager answers on its control socket.
	if [ "$impl" = systemd ]; then
		ready='systemctl is-system-running | grep -qE "running|degraded"'
	else
		ready='test -S /run/ggl-svc.sock'
	fi
	tries=150
	until docker exec "$name" sh -c "$ready" 2>/dev/null; do
		tries=$((tries - 1))
		[ "$tries" -gt 0 ] || { echo "$impl did not come up" >&2; exit 1; }
		sleep 0.2
	done
	docker cp "$here/scenarios.sh" "$name:/scenarios.sh" >/dev/null
	docker exec -e IMPL="$impl" "$name" sh /scenarios.sh "$@" \
		>"$ctx/$impl.txt" 2>"$ctx/$impl.err" || true
done

differences=0
deliberate=0
while IFS= read -r ref; do
	key=${ref%%:*}
	got=$(grep -F "$key:" "$ctx/ggl-svc.txt" || echo "$key: (missing)")
	if [ "$ref" = "$got" ]; then
		printf 'same     %s\n' "$ref"
	elif grep -qxF "$key" "$here/deviations.txt" 2>/dev/null; then
		printf 'DELIBERATE %s\n           systemd:%s\n           ggl-svc:%s\n' \
			"$key" "${ref#*:}" "${got#*:}"
		deliberate=$((deliberate + 1))
	else
		printf 'DIFFERENT  %s\n           systemd:%s\n           ggl-svc:%s\n' \
			"$key" "${ref#*:}" "${got#*:}"
		differences=$((differences + 1))
	fi
done <"$ctx/systemd.txt"
[ -s "$ctx/systemd.err" ] && { echo "--- systemd stderr"; cat "$ctx/systemd.err"; }
[ -s "$ctx/ggl-svc.err" ] && { echo "--- ggl-svc stderr"; cat "$ctx/ggl-svc.err"; }
echo "$(wc -l <"$ctx/systemd.txt") checkpoints: $differences different, $deliberate deliberate"
exit "$differences"
