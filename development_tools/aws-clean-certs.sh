#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Remove the certificates a device no longer uses:
#
#   development_tools/aws-clean-certs.sh <thing-name> [--dry-run]
#
#   AWS_REGION   default: the CLI's configured region
#
# A device without persistent storage provisions itself again at every boot
# (see "Device identity and state" in the README): each boot attaches a new
# certificate to its Thing and leaves the previous one registered, active
# and unusable (its private key is gone). This keeps the newest certificate
# attached to the Thing and, for every other one, detaches it from the
# Thing and its policies, deactivates it and deletes it.
#
# Only for Things whose device provisions itself at every boot: a device
# with persistent storage keeps using the certificate it was first given,
# and loses access if a newer one exists and this removes its own.
set -eu

thing=${1:?usage: $0 <thing-name> [--dry-run]}
dry=${2:-}
region=${AWS_REGION:-$(aws configure get region)}

arns=$(aws iot list-thing-principals --region "$region" --thing-name "$thing" \
	--query 'principals[]' --output text | tr '\t' '\n' | grep ':cert/' || true)
if [ -z "$arns" ]; then
	echo "$thing has no certificates"
	exit 0
fi

# Newest first, by creation date.
sorted=$(for arn in $arns; do
	id=${arn##*/}
	created=$(aws iot describe-certificate --region "$region" \
		--certificate-id "$id" \
		--query certificateDescription.creationDate --output text)
	printf '%s %s\n' "$created" "$arn"
done | sort -r | cut -d' ' -f2)

keep=$(printf '%s\n' "$sorted" | head -n 1)
echo "keep   $keep"
for arn in $(printf '%s\n' "$sorted" | tail -n +2); do
	id=${arn##*/}
	echo "remove $arn"
	[ "$dry" = --dry-run ] && continue
	aws iot detach-thing-principal --region "$region" --thing-name "$thing" \
		--principal "$arn"
	for policy in $(aws iot list-attached-policies --region "$region" \
		--target "$arn" --query 'policies[].policyName' --output text); do
		aws iot detach-policy --region "$region" --policy-name "$policy" \
			--target "$arn"
	done
	aws iot update-certificate --region "$region" --certificate-id "$id" \
		--new-status INACTIVE
	# Detaching is eventually consistent: retry the delete for a while.
	tries=10
	until aws iot delete-certificate --region "$region" \
		--certificate-id "$id" 2>/dev/null; do
		tries=$((tries - 1))
		[ "$tries" -gt 0 ] || { echo "cannot delete $id" >&2; exit 1; }
		sleep 3
	done
done
