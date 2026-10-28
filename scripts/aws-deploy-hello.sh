#!/bin/sh
# Register com.espressif.esp32s31.Hello as a Greengrass component and deploy
# it to a core device (systemd variant; the portable core has no deployment
# agent):
#
#   scripts/aws-deploy-hello.sh <thing-name>
#
# The recipe has no artifacts; the binary ships in the image.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
thing=${1:?usage: $0 <thing-name>}
region=${AWS_REGION:-$(aws configure get region)}
recipe=$repo/components/esp32s31-ggl-hello/recipe.yaml
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

aws greengrassv2 create-deployment --region "$region" \
	--target-arn "arn:aws:iot:$region:$account:thing/$thing" \
	--deployment-name "$name on $thing" \
	--components "{\"$name\":{\"componentVersion\":\"$version\"}}" \
	--query deploymentId --output text
