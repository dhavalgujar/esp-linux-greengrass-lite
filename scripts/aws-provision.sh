#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Set up AWS IoT fleet provisioning for a fleet of Greengrass Lite core
# devices, and write the claim certificate and device configuration for it:
#
#   scripts/aws-provision.sh <fleet-name>
#
#   AWS_REGION       default: the CLI's configured region
#   GG_ROLE_ALIAS    existing IoT role alias for the Token Exchange Service
#                    (default: ESP32S31GreengrassTokenExchangeAlias)
#
# Creates what does not exist yet, and leaves what does:
#   - thing group <fleet>, which every device joins (deploy to it);
#   - IAM role <fleet>-provisioning, with which AWS IoT registers devices;
#   - provisioning template <fleet>: Thing <fleet>-<serial>, the certificate
#     signed from the device's CSR, and an IoT policy scoped to that Thing;
#   - IoT policy <fleet>-claim and a claim certificate that may only use it.
# Writes $S31_WORK/secrets/<fleet>/{config.yaml,claim/} (mode 0700); devices
# provision themselves from these at boot (S95greengrass). The token-exchange
# role and alias and the account's Greengrass service role must already
# exist; this script only checks them.
#
# The template does not validate devices: anyone holding the claim can
# register a device in the fleet. In production, add a pre-provisioning hook
# that checks the serial number against your records.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
fleet=${1:?usage: $0 <fleet-name>}
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
mkdir -p "$secrets/claim"
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

data_endpoint=$(aws iot describe-endpoint --region "$region" \
	--endpoint-type iot:Data-ATS --query endpointAddress --output text)
cred_endpoint=$(aws iot describe-endpoint --region "$region" \
	--endpoint-type iot:CredentialProvider --query endpointAddress \
	--output text)
subst "$repo/aws/config.yaml.in" >"$secrets/config.yaml"

echo "Fleet $fleet ready: devices register as $fleet-<serial> in thing group $fleet"
echo "Claim and config.yaml: $secrets"
