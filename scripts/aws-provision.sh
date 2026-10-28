#!/bin/sh
# Provision an AWS IoT Thing for a Greengrass Lite core device:
#
#   scripts/aws-provision.sh <thing-name>
#
#   AWS_REGION       default: the CLI's configured region
#   GG_ROLE_ALIAS    existing IoT role alias for the Token Exchange Service
#
# Creates the Thing, an active certificate with a new key pair, and an IoT
# policy scoped to that Thing, then writes the device credentials and its
# Greengrass config.yaml to $S31_WORK/secrets/<thing-name> (mode 0700).
# The token-exchange role/alias and the account's Greengrass service role
# must already exist; this script only checks them.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
thing=${1:?usage: $0 <thing-name>}
region=${AWS_REGION:-$(aws configure get region)}
role_alias=${GG_ROLE_ALIAS:-ESP32S31GreengrassTokenExchangeAlias}
policy=${thing}-greengrass-policy
secrets=$work/secrets/$thing

if [ -e "$secrets/device.pem.crt" ]; then
	echo "$secrets already holds credentials; refusing to overwrite" >&2
	exit 1
fi

account=$(aws sts get-caller-identity --query Account --output text)
aws iot describe-role-alias --region "$region" --role-alias "$role_alias" \
	--query roleAliasDescription.roleArn --output text >/dev/null
aws greengrassv2 get-service-role-for-account --region "$region" \
	--query roleArn --output text >/dev/null

umask 077
mkdir -p "$secrets"

aws iot create-thing --region "$region" --thing-name "$thing" >/dev/null

sed -e "s|@REGION@|$region|g" -e "s|@ACCOUNT@|$account|g" \
	-e "s|@THING@|$thing|g" -e "s|@ROLE_ALIAS@|$role_alias|g" \
	"$repo/aws/device-policy.json.in" >"$secrets/device-policy.json"
aws iot create-policy --region "$region" --policy-name "$policy" \
	--policy-document "file://$secrets/device-policy.json" >/dev/null

cert_arn=$(aws iot create-keys-and-certificate --region "$region" \
	--set-as-active \
	--certificate-pem-outfile "$secrets/device.pem.crt" \
	--private-key-outfile "$secrets/private.pem.key" \
	--query certificateArn --output text)
echo "$cert_arn" >"$secrets/certificate-arn"
aws iot attach-policy --region "$region" --policy-name "$policy" \
	--target "$cert_arn"
aws iot attach-thing-principal --region "$region" --thing-name "$thing" \
	--principal "$cert_arn"

curl -fsS -o "$secrets/AmazonRootCA1.pem" \
	https://www.amazontrust.com/repository/AmazonRootCA1.pem

data_endpoint=$(aws iot describe-endpoint --region "$region" \
	--endpoint-type iot:Data-ATS --query endpointAddress --output text)
cred_endpoint=$(aws iot describe-endpoint --region "$region" \
	--endpoint-type iot:CredentialProvider --query endpointAddress \
	--output text)
sed -e "s|@REGION@|$region|g" -e "s|@THING@|$thing|g" \
	-e "s|@ROLE_ALIAS@|$role_alias|g" \
	-e "s|@DATA_ENDPOINT@|$data_endpoint|g" \
	-e "s|@CRED_ENDPOINT@|$cred_endpoint|g" \
	"$repo/aws/config.yaml.in" >"$secrets/config.yaml"

echo "Provisioned $thing ($cert_arn)"
echo "Credentials and config.yaml: $secrets"
