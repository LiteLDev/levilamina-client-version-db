#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DB_FILE="${SCRIPT_DIR}/version-db.json"
REPO="LiteLDev/LeviLamina"

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

if [[ ! -f "${DB_FILE}" ]]; then
    echo "version-db.json not found at ${DB_FILE}" >&2
    exit 1
fi

TAG="${TAG:-}"  # Optional override via environment variable

if [[ -z "${TAG}" ]]; then
    TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/tags?per_page=100" \
    | jq -r '.[0].name // empty')
fi

if [[ -z "${TAG}" ]]; then
    echo "Failed to determine latest tag" >&2
    exit 1
fi

TOOTH_URL="https://github.com/${REPO}/raw/refs/tags/${TAG}/tooth.json"

CLIENT_BRD_VERSION=$(curl -fsSL "${TOOTH_URL}" \
| jq -r '.variants[] | select(.label=="client") | .dependencies["github.com/LiteLDev/bedrock-runtime-data"] | select(.!=null)')

if [[ -z "${CLIENT_BRD_VERSION}" ]]; then
    echo "Failed to read bedrock-runtime-data dependency for client variant" >&2
    exit 1
fi

SHORT_TAG="${TAG#v}"
RUNTIME_VERSION="${CLIENT_BRD_VERSION%%-*}"

TMP_FILE=$(mktemp)
jq --arg tag "${SHORT_TAG}" --arg ver "${RUNTIME_VERSION}" '.versions[$ver] = ((.versions[$ver] // []) + [$tag] | unique)' "${DB_FILE}" > "${TMP_FILE}"
mv "${TMP_FILE}" "${DB_FILE}"

echo "Updated ${DB_FILE} with ${SHORT_TAG}: ${RUNTIME_VERSION}"
