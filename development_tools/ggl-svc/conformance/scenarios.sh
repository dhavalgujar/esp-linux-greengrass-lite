#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
#
# Runs inside a container whose service manager is systemd (IMPL=systemd)
# or ggl-svcd (IMPL=ggl-svc). Each scenario writes unit files of the kinds
# Greengrass Lite generates (recipe2unit) and the core units use, drives
# them with systemctl, and prints checkpoints:
#
#   <scenario> <checkpoint>: <ActiveState> <Result> <NRestarts> [extra]
#
# run.sh compares the two outputs line by line. Run one scenario with
#   scenarios.sh <name>
set -u

IMPL=${IMPL:?IMPL=systemd|ggl-svc}
UNITS=/tmp/units
mkdir -p "$UNITS"

# ActiveState Result NRestarts of a unit.
state() {
	if [ "$IMPL" = systemd ]; then
		systemctl show -p ActiveState -p Result -p NRestarts "$1" |
			sort | sed 's/^[^=]*=//' | tr '\n' ' ' |
			awk '{ print $1, $3, $2 }'
	else
		systemctl show "$1" 2>/dev/null | awk '{ print $2, $3, $4 }'
	fi
}

# Waits until the unit is neither activating nor deactivating (at most
# $2 seconds, default 30). Restart delays count as activating.
settle() {
	n=$((${2:-30} * 10))
	while [ "$n" -gt 0 ]; do
		case $(state "$1") in
		activating* | deactivating* | "") ;;
		*) return 0 ;;
		esac
		sleep 0.1
		n=$((n - 1))
	done
}

record() {
	printf '%s %s: %s%s\n' "$scenario" "$2" "$(state "$1")" "${3:+ $3}"
}

unit() {
	cat >"$UNITS/$1"
	systemctl link "$UNITS/$1" >/dev/null 2>&1
	[ "$IMPL" = systemd ] && systemctl daemon-reload
	true
}

start() { systemctl start --no-block "$1"; }
stop() { systemctl stop "$1" >/dev/null 2>&1; }
procs() { ps -eo args= | grep -c "^$1\$"; }

# --- Type=exec, the run phase of a component ------------------------------

s_exec_runs() {
	unit t-exec-runs.service <<'EOF'
[Service]
Type=exec
ExecStart=/bin/sleep 1001
EOF
	start t-exec-runs.service
	settle t-exec-runs.service
	record t-exec-runs.service started
	stop t-exec-runs.service
	settle t-exec-runs.service
	record t-exec-runs.service stopped "procs=$(procs 'sleep 1001')"
}

s_exec_exit0() {
	unit t-exec-exit0.service <<'EOF'
[Service]
Type=exec
ExecStart=/bin/true
EOF
	start t-exec-exit0.service
	sleep 1
	settle t-exec-exit0.service
	record t-exec-exit0.service exited
}

s_exec_exit1() {
	unit t-exec-exit1.service <<'EOF'
[Service]
Type=exec
ExecStart=/bin/false
EOF
	start t-exec-exit1.service
	sleep 1
	settle t-exec-exit1.service
	record t-exec-exit1.service exited
	systemctl reset-failed t-exec-exit1.service
	record t-exec-exit1.service reset-failed
}

s_success_status() {
	unit t-success-status.service <<'EOF'
[Service]
Type=exec
ExecStart=/bin/sh -c 'exit 101'
SuccessExitStatus=100 101
EOF
	start t-success-status.service
	sleep 1
	settle t-success-status.service
	record t-success-status.service exited
}

# A crash: the main process dies of a signal nobody asked for.
s_killed_by_signal() {
	unit t-signal.service <<'EOF'
[Service]
Type=exec
ExecStart=/bin/sleep 1013
EOF
	start t-signal.service
	sleep 1
	pkill -KILL -x -f '/bin/sleep 1013'
	sleep 1
	settle t-signal.service
	record t-signal.service killed
}

# What recipe2unit generates for a run phase: restarts on failure, at most
# 3 starts per hour, then failed (Greengrass: BROKEN).
s_start_limit() {
	unit t-start-limit.service <<'EOF'
[Unit]
StartLimitInterval=3600
StartLimitBurst=3
[Service]
Type=exec
ExecStart=/bin/false
Restart=on-failure
RestartSec=1
TimeoutSec=120
EOF
	start t-start-limit.service
	sleep 8
	settle t-start-limit.service
	record t-start-limit.service broken
}

s_restart_recovers() {
	rm -f /tmp/t-recovers.ran
	unit t-recovers.service <<'EOF'
[Unit]
StartLimitInterval=3600
StartLimitBurst=3
[Service]
Type=exec
ExecStart=/bin/sh -c 'if [ -e /tmp/t-recovers.ran ]; then exec sleep 1002; fi; touch /tmp/t-recovers.ran; exit 1'
Restart=on-failure
RestartSec=1
EOF
	start t-recovers.service
	sleep 3
	settle t-recovers.service
	record t-recovers.service recovered
	stop t-recovers.service
}

s_restart_always() {
	unit t-always.service <<'EOF'
[Unit]
StartLimitInterval=3600
StartLimitBurst=3
[Service]
Type=exec
ExecStart=/bin/true
Restart=always
RestartSec=1
EOF
	start t-always.service
	sleep 8
	settle t-always.service
	record t-always.service limited
}

s_manual_restart_resets() {
	rm -f /tmp/t-manual.ran
	unit t-manual.service <<'EOF'
[Service]
Type=exec
ExecStart=/bin/sh -c 'if [ -e /tmp/t-manual.ran ]; then exec sleep 1003; fi; touch /tmp/t-manual.ran; exit 1'
Restart=on-failure
RestartSec=1
EOF
	start t-manual.service
	sleep 3
	settle t-manual.service
	record t-manual.service auto-restarted
	systemctl restart --no-block t-manual.service
	sleep 1
	settle t-manual.service
	record t-manual.service manually-restarted
	stop t-manual.service
}

# --- Type=oneshot: install and bootstrap phases ----------------------------

s_oneshot() {
	unit t-oneshot.service <<'EOF'
[Service]
Type=oneshot
ExecStart=/bin/true
EOF
	start t-oneshot.service
	settle t-oneshot.service
	record t-oneshot.service finished
}

s_oneshot_remain() {
	unit t-oneshot-remain.service <<'EOF'
[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/true
EOF
	start t-oneshot-remain.service
	settle t-oneshot-remain.service
	record t-oneshot-remain.service finished
	stop t-oneshot-remain.service
	settle t-oneshot-remain.service
	record t-oneshot-remain.service stopped
}

s_oneshot_fails() {
	unit t-oneshot-fail.service <<'EOF'
[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/false
EOF
	start t-oneshot-fail.service
	settle t-oneshot-fail.service
	record t-oneshot-fail.service finished
}

s_oneshot_timeout() {
	unit t-oneshot-timeout.service <<'EOF'
[Service]
Type=oneshot
ExecStart=/bin/sleep 1004
TimeoutStartSec=2
EOF
	start t-oneshot-timeout.service
	sleep 4
	settle t-oneshot-timeout.service
	record t-oneshot-timeout.service timed-out "procs=$(procs 'sleep 1004')"
}

# --- Type=notify: the startup phase ----------------------------------------

s_notify_ready() {
	unit t-notify.service <<'EOF'
[Service]
Type=notify
NotifyAccess=all
RemainAfterExit=true
ExecStart=/bin/sh -c 'sleep 1; systemd-notify --ready; sleep 1'
EOF
	start t-notify.service
	sleep 0.5
	record t-notify.service before-ready
	sleep 3
	settle t-notify.service
	record t-notify.service after-exit
}

s_notify_never_ready() {
	unit t-notify-never.service <<'EOF'
[Service]
Type=notify
NotifyAccess=all
ExecStart=/bin/sh -c 'sleep 1'
EOF
	start t-notify-never.service
	sleep 2
	settle t-notify-never.service
	record t-notify-never.service exited
}

s_notify_timeout() {
	unit t-notify-timeout.service <<'EOF'
[Service]
Type=notify
NotifyAccess=all
TimeoutStartSec=2
ExecStart=/bin/sleep 1005
EOF
	start t-notify-timeout.service
	sleep 4
	settle t-notify-timeout.service
	record t-notify-timeout.service timed-out
}

# Notifications are only accepted from Type=notify units.
s_notify_ignored() {
	unit t-notify-exec.service <<'EOF'
[Service]
Type=exec
NotifyAccess=all
ExecStart=/bin/sh -c 'sleep 1; systemd-notify --stopping; exec sleep 1006'
EOF
	start t-notify-exec.service
	sleep 3
	settle t-notify-exec.service
	record t-notify-exec.service after-notify
	stop t-notify-exec.service
}

# --- Stopping ----------------------------------------------------------------

# KillMode=control-group: everything the unit started goes when it stops.
s_stop_kills_group() {
	unit t-group.service <<'EOF'
[Service]
Type=exec
ExecStart=/bin/sh -c '/bin/sleep 1007 & exec /bin/sleep 1008'
EOF
	start t-group.service
	sleep 1
	stop t-group.service
	settle t-group.service
	record t-group.service stopped "procs=$(procs 'sleep 1007')"
}

s_leftovers_killed() {
	unit t-leftover.service <<'EOF'
[Service]
Type=exec
ExecStart=/bin/sh -c '/bin/sleep 1009 & exit 0'
EOF
	start t-leftover.service
	sleep 2
	settle t-leftover.service
	record t-leftover.service exited "procs=$(procs 'sleep 1009')"
}

s_stop_timeout() {
	unit t-stop-timeout.service <<'EOF'
[Service]
Type=exec
ExecStart=/bin/sh -c 'trap "" TERM; while :; do sleep 1; done'
TimeoutStopSec=2
EOF
	start t-stop-timeout.service
	sleep 1
	stop t-stop-timeout.service
	settle t-stop-timeout.service
	record t-stop-timeout.service stopped
}

# --- Dependencies ------------------------------------------------------------

s_binds_to() {
	unit t-bound-a.service <<'EOF'
[Service]
Type=exec
ExecStart=/bin/sleep 1010
EOF
	unit t-bound-b.service <<'EOF'
[Unit]
BindsTo=t-bound-a.service
After=t-bound-a.service
[Service]
Type=exec
ExecStart=/bin/sleep 1011
EOF
	[ "$IMPL" = ggl-svc ] && ggl_names
	start "$B"
	sleep 1
	settle "$B"
	record "$A" b-started
	stop "$A"
	sleep 1
	settle "$B"
	record "$B" a-stopped
	start "$B"
	sleep 1
	settle "$B"
	systemctl restart --no-block "$A"
	sleep 2
	settle "$A"
	settle "$B"
	record "$B" a-restarted
	stop "$B"
	stop "$A"
}

s_wants_after() {
	rm -f /tmp/t-order
	unit t-dep.service <<'EOF'
[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/sh -c 'sleep 1; echo dep >>/tmp/t-order'
EOF
	unit t-main.service <<'EOF'
[Unit]
Wants=t-dep.service
After=t-dep.service
[Service]
Type=exec
ExecStart=/bin/sh -c 'echo main >>/tmp/t-order; exec sleep 1012'
EOF
	[ "$IMPL" = ggl-svc ] && ggl_names
	start "$M"
	sleep 3
	settle "$M"
	record "$D" dep "order=$(tr '\n' , </tmp/t-order)"
	stop "$M"
	stop "$D"
}

# ggl-svcd only follows dependencies between ggl.* units (all Greengrass
# units are): the dependency scenarios use such names there.
ggl_names() { :; }
A=t-bound-a.service B=t-bound-b.service D=t-dep.service M=t-main.service
if [ "$IMPL" = ggl-svc ]; then
	ggl_names() {
		for f in "$UNITS"/t-bound-*.service "$UNITS"/t-dep.service "$UNITS"/t-main.service; do
			[ -e "$f" ] || continue
			sed -e 's/t-bound-a/ggl.t-bound-a/; s/t-bound-b/ggl.t-bound-b/' \
				-e 's/t-dep/ggl.t-dep/; s/t-main/ggl.t-main/' \
				"$f" >"$UNITS/ggl.${f##*/}"
			systemctl link "$UNITS/ggl.${f##*/}" >/dev/null
		done
	}
	A=ggl.t-bound-a.service B=ggl.t-bound-b.service
	D=ggl.t-dep.service M=ggl.t-main.service
fi

# --- Execution environment ---------------------------------------------------

# The process's identity and environment, for a user without a home
# directory (nobody), one with (ggtest, created in both images), and no
# User= at all.
s_environment() {
	mkdir -p /tmp/t-wd
	chmod 0777 /tmp/t-wd
	for user in nobody ggtest none; do
		[ "$user" = none ] && line= || line="User=$user"
		unit "t-env-$user.service" <<EOF
[Service]
Type=oneshot
$line
WorkingDirectory=/tmp/t-wd
Environment="GREETING=hello world"
ExecStart=/bin/sh -c 'echo "\$(id -un):\$(id -gn):\$(id -G | wc -w):\$(pwd):\$GREETING:U=\$USER:L=\$LOGNAME:H=\$HOME:S=\$SHELL" >/tmp/t-wd/$user'
EOF
		start "t-env-$user.service"
		settle "t-env-$user.service"
		record "t-env-$user.service" "ran-as-$user" "$(cat "/tmp/t-wd/$user" 2>/dev/null)"
	done
}

all="exec_runs exec_exit0 exec_exit1 success_status killed_by_signal
start_limit restart_recovers restart_always manual_restart_resets oneshot
oneshot_remain oneshot_fails oneshot_timeout notify_ready notify_never_ready
notify_timeout notify_ignored stop_kills_group leftovers_killed stop_timeout
binds_to wants_after environment"

for scenario in ${*:-$all}; do
	"s_$scenario"
done
