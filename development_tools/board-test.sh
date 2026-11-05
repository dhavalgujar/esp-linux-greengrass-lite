#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# End-to-end checks of a running board:
#
#   development_tools/board-test.sh <board-ip> <fleet-name> [--cloud] [--fresh]
#       [--reset <serial-port> <chip-mac>]
#
# The board belongs to the fleet (scripts/aws-provision.sh), in thing group
# <fleet>: as the Thing of its connection kit, or provisioned at boot as
# <fleet>-<serial>.
#
#   --cloud   also deploy the demo from AWS (scripts/aws-deploy-hello.sh)
#             and check the core device and component in the Greengrass API;
#             and deploy a test component with a bootstrap step, which
#             makes the device reboot mid-deployment (registered in the
#             account for the check and deleted afterwards)
#   --reset   finally reset the board through its serial port (after
#             checking the chip MAC) and check what comes back (needs
#             --cloud): with persistent storage the same device, with the
#             cloud-deployed demo
#   --fresh   the board keeps its state in RAM (nfs-deploy.sh --fresh): skip
#             the bootstrap check (a deployment cannot outlive the reboot it
#             needs), and expect nothing deployed after the reset: the same
#             identity with a connection kit in the image, a new certificate
#             with fleet provisioning
#
#   S31_WORK      work area holding secrets/ssh (default: repo/..)
#   ESP_ESPTOOL   esptool for --reset (default: from PATH)
#
# Exit status is the number of failed checks.
set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
usage="usage: $0 <board-ip> <fleet-name> [--cloud] [--fresh] [--reset <port> <mac>]"
ip=${1:?$usage}
fleet=${2:?$usage}
shift 2
group=${GG_THING_GROUP:-$fleet}
cloud=0
fresh=0
reset_port=
reset_mac=
while [ $# -gt 0 ]; do
	case $1 in
	--cloud) cloud=1; shift ;;
	--fresh) fresh=1; shift ;;
	--reset) reset_port=${2:?--reset <port> <mac>}; reset_mac=${3:?--reset <port> <mac>}; shift 3 ;;
	*) echo "unknown option $1" >&2; exit 2 ;;
	esac
done
if [ -n "$reset_port" ] && [ "$cloud" != 1 ]; then
	# The reset check expects the cloud-deployed demo to come back.
	echo "--reset needs --cloud" >&2
	exit 2
fi

key=$work/secrets/ssh/id_ed25519
hello=com.espressif.esp32s31.Hello
bootstrap=com.espressif.esp32s31.BootstrapTest
failures=0

# Every command on the board gets these, so that the checks hold under
# ggl-svc (this repository's image) and under systemd (upstream's service
# model, development_tools/systemd-evaluation):
#   log            the system log so far (both files of a rotated log)
#   since MARK     the log from the line holding MARK (logger(1) wrote it)
#   unit_show U..  "<unit> <ActiveState> <Result> <NRestarts>
#                  <InactiveEnterTimestampMonotonic>" per unit
#   core_status    unit_show for the core units
#   linked_units   the units deployments linked
prelude='if [ -d /run/systemd/system ]; then
	log() { journalctl -q --no-pager -o short; }
	unit_show() {
		for u; do
			printf "%s %s %s %s %s\n" "$u" \
				"$(systemctl show -P ActiveState "$u")" \
				"$(systemctl show -P Result "$u")" \
				"$(systemctl show -P NRestarts "$u")" \
				"$(systemctl show -P InactiveEnterTimestampMonotonic "$u")"
		done
	}
	core_status() {
		unit_show $(systemctl list-units --all --plain --no-legend \
			"ggl.core.*.service" "ggl.aws.*.service" | cut -d" " -f1)
	}
	linked_units() { ls /etc/systemd/system | grep "^ggl\."; }
else
	log() { cat /var/log/messages.0 /var/log/messages 2>/dev/null; }
	unit_show() { for u; do systemctl show "$u"; done; }
	core_status() { /etc/init.d/S95greengrass status; }
	linked_units() { ls /var/lib/ggl-svc/links; }
fi
since() { log | sed -n "/$1/,\$p"; }
mark() { m="board-test-$$-$(date +%s)"; logger -t board-test "$m"; echo "$m"; }
'

# A board that goes away mid-command fails the command within ~30 s instead
# of leaving the session waiting for TCP to time out.
board() {
	ssh -i "$key" -o UserKnownHostsFile="$work/secrets/ssh/known_hosts" \
		-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
		-o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
		-o BatchMode=yes "root@$ip" "$prelude" "$@"
}
check() {
	name=$1
	shift
	if "$@"; then
		echo "PASS  $name"
	else
		echo "FAIL  $name"
		failures=$((failures + 1))
		# /var/log is a tmpfs: show the evidence before a reset loses it.
		board 'log | grep -E "ggdeploymentd|ggl-svcd: ggl\.|recipe-runner|E\[" |
			grep -v core_mqtt | tail -n 15' 2>/dev/null | sed 's/^/      /'
	fi
}

# Runs a local deployment on the board and prints the job's final status.
local_deploy() {
	board '
		m=$(mark)
		/usr/bin/ggl-cli deploy '"$*"' >/dev/null 2>&1 || exit 1
		for i in $(seq 1 100); do
			since "$m" | grep -q "reporting job as" && break
			sleep 3
		done
		since "$m" | grep "reporting job as" | tail -n 1 | sed "s/.*reporting job as //; s/\.$//"'
}

core_units_healthy() {
	out=$(board 'core_status | grep "^ggl\.\(core\|aws\)"')
	[ "$(printf '%s\n' "$out" | grep -c ' active success 0 ')" -eq 9 ]
}

hello_unit_active() {
	board "unit_show ggl.$hello.service 2>/dev/null" | grep -q ' active '
}

hello_passes_after_local_deploy() {
	# If another deployment already runs the demo, this one changes nothing
	# and the demo just has to keep running.
	was_active=0
	hello_unit_active && was_active=1
	m=$(board mark)
	[ "$(local_deploy -r /usr/share/esp32s31-ggl-hello -c $hello=1.0.0)" = SUCCEEDED ] || return 1
	if [ "$was_active" = 1 ]; then
		hello_unit_active
		return
	fi
	board 'for i in $(seq 1 60); do
			since '"$m"' | grep -q "hello: PASS" && exit 0
			sleep 2
		done; exit 1'
}

impersonation_refused() {
	# recipe-runner outside any unit, claiming the demo component.
	out=$(board 'cd /tmp && su -s /bin/sh gg_component -c \
		"AWS_GG_NUCLEUS_DOMAIN_SOCKET_FILEPATH_FOR_COMPONENT=/var/lib/greengrass/gg-ipc.socket \
		GGL_COMPONENT_NAME='"$hello"' \
		/usr/bin/recipe-runner -n '"$hello"' -v 1.0.0 -p run" 2>&1 & pid=$!;
		sleep 10; kill $pid 2>/dev/null; wait $pid 2>/dev/null; true')
	printf '%s\n' "$out" | grep -q "failed to authenticate"
}

failing_component_is_broken_then_removed() {
	board 'umask 022 && mkdir -p /tmp/failtest && cat >/tmp/failtest/com.espressif.esp32s31.FailTest-1.0.0.yaml <<"EOF"
---
RecipeFormatVersion: "2020-01-25"
ComponentName: "com.espressif.esp32s31.FailTest"
ComponentVersion: "1.0.0"
ComponentPublisher: "Espressif"
Manifests:
  - Platform:
      os: linux
      runtime: "*"
    Lifecycle:
      run:
        Script: "exit 1"
EOF'
	local_deploy -r /tmp/failtest -c com.espressif.esp32s31.FailTest=1.0.0 >/dev/null
	# Failed after 3 restarts, which gghealthd reports as BROKEN. As under
	# systemd, the start limit keeps the failure's Result (exit-code).
	state=$(board 'for i in $(seq 1 30); do
			s=$(unit_show ggl.com.espressif.esp32s31.FailTest.service)
			case $s in *" failed exit-code 3 "*) break ;; esac
			sleep 2
		done; echo "$s"')
	case $state in *" failed exit-code 3 "*) ;; *) return 1 ;; esac
	[ "$(local_deploy -d com.espressif.esp32s31.FailTest)" = SUCCEEDED ] || return 1
	board '! linked_units | grep -q FailTest'
}

# A component with install and startup phases: exercises
# "systemctl start --no-block" and systemd-notify (startup scripts end with
# --ready and --stopping).
phased_component_deploys() {
	board 'umask 022 && mkdir -p /tmp/phasetest && cat >/tmp/phasetest/com.espressif.esp32s31.PhaseTest-1.0.0.yaml <<"EOF"
---
RecipeFormatVersion: "2020-01-25"
ComponentName: "com.espressif.esp32s31.PhaseTest"
ComponentVersion: "1.0.0"
ComponentPublisher: "Espressif"
Manifests:
  - Platform:
      os: linux
      runtime: "*"
    Lifecycle:
      install:
        Script: "echo phasetest installed"
      startup:
        Script: "echo phasetest started"
EOF'
	[ "$(local_deploy -r /tmp/phasetest -c com.espressif.esp32s31.PhaseTest=1.0.0)" = SUCCEEDED ] || return 1
	states=$(board 'unit_show ggl.com.espressif.esp32s31.PhaseTest.install.service \
		ggl.com.espressif.esp32s31.PhaseTest.service')
	# The generated install unit has RemainAfterExit=true (active once it
	# succeeded); the startup unit must have run and then finished.
	printf '%s\n' "$states" |
		grep -Eq "PhaseTest\.install\.service (active|inactive) success " &&
		printf '%s\n' "$states" |
		grep -Eq "PhaseTest\.service inactive success [0-9]+ [1-9]" || return 1
	[ "$(local_deploy -d com.espressif.esp32s31.PhaseTest)" = SUCCEEDED ]
}

local_root_removed() {
	[ "$(local_deploy -d $hello)" = SUCCEEDED ] || return 1
	# With --cloud the group no longer lists the demo either (see
	# cloud_removal_succeeds), so it must be gone entirely.
	[ "$cloud" = 1 ] || return 0
	board '! linked_units | grep -q Hello' &&
		! hello_unit_active
}

wait_cloud_deployment() {
	dep=$1
	for i in $(seq 1 90); do
		st=$(aws greengrassv2 list-effective-deployments \
			--core-device-thing-name "$thing" \
			--query "effectiveDeployments[?deploymentId=='$dep'].coreDeviceExecutionStatus | [0]" \
			--output text)
		case $st in SUCCEEDED) return 0 ;; FAILED|TIMED_OUT|REJECTED) return 1 ;; esac
		sleep 5
	done
	return 1
}

aws_region() {
	printf '%s\n' "${AWS_REGION:-$(aws configure get region)}"
}
aws_account() {
	aws sts get-caller-identity --query Account --output text
}

# Deploys the components (JSON) to the thing group; prints the deployment.
group_deploy() {
	aws greengrassv2 create-deployment --region "$(aws_region)" \
		--target-arn "arn:aws:iot:$(aws_region):$(aws_account):thinggroup/$group" \
		--deployment-name "board-test: $1" --components "$2" \
		--query deploymentId --output text
}

bootstrap_arn() {
	echo "arn:aws:greengrass:$(aws_region):$(aws_account):components:$bootstrap:versions:1.0.0"
}

# Start the local checks from a clean state: remove the demo from the
# thing group (this also exercises a cloud removal).
cloud_removal_succeeds() {
	dep=$(group_deploy "remove the demo" '{}') || return 1
	# A local deployment may still list the demo; local_root_removed checks
	# that it is gone once neither does.
	wait_cloud_deployment "$dep"
}

# A cloud deployment of a component with a bootstrap step: nucleus lite
# reboots the device to complete it, then resumes the deployment after the
# boot and reports it. Exercises the SBI system reset and the resumption of
# the IoT job.
cloud_bootstrap_reboot_succeeds() {
	if ! aws greengrassv2 describe-component --arn "$(bootstrap_arn)" \
		>/dev/null 2>&1; then
		recipe=$(mktemp)
		cat >"$recipe" <<EOF
---
RecipeFormatVersion: "2020-01-25"
ComponentName: "$bootstrap"
ComponentVersion: "1.0.0"
ComponentDescription: "board-test: a bootstrap step, which reboots the device."
ComponentPublisher: "Espressif"
Manifests:
  - Platform:
      os: linux
      architecture: riscv32
      runtime: "*"
    Lifecycle:
      bootstrap:
        Script: "echo bootstraptest bootstrap"
      run:
        Script: "echo bootstraptest running; exec sleep 1000000"
EOF
		aws greengrassv2 create-component-version \
			--inline-recipe "fileb://$recipe" >/dev/null
		ret=$?
		rm -f "$recipe"
		[ "$ret" = 0 ] || return 1
		for i in $(seq 1 30); do
			aws greengrassv2 describe-component --arn "$(bootstrap_arn)" \
				--query status.componentState --output text |
				grep -qx DEPLOYABLE && break
			sleep 2
		done
	fi
	boot0=$(board 'cat /proc/sys/kernel/random/boot_id')
	wait_cloud_deployment "$(group_deploy "bootstrap and reboot" \
		"{\"$bootstrap\":{\"componentVersion\":\"1.0.0\"}}")" || return 1
	[ "$(board 'cat /proc/sys/kernel/random/boot_id')" != "$boot0" ] &&
		board "unit_show ggl.$bootstrap.service" | grep -q ' active '
}

# The demo deployment replaced the test component's: nothing of it may run
# any more, and its run unit is gone. (Its finished bootstrap unit stays
# loaded until the next daemon-reload or boot: upstream's removal disables
# only the run unit and reloads before deleting the unit files.) Then remove
# it from the account.
bootstrap_component_deleted() {
	units=$(board 'for u in $(linked_units | grep BootstrapTest); do
			unit_show "$u"
		done; true') || return 1
	! printf '%s\n' "$units" | grep -Eq "BootstrapTest\.service | (active|activating) " &&
		aws greengrassv2 delete-component --arn "$(bootstrap_arn)"
}

cloud_deployment_succeeds() {
	wait_cloud_deployment "$("$repo/scripts/aws-deploy-hello.sh" "$group" | tail -n 1)"
}

cloud_reports_healthy_and_running() {
	sleep 30
	[ "$(aws greengrassv2 get-core-device --core-device-thing-name "$thing" \
		--query status --output text)" = HEALTHY ] &&
		aws greengrassv2 list-installed-components \
			--core-device-thing-name "$thing" \
			--query "installedComponents[?componentName=='$hello'].lifecycleState | [0]" \
			--output text | grep -qx RUNNING
}

# The device's certificate (from a connection kit, or fleet provisioning),
# or nothing before it has one.
device_certificate() {
	board 'cat /var/lib/greengrass/credentials/device.pem.crt \
		/var/lib/greengrass/credentials/certificate.pem' 2>/dev/null |
		sha256sum | cut -c1-16
}

# Waits until the device has its identity and its core units run.
provisioned_and_running() {
	board 'for i in $(seq 1 120); do
			{ [ -s /var/lib/greengrass/credentials/device.pem.crt ] ||
				[ -s /var/lib/greengrass/credentials/certificate.pem ]; } &&
				[ "$(core_status | grep -c " active ")" -ge 9 ] &&
				exit 0
			sleep 5
		done; exit 1' || return 1
	sleep 20
	core_units_healthy
}

# Fleet provisioning registered the Thing, in the fleet's group, with the
# certificate the device holds.
device_registered() {
	[ -n "$thing" ] &&
		aws iot list-thing-groups-for-thing --thing-name "$thing" \
			--query 'thingGroups[].groupName' --output text | grep -qw "$group" &&
		[ "$(aws iot list-thing-principals --thing-name "$thing" \
			--query 'length(principals)' --output text)" -ge 1 ]
}

# Resets the board through its serial port and waits for SSH.
cold_reset() {
	esptool=${ESP_ESPTOOL:-esptool}
	mac=$("$esptool" --port "$reset_port" read-mac 2>&1 |
		sed -n 's/^MAC: *//p' | head -n 1 | tr '[:upper:]' '[:lower:]')
	[ "$mac" = "$(printf '%s' "$reset_mac" | tr '[:upper:]' '[:lower:]')" ] || return 1
	for i in $(seq 1 90); do
		board true 2>/dev/null && break
		sleep 2
	done
}

# Persistent storage: the same device comes back, with what was deployed.
comes_back_after_reset() {
	cert0=$(device_certificate)
	cold_reset || return 1
	board 'for i in $(seq 1 150); do log | grep -q "hello: PASS" && exit 0; sleep 1; done; exit 1' &&
		core_units_healthy && [ "$(device_certificate)" = "$cert0" ]
}

# No storage: nothing deployed comes back; the identity does if the image
# carries it (connection kit), a new one is provisioned otherwise.
fresh_after_reset() {
	cert0=$(device_certificate)
	cold_reset || return 1
	provisioned_and_running || return 1
	if [ "$image_kit" = 1 ]; then
		[ "$(device_certificate)" = "$cert0" ] || return 1
	else
		[ "$(device_certificate)" != "$cert0" ] || return 1
	fi
	! board 'linked_units' | grep -q Hello
}

# Recipes handed to ggl-cli -r are copied with their mode; recipe-runner
# runs as gg_component and must be able to read them (hence umask 022
# above). Remove test components a previous, interrupted run left behind.
for leftover in com.espressif.esp32s31.FailTest com.espressif.esp32s31.PhaseTest; do
	if board "ls /var/lib/greengrass/packages/recipes" 2>/dev/null |
		grep -q "^$leftover-"; then
		local_deploy -d "$leftover" >/dev/null
	fi
done

check "device has its identity, core units active" provisioned_and_running
image_kit=$(board 'test -d /etc/greengrass/connection-kit && echo 1 || echo 0')
# The Thing: the connection kit's, or <fleet>-<serial> from provisioning.
thing=$(board 'sed -n "s/^ *thingName: *\"\(.*\)\"/\1/p" \
	/var/lib/greengrass/config.d/connection-kit.yaml 2>/dev/null')
if [ -z "$thing" ]; then
	serial=$(board 'tr -d ":\n" </sys/class/net/eth0/address')
	thing=${serial:+$fleet-$serial}
fi
if [ "$cloud" = 1 ]; then
	check "Thing $thing registered in group $group" device_registered
	check "cloud removal of the demo SUCCEEDED" cloud_removal_succeeds
fi
check "local deployment of the demo, AWS IoT Core round trip" hello_passes_after_local_deploy
check "IPC caller outside any unit refused" impersonation_refused
check "failing component ends BROKEN, removal cleans up" failing_component_is_broken_then_removed
check "install and startup phases (systemd-notify) deploy" phased_component_deploys
check "local deployment root removed" local_root_removed
if [ "$cloud" = 1 ]; then
	if [ "$fresh" = 0 ]; then
		check "cloud deployment with a bootstrap step: reboot, resume, SUCCEEDED" cloud_bootstrap_reboot_succeeds
	fi
	check "cloud deployment of the demo SUCCEEDED" cloud_deployment_succeeds
	if [ "$fresh" = 0 ]; then
		check "test component removed from the device and the account" bootstrap_component_deleted
	fi
	check "core device HEALTHY, demo RUNNING (Greengrass API)" cloud_reports_healthy_and_running
fi
if [ -n "$reset_port" ] && [ "$fresh" = 0 ]; then
	check "after a cold reset: same device, core units and deployed demo back" comes_back_after_reset
elif [ -n "$reset_port" ] && [ "$image_kit" = 1 ]; then
	check "after a cold reset: same identity (from the image), nothing deployed" fresh_after_reset
elif [ -n "$reset_port" ]; then
	check "after a cold reset: provisioned anew, new certificate, nothing deployed" fresh_after_reset
fi
check "core units active, no restarts (end)" core_units_healthy
echo "$failures check(s) failed"
exit "$failures"
