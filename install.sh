#!/bin/sh

# Identity token <email:hash>
IDENTITY_AUTH_TOKEN="CHANGE_ME"

# External address and port, setup port forwarding as needed
CONTACT_EXTERNAL_ADDRESS="example.com:28968"

# Operator email address
OPERATOR_EMAIL="user@example.com"

# Wallet
OPERATOR_WALLET="0x0e......02f"
OPERATOR_WALLET_FEATURES=""

# Location where the store will be initialized.
STORAGE_PATH="/mnt/storj"

# ip to ping for network connectivity test
NETWAIT_IP="1.1.1.1"

# Where to run console
CONSOLE_ADDRESS=":14002"

# How much space to allocate
STORAGE_ALLOCATED_DISK_SPACE="1.00 TB"

if [ "$IDENTITY_AUTH_TOKEN" = "CHANGE_ME" ]; then
  echo "Edit the script and specify required parameters:"
  echo "IDENTITY_AUTH_TOKEN, CONTACT_EXTERNAL_ADDRESS, OPERATOR_EMAIL, OPERATOR_WALLET, STORAGE_PATH"
  exit 1
fi

if [ ! -w "${STORAGE_PATH}" ]; then
  echo "Storage path is not writable"
  exit 1
fi

IDENTITY_ROOT="${STORAGE_PATH}/identity"
CONFIG_DIR="${STORAGE_PATH}/config"
mkdir -p "${CONFIG_DIR}" "${IDENTITY_ROOT}" || exit 1

# Prerequisites
pkg install -y jq curl unzip || exit 1

# NOTE on storagenode-updater: As of today, storagenode updater does not know how to restart the service on freebsd.
# While it successfully updates the executable it continues running the old one.
# Until the situation changes we include a simple shell script instead of storage node updater that ignores input
# parameters and simply does the job. When this changes, uncomment the STORAGENODE_UPDATER_XXX related code below.
# See https://github.com/storj/storj/issues/5333

# Figure out suggested version and URL:
VERSION_CHECK_URL="https://version.storj.io"
SUGGESTION=$(curl -L "${VERSION_CHECK_URL}" 2>/dev/null | jq -r '.processes.storagenode.suggested')
VERSION=$(echo "${SUGGESTION}" | jq -r '.version')

if [ -z "${VERSION}" ]; then
    echo "Failed to determine suggested version"
    exit 1
fi

echo "Suggested STORJ version: v${VERSION}"

STORAGENODE_URL=$(echo "${SUGGESTION}" | jq -r '.url' | sed "s/[{]arch[}]/amd64/g" | sed "s/[{]os[}]/freebsd/g")

if [ -z "${STORAGENODE_URL}" ]; then
    echo "Failed to determine suggested storage node download URL"
    exit 1
fi

echo "Storagenode download URL: ${STORAGENODE_URL}"
#STORAGENODE_UPDATER_URL="https://github.com/storj/storj/releases/download/v${VERSION}/storagenode-updater_freebsd_amd64.zip"
IDENTITY_URL="https://github.com/storj/storj/releases/download/v${VERSION}/identity_freebsd_amd64.zip"

mkdir -p /tmp/"${VERSION}"

IDENTITY_ZIP=/tmp/${VERSION}/$(basename "${IDENTITY_URL}")
STORAGENODE_ZIP=/tmp/${VERSION}/$(basename "${STORAGENODE_URL}")
#STORAGENODE_UPDATER_ZIP=/tmp/${VERSION}/$(basename ${STORAGENODE_UPDATER_URL})

TARGET_BIN_DIR="/usr/local/bin"

fetch() {
  what="${1}"
  where="${2}"

  if [ ! -f "${where}" ] ; then
    echo "Downloading ${what} from ${where}"
    curl -L "${what}" -o "${where}"
  fi
  if [ ! -f "${where}" ] ; then
    echo "Failed to download ${where} from ${what}"
    exit 1
  fi
}

echo "Fetching executables from the internet"
fetch "${IDENTITY_URL}"    "${IDENTITY_ZIP}"
fetch "${STORAGENODE_URL}" "${STORAGENODE_ZIP}"
#fetch "${STORAGENODE_UPDATER_URL}" "${STORAGENODE_UPDATER_ZIP}"

echo "Stopping existing services"
service storj stop 2>/dev/null >/dev/null
service storjupd stop 2>/dev/null >/dev/null

echo "Copying rc scripts and replacement updater"
cp -rv root/ /

echo "Extracting downloaded binaries to ${TARGET_BIN_DIR}"
unzip -d "${TARGET_BIN_DIR}" -o "${IDENTITY_ZIP}"
unzip -d "${TARGET_BIN_DIR}" -o "${STORAGENODE_ZIP}"
#unzip -d "${TARGET_BIN_DIR}" -o "${STORAGENODE_UPDATER_ZIP}"

IDENTITY_DIR="${IDENTITY_ROOT}/storagenode"

if [ ! -f "${IDENTITY_DIR}/identity.cert" ]; then
  echo "Generating new identity"
  identity create storagenode \
    --config-dir "${CONFIG_DIR}" \
    --identity-dir "${IDENTITY_ROOT}" \
    || exit 1
else
  echo "Identity found in ${IDENTITY_DIR}"
fi

if [ 0 -eq $(find "${IDENTITY_DIR}" -name "identity.*.cert" | wc -l) ]; then
  echo "Authorizing the storage node with identity ${IDENTITY_AUTH_TOKEN}"
  identity authorize storagenode "${IDENTITY_AUTH_TOKEN}" \
    --config-dir "${CONFIG_DIR}" \
    --identity-dir "${IDENTITY_ROOT}" \
    || exit 1
else
  echo "Identity is already authorized for at least one token."
fi

if [ 2 -ne $(grep -c BEGIN ${IDENTITY_DIR}/ca.cert) ]; then
  echo "Bad Identity: ca.cert"
  exit 1
fi

if [ 3 -ne $(grep -c BEGIN ${IDENTITY_DIR}/identity.cert) ]; then
  echo "Bad Identity: identity.cert"
  exit 1
fi

CONFIG_FILE="${CONFIG_DIR}/config.yaml"

if [ ! -f "${CONFIG_FILE}" ]; then
  storagenode setup \
    --storage.path "${STORAGE_PATH}" \
    --config-dir "${CONFIG_DIR}" \
    --identity-dir "${IDENTITY_DIR}" \
    --operator.email "${OPERATOR_EMAIL}" \
    --console.address "${CONSOLE_ADDRESS}" \
    --operator.wallet "${OPERATOR_WALLET}" \
    --operator.wallet-features "${OPERATOR_WALLET_FEATURES}" \
    --contact.external-address "${CONTACT_EXTERNAL_ADDRESS}" \
    --storage.allocated-disk-space "${STORAGE_ALLOCATED_DISK_SPACE}"
fi

echo "Configuring netwait to wait for ${NETWAIT_IP}"
sysrc netwait_ip="${NETWAIT_IP}"

echo "Configuring storj"
sysrc storj_identity_dir="${IDENTITY_DIR}"
sysrc storj_config_dir="${CONFIG_DIR}"
# This is needed to prevent the service from starting if the storage is not mounted.
sysrc storj_storage_path="${STORAGE_PATH}"

echo "Enabling services"
service storj enable
service storjupd enable
service newsyslog enable
service netwait enable

echo "Starting services"
service storj start
service storjupd start
service newsyslog start

