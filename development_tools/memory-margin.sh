#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# How much memory a running board can really spare:
#
#   development_tools/memory-margin.sh <board-ip> [<max-MiB> [<first-MiB>]]
#                                      (default: from 0 to 6 MiB)
#
#   S31_WORK      work area holding secrets/ssh (default: repo/..)
#
# MemAvailable counts page cache that holds program code, which the board
# needs again. This takes memory away with an unswappable tmpfs balloon,
# 1 MiB more at each step, and at each step deploys and removes a small
# local component (ggl-cli), counting file pages read again after eviction
# (workingset_refault_file). It stops once a deployment fails or takes
# more than 300 s; the board recovers when the balloon is removed. Run it
# on a freshly booted board: a deployment leaves ggdeploymentd with more
# heap. It takes 10 to 60 minutes, and the step that fails makes the
# board unresponsive for a while.
set -eu

ip=${1:?usage: $0 <board-ip> [<max-MiB> [<first-MiB>]]}
max=${2:-6}
first=${3:-0}
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}

ssh -i "$work/secrets/ssh/id_ed25519" \
	-o UserKnownHostsFile="$work/secrets/ssh/known_hosts" \
	-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
	-o ServerAliveInterval=15 -o ServerAliveCountMax=80 \
	-o BatchMode=yes "root@$ip" "MAX=$max FIRST=$first sh -s" <<'EOF'
R=/tmp/margin-recipe
B=/tmp/margin-balloon
mkdir -p $R $B
cat >$R/com.example.Balloon-1.0.0.yaml <<'Y'
---
RecipeFormatVersion: "2020-01-25"
ComponentName: "com.example.Balloon"
ComponentVersion: "1.0.0"
ComponentPublisher: "test"
ComponentConfiguration:
  DefaultConfiguration:
    a: "1"
    b: "2"
    c: "3"
Manifests:
  - Platform:
      os: linux
      runtime: "*"
    Lifecycle:
      run:
        Script: "exec sleep 3600"
Y
chmod -R a+rX $R
# The system log so far, rotated or not, and from a marker on.
if [ -d /run/systemd/system ]; then
	log() { journalctl -q --no-pager -o short; }
else
	log() { cat /var/log/messages.0 /var/log/messages 2>/dev/null; }
fi
since() { log | sed -n "/$1/,\$p"; }
# Not every busybox has timeout.
limit=
command -v timeout >/dev/null && limit="timeout 60"
mem() { awk -v k="$1:" '$1 == k { print $2 }' /proc/meminfo; }
refaults() { awk '/^workingset_refault_file/ { print $2 }' /proc/vmstat; }
up() { cut -d' ' -f1 /proc/uptime; }
# Runs a local deployment; prints its result and how long it took (s).
deploy() {
	m="memory-margin-$$-$(date +%s)"
	logger -t memory-margin "$m"
	t0=$(up)
	$limit /usr/bin/ggl-cli deploy "$@" >/dev/null 2>&1 ||
		{ echo "cli-failed 0"; return; }
	i=0
	while [ $i -lt 100 ] && ! since "$m" | grep -q "reporting job as"; do
		sleep 3
		i=$((i + 1))
	done
	r=$(since "$m" | grep "reporting job as" | tail -n 1 | sed 's/.*reporting job as //; s/\.$//')
	[ $i -ge 100 ] && r=TIMEOUT
	echo "$r $(echo "$(up) $t0" | awk '{ printf "%.0f", $1 - $2 }')"
}
mount -t tmpfs -o size=$((MAX + 1))m tmpfs $B
echo "MemAvailable $(mem MemAvailable) kB, Mapped $(mem Mapped) kB, AnonPages $(mem AnonPages) kB"
echo "balloon  MemAvailable  lowest  refaults  deploy        remove"
mb=$FIRST
while [ $mb -le "$MAX" ]; do
	rm -f $B/b
	[ $mb -gt 0 ] && dd if=/dev/zero of=$B/b bs=1k count=$((mb * 1024)) 2>/dev/null
	sleep 5
	before=$(mem MemAvailable)
	r0=$(refaults)
	rm -f /tmp/margin-stop
	(
		m=999999
		while [ ! -f /tmp/margin-stop ]; do
			a=$(mem MemAvailable)
			[ "$a" -lt $m ] && m=$a
			echo $m >/tmp/margin-min
			sleep 1
		done
	) &
	sampler=$!
	add=$(deploy -r $R -c com.example.Balloon=1.0.0)
	sleep 10
	remove=$(deploy -d com.example.Balloon)
	touch /tmp/margin-stop
	wait $sampler
	printf '%3d MiB  %8s kB  %6s kB  %8s  %-12s  %s\n' $mb "$before" \
		"$(cat /tmp/margin-min)" $(($(refaults) - r0)) \
		"${add% *} ${add#* }s" "${remove% *} ${remove#* }s"
	set -- $add $remove
	if [ "$1" != SUCCEEDED ] || [ "$3" != SUCCEEDED ] ||
		[ "$2" -gt 300 ] || [ "$4" -gt 300 ]; then
		break
	fi
	mb=$((mb + 1))
done
rm -f $B/b /tmp/margin-stop /tmp/margin-min
umount $B
# A failed step can leave the component deployed: remove it with the
# memory back.
if ls /var/lib/greengrass/packages/recipes | grep -q "^com.example.Balloon-"; then
	echo "removing the test component: $(deploy -d com.example.Balloon)"
fi
rm -rf $R $B
EOF
