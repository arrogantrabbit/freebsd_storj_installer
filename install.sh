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
NETWAIT_IP=1.1.1.1

# Where to run console
CONSOLE_ADDRESS=":14002"

if [ "$IDENTITY_AUTH_TOKEN" == "CHANGE_ME" ]; then
  echo "Edit the script and specify required parameters:"
  echo "IDENTITY_AUTH_TOKEN, CONTACT_EXTERNAL_ADDRESS, OPERATOR_EMAIL, OPERATOR_WALLET, STORAGE_PATH"
  exit 1
fi

if [ ! -d "${STORAGE_PATH}" ]; then
  echo "Storage path is not accessible"
  exit 1
fi

IDENTITY_DIR="${STORAGE_PATH}/identity"
CONFIG_DIR="${STORAGE_PATH}/config"
mkdir -p "${CONFIG_DIR}" "${IDENTITY_DIR}" || exit 1

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
  what=$1
  where=$2

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

if [ ! -f "${IDENTITY_DIR}/storagenode/identity.cert" ]; then
  echo "Generating new identity"
  identity create storagenode --config-dir "${CONFIG_DIR}" --identity-dir "${IDENTITY_DIR}" || exit 1
else
  echo "Identity found in ${IDENTITY_DIR}"
fi

if [ "0" == "$(find "${IDENTITY_DIR}/storagenode" -name "identity.*.cert" | wc -l)" ]; then
  echo "Authorizing the storage node with identity ${IDENTITY_AUTH_TOKEN}"
  identity authorize storagenode "${IDENTITY_AUTH_TOKEN}" --config-dir "${CONFIG_DIR}" --identity-dir "${IDENTITY_DIR}" || exit 1
else
  echo "Identity is already authorized for at least one token."
fi

if [ "2" != "$(grep -c BEGIN ${IDENTITY_DIR}/storagenode/ca.cert)" ]; then
  echo "Bad Identity: ca.cert"
  exit 1
fi

if [ "3" != "$(grep -c BEGIN ${IDENTITY_DIR}/storagenode/identity.cert)" ]; then
  echo "Bad Identity: identity.cert"
  exit 1
fi

if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
  storagenode setup --storage.path "${STORAGE_PATH}" --config-dir "${CONFIG_DIR}" --identity-dir "${IDENTITY_DIR}/storagenode"
fi

echo "Configuring netwait to wait for ${NETWAIT_IP}"
sysrc netwait_ip="${NETWAIT_IP}"

echo "Configuring storj"
sysrc storj_console_address="${CONSOLE_ADDRESS}"
sysrc storj_operator_email="${OPERATOR_EMAIL}"
sysrc storj_operator_wallet="${OPERATOR_WALLET}"
sysrc storj_operator_wallet_features="${OPERATOR_WALLET_FEATURES}"
sysrc storj_storage_path="${STORAGE_PATH}"
sysrc storj_identity_dir="${IDENTITY_DIR}/storagenode"
sysrc storj_config_dir="${CONFIG_DIR}"
sysrc storj_contact_external_address="${CONTACT_EXTERNAL_ADDRESS}"

echo "Enabling services"
service storj enable
service storjupd enable
service newsyslog enable
service netwait enable

echo "Starting services"
service storj start
service storjupd start
service newsyslog start

