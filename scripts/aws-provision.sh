#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Set up a fleet of Greengrass Lite core devices in AWS IoT, and either a
# connection kit for one device of it, or fleet provisioning for all:
#
#   scripts/aws-provision.sh <fleet-name> --device <name>
#   scripts/aws-provision.sh <fleet-name>
#
#   AWS_REGION       default: the CLI's configured region
#   GG_ROLE_ALIAS    existing IoT role alias for the Token Exchange Service
#                    (default: ESP32S31GreengrassTokenExchangeAlias)
#
# Creates what does not exist yet, and leaves what does:
#   - thing group <fleet>, which every device joins (deploy to it);
#   - IAM role <fleet>-provisioning, with which AWS IoT registers devices;
#   - provisioning template <fleet>: Thing <fleet>-<serial>, its
#     certificate, and an IoT policy scoped to that Thing.
# The token-exchange role and alias and the account's Greengrass service role
# must already exist; this script only checks them.
#
# --device <name>: registers Thing <fleet>-<name> through the template, with
# a new key and certificate, and writes a connection kit for it, in the
# format the AWS IoT console downloads for a nucleus lite core device, to
# $S31_WORK/secrets/<fleet>/devices/<fleet>-<name>-connectionKit.zip (mode
# 0700 directory). Install it with scripts/nfs-deploy.sh --kit. The private
# key is created here, on the workstation.
#
# Without --device: fleet provisioning. Creates IoT policy <fleet>-claim and
# a claim certificate that may only use it, and writes them with the fleet's
# config.yaml to $S31_WORK/secrets/<fleet>/{config.yaml,claim/}; devices
# provision themselves from these at boot (scripts/nfs-deploy.sh --claim;
# the 16 MiB configuration, whose patches let fleet provisioning work on
# this chip).
# The template does not validate devices: anyone holding the claim can
# register a device in the fleet. In production, add a pre-provisioning hook
# that checks the serial number against your records.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
fleet=${1:?usage: $0 <fleet-name> [--device <name>]}
device=
if [ "${2:-}" = --device ]; then
	device=${3:?usage: $0 <fleet-name> [--device <name>]}
fi
region=${AWS_REGION:-$(aws configure get region)}
role_alias=${GG_ROLE_ALIAS:-ESP32S31GreengrassTokenExchangeAlias}
role=$fleet-provisioning
claim_policy=$fleet-claim
secrets=$work/secrets/$fleet

account=$(aws sts get-caller-identity --query Account --output text)
aws iot describe-role-alias --region "$region" --role-alias "$role_alias" \
	--query roleAliasDescription.roleArn --output text >/dev/null
aws greengrassv2 get-service-role-for-account --region "$region" \
	--query roleArn --output text >/dev/null

umask 077
mkdir -p "$secrets"
subst() {
	sed -e "s|@REGION@|$region|g" -e "s|@ACCOUNT@|$account|g" \
		-e "s|@FLEET@|$fleet|g" -e "s|@ROLE_ALIAS@|$role_alias|g" \
		-e "s|@DATA_ENDPOINT@|${data_endpoint:-}|g" \
		-e "s|@CRED_ENDPOINT@|${cred_endpoint:-}|g" "$1"
}

if aws iot describe-thing-group --region "$region" \
	--thing-group-name "$fleet" >/dev/null 2>&1; then
	echo "thing group $fleet: exists"
else
	aws iot create-thing-group --region "$region" \
		--thing-group-name "$fleet" >/dev/null
	echo "thing group $fleet: created"
fi

if role_arn=$(aws iam get-role --role-name "$role" \
	--query Role.Arn --output text 2>/dev/null); then
	echo "IAM role $role: exists"
else
	role_arn=$(aws iam create-role --role-name "$role" \
		--description "AWS IoT fleet provisioning for $fleet" \
		--assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"iot.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
		--query Role.Arn --output text)
	aws iam attach-role-policy --role-name "$role" --policy-arn \
		arn:aws:iam::aws:policy/service-role/AWSIoTThingsRegistration
	echo "IAM role $role: created"
	# IAM is eventually consistent: AWS IoT may not see a new role at once.
	sleep 10
fi

subst "$repo/aws/provisioning-template.json.in" >"$secrets/provisioning-template.json"
if aws iot describe-provisioning-template --region "$region" \
	--template-name "$fleet" >/dev/null 2>&1; then
	aws iot create-provisioning-template-version --region "$region" \
		--template-name "$fleet" --set-as-default \
		--template-body "file://$secrets/provisioning-template.json" >/dev/null
	echo "provisioning template $fleet: exists, body updated"
else
	aws iot create-provisioning-template --region "$region" \
		--template-name "$fleet" --enabled \
		--provisioning-role-arn "$role_arn" \
		--template-body "file://$secrets/provisioning-template.json" >/dev/null
	echo "provisioning template $fleet: created"
fi

data_endpoint=$(aws iot describe-endpoint --region "$region" \
	--endpoint-type iot:Data-ATS --query endpointAddress --output text)
cred_endpoint=$(aws iot describe-endpoint --region "$region" \
	--endpoint-type iot:CredentialProvider --query endpointAddress \
	--output text)

if [ -n "$device" ]; then
	thing=$fleet-$device
	dir=$secrets/devices/$thing
	kit=$secrets/devices/$thing-connectionKit.zip
	if [ -e "$kit" ]; then
		echo "$kit already exists; refusing to overwrite" >&2
		exit 1
	fi
	mkdir -p "$dir"
	cert_id=$(aws iot create-keys-and-certificate --region "$region" \
		--set-as-active \
		--certificate-pem-outfile "$dir/device.pem.crt" \
		--private-key-outfile "$dir/private.pem.key" \
		--query certificateId --output text)
	# The same template as fleet provisioning: the same Thing name, policy
	# and thing group as a device that provisioned itself. RegisterThing does
	# not evaluate Fn::Join, so the serial number is put in here.
	python3 - "$secrets/provisioning-template.json" "$device" \
		>"$dir/template.json" <<'PY'
import json, sys
template, serial = json.load(open(sys.argv[1])), sys.argv[2]
def render(x):
    if isinstance(x, dict) and "Fn::Join" in x:
        sep, parts = x["Fn::Join"]
        return sep.join(render(p) for p in parts)
    if isinstance(x, dict) and x.get("Ref") == "SerialNumber":
        return serial
    if isinstance(x, dict):
        return {k: render(v) for k, v in x.items()}
    if isinstance(x, list):
        return [render(v) for v in x]
    return x
template["Resources"] = render(template["Resources"])
del template["Parameters"]["SerialNumber"]
json.dump(template, sys.stdout)
PY
	aws iot register-thing --region "$region" \
		--template-body "file://$dir/template.json" \
		--parameters "{\"AWS::IoT::Certificate::Id\":\"$cert_id\"}" \
		>/dev/null
	curl -fsS -o "$dir/AmazonRootCA1.pem" \
		https://www.amazontrust.com/repository/AmazonRootCA1.pem
	# As the console writes it: the device fills in {{config_dir}} and
	# {{nucleus_component}}.
	cat >"$dir/config.yaml" <<EOF
---
system:
  privateKeyPath: "{{config_dir}}/private.pem.key"
  certificateFilePath: "{{config_dir}}/device.pem.crt"
  rootCaPath: "{{config_dir}}/AmazonRootCA1.pem"
  thingName: "$thing"
services:
  {{nucleus_component}}:
    componentType: "NUCLEUS"
    configuration:
      awsRegion: "$region"
      iotCredEndpoint: "$cred_endpoint"
      iotDataEndpoint: "$data_endpoint"
      iotRoleAlias: "$role_alias"
EOF
	zip -qj "$kit" "$dir/config.yaml" "$dir/device.pem.crt" \
		"$dir/private.pem.key" "$dir/AmazonRootCA1.pem"
	echo "Device $thing registered (certificate $cert_id) in thing group $fleet"
	echo "Connection kit: $kit"
	exit 0
fi

mkdir -p "$secrets/claim"
subst "$repo/aws/claim-policy.json.in" >"$secrets/claim-policy.json"
if aws iot get-policy --region "$region" \
	--policy-name "$claim_policy" >/dev/null 2>&1; then
	echo "IoT policy $claim_policy: exists"
else
	aws iot create-policy --region "$region" --policy-name "$claim_policy" \
		--policy-document "file://$secrets/claim-policy.json" >/dev/null
	echo "IoT policy $claim_policy: created"
fi

if [ -s "$secrets/claim/claim.pem.crt" ]; then
	echo "claim certificate: exists ($secrets/claim)"
else
	cert_arn=$(aws iot create-keys-and-certificate --region "$region" \
		--set-as-active \
		--certificate-pem-outfile "$secrets/claim/claim.pem.crt" \
		--private-key-outfile "$secrets/claim/claim.pem.key" \
		--query certificateArn --output text)
	echo "$cert_arn" >"$secrets/claim/certificate-arn"
	aws iot attach-policy --region "$region" --policy-name "$claim_policy" \
		--target "$cert_arn"
	echo "claim certificate: created ($cert_arn)"
fi
curl -fsS -o "$secrets/claim/AmazonRootCA1.pem" \
	https://www.amazontrust.com/repository/AmazonRootCA1.pem
subst "$repo/aws/config.yaml.in" >"$secrets/config.yaml"

echo "Fleet $fleet ready: devices register as $fleet-<serial> in thing group $fleet"
echo "Claim and config.yaml: $secrets"
