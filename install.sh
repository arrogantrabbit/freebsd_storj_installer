#!/bin/sh

# Identity token <email:hash>
IDENTITY_AUTH_TOKEN="CHANGE_ME1"

# External address and port, setup port forwarding as needed
CONTACT_EXTERNAL_ADDRESS="example.com:28967"

# Operator email address
OPERATOR_EMAIL="user@example.com"

# Wallet
OPERATOR_WALLET="0x0e......02f"
OPERATOR_WALLET_FEATURES="zksync"

# Location WHERE the store will be initialized.
STORAGE_PATH="/mnt/storagenode"

# ip to ping for network connectivity test
NETWAIT_IP="1.1.1.1"

# Where to run console
CONSOLE_ADDRESS=":14002"

# How much space to allocate
STORAGE_ALLOCATED_DISK_SPACE="1.00 TB"

## Should not need to change anything beyond this line
## ---------------------------------------------------

if [ "$IDENTITY_AUTH_TOKEN" = "CHANGE_ME" ]; then
  echo "Edit the script and specify required parameters:"
  echo "IDENTITY_AUTH_TOKEN, CONTACT_EXTERNAL_ADDRESS, OPERATOR_EMAIL, OPERATOR_WALLET, STORAGE_PATH"
  exit 1
fi

[ -w "${STORAGE_PATH}" ] || (echo "Specified storage path is not writable: ${STORAGE_PATH}";  exit 1)

IDENTITY_ROOT="${STORAGE_PATH}/identity"
CONFIG_DIR="${STORAGE_PATH}/config"
mkdir -p "${CONFIG_DIR}" "${IDENTITY_ROOT}" || exit 1

[ "$(id -u)" -eq 0 ] || (echo "Restart the script as superuser"; exit 1)

# Prerequisites
pkg install -y jq curl unzip || exit 1

# Adding the storagenode user "storagenode" with group "storagenode" unless already exists
id -g storagenode >/dev/null 2>/dev/null || (pw groupadd storagenode || exit 1)
id -g storagenode >/dev/null 2>/dev/null || (pw useradd -n storagenode -G storagenode -s /nonexistent -h - || exit 1)

# Taking ownership of the storage directory
chown -R storagenode:storagenode "${STORAGE_PATH}" || exit 1

# NOTE on storagenode_updater: As of today, storagenode updater does not know how to restart the service on freebsd.
# While it successfully updates the executable it continues running the old one.
# Until the situation changes we include a simple shell script instead of storage node updater that ignores input
# parameters and simply does the job. When this changes, uncomment the STORAGENODE_UPDATER_XXX related code below.
# See https://github.com/storj/storj/issues/5333

# Figure out suggested version and URL:
VERSION_CHECK_URL="https://version.storj.io"
SUGGESTION=$(curl -L "${VERSION_CHECK_URL}" 2>/dev/null | jq -r '.processes.storagenode.suggested')
VERSION=$(echo "${SUGGESTION}" | jq -r '.version')

[ -z "${VERSION}" ] && (echo "Failed to determine suggested version";  exit 1)
echo "Suggested STORJ version: v${VERSION}"

STORAGENODE_URL=$(echo "${SUGGESTION}" | jq -r '.url' | sed "s/[{]arch[}]/amd64/g" | sed "s/[{]os[}]/freebsd/g")
[ -z "${STORAGENODE_URL}" ] && (echo "Failed to determine suggested storage node download URL"; exit 1)

echo "Storagenode download URL: ${STORAGENODE_URL}"
#STORAGENODE_UPDATER_URL="https://github.com/storj/storj/releases/download/v${VERSION}/storagenode-updater_freebsd_amd64.zip"
IDENTITY_URL="https://github.com/storj/storj/releases/download/v${VERSION}/identity_freebsd_amd64.zip"

mkdir -p /tmp/"${VERSION}" || (echo "Cannot make a folder under /tmp"; exit 1)

IDENTITY_ZIP=/tmp/${VERSION}/$(basename "${IDENTITY_URL}")
STORAGENODE_ZIP=/tmp/${VERSION}/$(basename "${STORAGENODE_URL}")
#STORAGENODE_UPDATER_ZIP=/tmp/${VERSION}/$(basename ${STORAGENODE_UPDATER_URL})

TARGET_BIN_DIR="/usr/local/bin"

fetch()
{
  WHAT="${1}"
  WHERE="${2}"
  if [ ! -f "${WHERE}" ] ; then
    echo "Downloading ${WHAT} from ${WHERE}"
    curl --remove-on-error -L "${WHAT}" -o "${WHERE}"
  fi
  if [ ! -f "${WHERE}" ] ; then
    echo "Failed to download ${WHERE} from ${WHAT}"
    exit 1
  fi
}

echo "Fetching executables from the internet"
fetch "${IDENTITY_URL}"    "${IDENTITY_ZIP}"
fetch "${STORAGENODE_URL}" "${STORAGENODE_ZIP}"
#fetch "${STORAGENODE_UPDATER_URL}" "${STORAGENODE_UPDATER_ZIP}"

echo "Stopping existing services"
service storagenode stop 2>/dev/null >/dev/null
service storagenode_updater stop 2>/dev/null >/dev/null

echo "Copying rc scripts and replacement updater"
cp -rv overlay/ /

echo "Extracting downloaded binaries to ${TARGET_BIN_DIR}"
unzip -d "${TARGET_BIN_DIR}" -o "${IDENTITY_ZIP}"
unzip -d "${TARGET_BIN_DIR}" -o "${STORAGENODE_ZIP}"
#unzip -d "${TARGET_BIN_DIR}" -o "${STORAGENODE_UPDATER_ZIP}"

IDENTITY_DIR="${IDENTITY_ROOT}/storagenode"

if [ ! -f "${IDENTITY_DIR}/identity.cert" ]; then
  echo "Generating new identity"
  su -m storagenode -c "identity create storagenode --config-dir \"${CONFIG_DIR}\" --identity-dir \"${IDENTITY_ROOT}\"" || exit 1
else
  echo "Identity found in ${IDENTITY_DIR}"
fi

if [ 0 -eq "$(find "${IDENTITY_DIR}" -name "identity.*.cert" | wc -l)" ]; then
  echo "Authorizing the storage node with identity ${IDENTITY_AUTH_TOKEN}"
  su -m storagenode -c "identity authorize storagenode \"${IDENTITY_AUTH_TOKEN}\" --config-dir \"${CONFIG_DIR}\" --identity-dir \"${IDENTITY_ROOT}\"" || exit 1
else
  echo "Identity is already authorized for at least one token, skipping node authorization"
fi

echo "Verifying identity files"
[ 2 -eq "$(grep -c BEGIN "${IDENTITY_DIR}/ca.cert")" ] || (echo "Bad Identity: ca.cert"; exit 1)
[ 3 -eq "$(grep -c BEGIN "${IDENTITY_DIR}/identity.cert")" ] || (echo "Bad Identity: identity.cert"; exit 1)

CONFIG_FILE="${CONFIG_DIR}/config.yaml"
if [ ! -f "${CONFIG_FILE}" ]; then
  echo "Configuring storagenode"
  su -m storagenode -c "storagenode setup --storage.path "${STORAGE_PATH}" --config-dir \"${CONFIG_DIR}\" --identity-dir \"${IDENTITY_DIR}\" --operator.email \"${OPERATOR_EMAIL}\" --console.address \"${CONSOLE_ADDRESS}\" --operator.wallet \"${OPERATOR_WALLET}\" --operator.wallet-features \"${OPERATOR_WALLET_FEATURES}\" --contact.external-address \"${CONTACT_EXTERNAL_ADDRESS}\" --storage.allocated-disk-space \"${STORAGE_ALLOCATED_DISK_SPACE}\"" || exit 1
else
  echo "Storagenode setup has already been performed (config file exists), skipping node setup"
fi

# Setting ownership again
#chown -R storagenode:storagenode "${STORAGE_PATH}" || exit 1


echo "Configuring netwait to wait for ${NETWAIT_IP}"
sysrc netwait_ip="${NETWAIT_IP}"

echo "Configuring storagenode rc service"
sysrc storagenode_identity_dir="${IDENTITY_DIR}"
sysrc storagenode_config_dir="${CONFIG_DIR}"
# This is needed to prevent the service from starting if the storage is not mounted.
sysrc storagenode_storage_path="${STORAGE_PATH}"

echo "Configuring storagenode_updater rc service"
sysrc storagenode_updater_config_dir="${CONFIG_DIR}"
sysrc storagenode_updater_identity_dir="${IDENTITY_DIR}"

echo "Enabling services"
service storagenode enable
service storagenode_updater enable
service newsyslog enable
service netwait enable

echo "Starting services"
service storagenode start
service storagenode_updater start
service newsyslog start

echo "Success"
