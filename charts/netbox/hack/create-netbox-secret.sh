#!/usr/bin/env bash
#
# Creates the `netbox-secrets` Secret this chart expects, in one namespace.
#
# Run this once before installing the chart. Re-running it is safe: values that
# already exist in the Secret are kept, so the generated secret_key and
# api_token_peppers survive — losing them invalidates all sessions and all v2
# API tokens.
#
#   ./create-netbox-secret.sh -n netbox-prod -e netbox-admin@cyberlink.ch
#
# The DB and admin passwords are asked for interactively unless given with
# -d / -p. Note that passing them as arguments puts them in your shell history.

set -euo pipefail

NAMESPACE=""
NAME="netbox-secrets"
ADMIN_USER="admin"
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
DB_PASSWORD=""

usage() {
	cat <<EOF
usage: $(basename "$0") -n <namespace> [options]

  -n <namespace>   Namespace of the NetBox instance (required)
  -s <name>        Secret name (default: ${NAME})
  -u <username>    NetBox superuser name (default: ${ADMIN_USER})
  -e <email>       NetBox superuser email (required on first run)
  -p <password>    NetBox superuser password (asked for if omitted)
  -d <password>    PostgreSQL password (asked for if omitted)
  -h               This text
EOF
}

while getopts ":n:s:u:e:p:d:h" opt; do
	case "${opt}" in
	n) NAMESPACE="${OPTARG}" ;;
	s) NAME="${OPTARG}" ;;
	u) ADMIN_USER="${OPTARG}" ;;
	e) ADMIN_EMAIL="${OPTARG}" ;;
	p) ADMIN_PASSWORD="${OPTARG}" ;;
	d) DB_PASSWORD="${OPTARG}" ;;
	h)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 1
		;;
	esac
done

if [[ -z "${NAMESPACE}" ]]; then
	echo "error: -n <namespace> is required" >&2
	usage >&2
	exit 1
fi

for cmd in kubectl openssl; do
	command -v "${cmd}" >/dev/null || {
		echo "error: ${cmd} not found in PATH" >&2
		exit 1
	}
done

# Current value of a key in the Secret, empty if the Secret or the key is absent.
# Decoded by kubectl itself, so this does not depend on the local base64 flavour.
current() {
	kubectl -n "${NAMESPACE}" get secret "${NAME}" \
		-o go-template="{{ if .data }}{{ with (index .data \"$1\") }}{{ . | base64decode }}{{ end }}{{ end }}" \
		2>/dev/null || true
}

ask() {
	local prompt="$1" value=""
	read -r -s -p "${prompt}: " value </dev/tty
	echo >&2
	printf '%s' "${value}"
}

# Generated once and then kept for the lifetime of the instance.
SECRET_KEY="$(current secret_key)"
API_TOKEN_PEPPERS="$(current api_token_peppers)"
API_TOKEN="$(current api_token)"
VALKEY_PASSWORD="$(current valkey_password)"
EMAIL_PASSWORD="$(current email_password)"

[[ -n "${SECRET_KEY}" ]] || SECRET_KEY="$(openssl rand -base64 60 | tr -d '\n=')"
[[ -n "${API_TOKEN_PEPPERS}" ]] ||
	API_TOKEN_PEPPERS="$(printf '{"1":"%s"}' "$(openssl rand -base64 48 | tr -d '\n=')")"
# NetBox tokens are 40 characters.
[[ -n "${API_TOKEN}" ]] || API_TOKEN="$(openssl rand -hex 20)"
[[ -n "${VALKEY_PASSWORD}" ]] || VALKEY_PASSWORD="$(openssl rand -hex 24)"

# Asked for, or taken over from an existing Secret.
[[ -n "${ADMIN_EMAIL}" ]] || ADMIN_EMAIL="$(current email)"
if [[ -z "${ADMIN_EMAIL}" ]]; then
	echo "error: -e <email> is required for the NetBox superuser" >&2
	exit 1
fi

if [[ -z "${ADMIN_PASSWORD}" ]]; then
	ADMIN_PASSWORD="$(current password)"
	[[ -n "${ADMIN_PASSWORD}" ]] || ADMIN_PASSWORD="$(ask "NetBox superuser password")"
fi
if [[ -z "${DB_PASSWORD}" ]]; then
	DB_PASSWORD="$(current db_password)"
	[[ -n "${DB_PASSWORD}" ]] || DB_PASSWORD="$(ask "PostgreSQL password for the NetBox user")"
fi

# email_password has to exist even when unused: the upstream chart projects the
# key without `optional: true`, so a missing key leaves the pods in
# ContainerCreating.
kubectl -n "${NAMESPACE}" create secret generic "${NAME}" \
	--from-literal=secret_key="${SECRET_KEY}" \
	--from-literal=api_token_peppers="${API_TOKEN_PEPPERS}" \
	--from-literal=email_password="${EMAIL_PASSWORD}" \
	--from-literal=username="${ADMIN_USER}" \
	--from-literal=password="${ADMIN_PASSWORD}" \
	--from-literal=email="${ADMIN_EMAIL}" \
	--from-literal=api_token="${API_TOKEN}" \
	--from-literal=db_password="${DB_PASSWORD}" \
	--from-literal=valkey_password="${VALKEY_PASSWORD}" \
	--dry-run=client -o yaml | kubectl apply -f -

echo "secret ${NAMESPACE}/${NAME} is in place; you can install the chart now."
