#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Register com.espressif.esp32s31.Hello as a Greengrass component and deploy
# it to a core device through a thing group:
#
#   scripts/aws-deploy-hello.sh <thing-name>
#
#   GG_THING_GROUP   thing group to deploy to (default: <thing-name>-group);
#                    created, and the thing added to it, if needed
#
# Greengrass delivers deployments that target a single core device through
# the named shadow AWSManagedGreengrassV2Deployment, which nucleus lite does
# not implement; thing-group deployments arrive as IoT Jobs.
# The recipe has no artifacts; the binary ships in the image.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
thing=${1:?usage: $0 <thing-name>}
group=${GG_THING_GROUP:-$thing-group}
region=${AWS_REGION:-$(aws configure get region)}
recipe=$repo/examples/cloud/greengrass-hello/recipe.yaml
name=$(sed -n 's/^ComponentName: "\(.*\)"/\1/p' "$recipe")
version=$(sed -n 's/^ComponentVersion: "\(.*\)"/\1/p' "$recipe")
account=$(aws sts get-caller-identity --query Account --output text)
arn=arn:aws:greengrass:$region:$account:components:$name:versions:$version

if aws greengrassv2 describe-component --region "$region" --arn "$arn" \
	>/dev/null 2>&1; then
	echo "$name $version already registered"
else
	aws greengrassv2 create-component-version --region "$region" \
		--inline-recipe "fileb://$recipe" \
		--query '[arn,status.componentState]' --output text
fi

if ! aws iot describe-thing-group --region "$region" \
	--thing-group-name "$group" >/dev/null 2>&1; then
	aws iot create-thing-group --region "$region" \
		--thing-group-name "$group" >/dev/null
fi
aws iot add-thing-to-thing-group --region "$region" \
	--thing-group-name "$group" --thing-name "$thing"

aws greengrassv2 create-deployment --region "$region" \
	--target-arn "arn:aws:iot:$region:$account:thinggroup/$group" \
	--deployment-name "$name on $group" \
	--components "{\"$name\":{\"componentVersion\":\"$version\"}}" \
	--query deploymentId --output text
