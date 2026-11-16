#!/usr/bin/env bash
# Adds a LeviLamina release to v2/version-db.json, under the client game version it supports.
#
# TAG (optional) names the release, e.g. v26.60.8; without it, the highest version tag of
# LeviLamina is used. The client game version is read from the client entry's dependency on
# bedrock-runtime-data, in lip.toml (format 4) or, for older releases, tooth.json.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DB_FILE="${SCRIPT_DIR}/v2/version-db.json"
REPO="LiteLDev/LeviLamina"
BRD_ID="github.com/LiteLDev/bedrock-runtime-data"

for cmd in curl jq git python3; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "${cmd} is required" >&2; exit 1; }
done

if [[ ! -f "${DB_FILE}" ]]; then
    echo "version-db.json not found at ${DB_FILE}" >&2
    exit 1
fi

TAG="${TAG:-}"

if [[ -z "${TAG}" ]]; then
    # The highest SemVer tag (the tags API is not ordered by version: v26.60.10 < v26.60.9).
    TAG=$(git ls-remote --tags --refs "https://github.com/${REPO}.git" 'v*' \
    | python3 -I -c '
import re, sys
SEMVER = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$")
def key(m):
    pre = m.group(4)
    ids = [] if pre is None else [(0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split(".")]
    # A release sorts above its pre-releases.
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), pre is None, ids)
tags = []
for line in sys.stdin:
    name = line.split("refs/tags/", 1)[-1].strip()
    m = SEMVER.match(name)
    if m:
        tags.append((key(m), name))
print(max(tags)[1] if tags else "")
')
fi

if [[ -z "${TAG}" ]]; then
    echo "Failed to determine latest tag" >&2
    exit 1
fi

if [[ ! "${TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "Not a version tag: ${TAG}" >&2
    exit 1
fi

RAW_URL="https://github.com/${REPO}/raw/refs/tags/${TAG}"
MANIFEST=$(mktemp)
trap 'rm -f "${MANIFEST}"' EXIT

# lip.toml since the first lip.toml release; tooth.json before it.
if curl -fsL "${RAW_URL}/lip.toml" -o "${MANIFEST}"; then
    CLIENT_BRD_VERSION=$(python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    doc = tomllib.load(f)
entries = [e for e in doc.get("variants", {}).get("", []) if e.get("side") == "client"]
deps = entries[0].get("deps", {}) if entries else {}
print(deps.get(sys.argv[2], ""))
' "${MANIFEST}" "${BRD_ID}")
elif curl -fsSL "${RAW_URL}/tooth.json" -o "${MANIFEST}"; then
    CLIENT_BRD_VERSION=$(jq -r --arg id "${BRD_ID}" \
        '.variants[] | select(.label=="client") | .dependencies[$id] | select(.!=null)' "${MANIFEST}")
else
    echo "${TAG} has neither lip.toml nor tooth.json" >&2
    exit 1
fi

if [[ -z "${CLIENT_BRD_VERSION}" ]]; then
    echo "Failed to read bedrock-runtime-data dependency of the client entry of ${TAG}" >&2
    exit 1
fi

# Only list a release that a client can install: its client build must be uploaded.
ASSET_URL="https://github.com/${REPO}/releases/download/${TAG}/levilamina-${TAG}-client-release-windows-x64.zip"
if ! curl -fsSIL -o /dev/null "${ASSET_URL}"; then
    echo "The client build of ${TAG} is not uploaded yet: ${ASSET_URL}" >&2
    exit 1
fi

# 26.60.5-client.15 -> 1.26.60.05 (the game version, its last number in two digits).
IFS=. read -r MAJOR MINOR PATCH <<< "${CLIENT_BRD_VERSION%%-*}"
if [[ ! "${MAJOR}.${MINOR}.${PATCH}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Unexpected bedrock-runtime-data version: ${CLIENT_BRD_VERSION}" >&2
    exit 1
fi
GAME_VERSION=$(printf '1.%s.%s.%02d' "${MAJOR}" "${MINOR}" "$((10#${PATCH}))")

SHORT_TAG="${TAG#v}"

TMP_FILE=$(mktemp)
jq --arg tag "${SHORT_TAG}" --arg ver "${GAME_VERSION}" '.versions[$ver] = ((.versions[$ver] // []) + [$tag] | unique)' "${DB_FILE}" > "${TMP_FILE}"
mv "${TMP_FILE}" "${DB_FILE}"

echo "Updated ${DB_FILE} with ${SHORT_TAG}: ${GAME_VERSION}"
