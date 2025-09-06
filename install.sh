#!/bin/sh

# External address and port, setup port forwarding as needed
CONTACT_EXTERNAL_ADDRESS="example.com:28967"

# Operator email address
OPERATOR_EMAIL="user@example.com"

# Wallet
OPERATOR_WALLET="0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
OPERATOR_WALLET_FEATURES=""

# Location WHERE the store will be initialized.
STORAGE_PATH="/mnt/storagenode"
DATABASE_DIR="/mnt/storagenode"

# ip to ping for network connectivity test
NETWAIT_IP="1.1.1.1"

# Where to run console
CONSOLE_ADDRESS=":14002"

# How much space to allocate
STORAGE_ALLOCATED_DISK_SPACE="1.00 TB"

## Should not need to change anything beyond this line
## ---------------------------------------------------

if [ "$OPERATOR_EMAIL" = "user@example.com" ]; then
  echo "Error: Required configuration parameters not set."
  echo "Please edit this script and specify the following required parameters:"
  echo "  CONTACT_EXTERNAL_ADDRESS - External FQDN and port your node will be accessible at"
  echo "  OPERATOR_EMAIL - Your email address for node management"
  echo "  OPERATOR_WALLET - Your STORJ wallet address"
  echo "  STORAGE_PATH - Path where the storage is mounted (must be writable)"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: This script must be run as superuser (root)."
  echo "Please restart the script with sudo:"
  echo "  sudo ./install.sh"
  exit 1
fi

if [ ! -w "${STORAGE_PATH}" ]; then
  echo "Error: Specified storage path is not writable: ${STORAGE_PATH}"
  echo "Please ensure the directory exists and is writable by the current user."
  echo "You may need to create the directory or adjust permissions:"
  echo "  mkdir -p \"${STORAGE_PATH}\""
  echo "  chmod 755 \"${STORAGE_PATH}\""
  exit 1
fi

if [ ! -w "${STORAGE_PATH}" ]; then
  echo "Error: Storage path ${STORAGE_PATH} is not writable"
  exit 1
fi

# Validate that we can create files in the storage path
TEST_FILE="${STORAGE_PATH}/.storage_test"
if ! touch "${TEST_FILE}"; then
  echo "Error: Cannot create test file in storage path ${STORAGE_PATH}"
  exit 1
fi
rm -f "${TEST_FILE}"

echo "Storage path validation successful"

IDENTITY_ROOT="${STORAGE_PATH}/identity"
CONFIG_DIR="${STORAGE_PATH}/config"

if ! mkdir -p "${CONFIG_DIR}" "${IDENTITY_ROOT}"; then
  echo "Error: Failed to create required directories: ${CONFIG_DIR} and/or ${IDENTITY_ROOT}"
  exit 1
fi



echo "Installing required dependencies (jq, curl, unzip)"
if ! pkg install -y jq curl unzip; then
  echo "Error: Failed to install required dependencies."
  exit 1
fi

echo "Adding the storagenode user 'storagenode' with group 'storagenode' unless already exists"
id -g storagenode >/dev/null 2>/dev/null || pw groupadd storagenode
id -u storagenode >/dev/null 2>/dev/null || pw useradd -n storagenode -G storagenode -s /nonexistent -h -

echo "Taking ownership of the storage directory"
if ! chown -R storagenode:storagenode "${STORAGE_PATH}"; then
  echo "Error: Cannot change ownership of ${STORAGE_PATH}"
  exit 1
fi

echo "Taking ownership of the databases directory"
if ! chown -R storagenode:storagenode "${DATABASE_DIR}"; then
  echo "Error: Cannot change ownership of ${DATABASE_DIR}"
  exit 1
fi

# Figure out suggested version and URL:
VERSION_CHECK_URL="https://version.storj.io"
SUGGESTION=$(curl -L "${VERSION_CHECK_URL}" 2>/dev/null | jq -r '.processes.storagenode.suggested')
VERSION=$(echo "${SUGGESTION}" | jq -r '.version')

if [ -z "${VERSION}" ]; then
  echo "Failed to determine suggested version"
  exit 1
fi

echo "Suggested STORJ version: v${VERSION}"

# Get checksums from GitHub API
GH_API_URL="https://api.github.com/repos/storj/storj/releases/latest"
GH_DATA=$(curl -L "${GH_API_URL}" 2>/dev/null)

STORAGENODE_URL=$(echo "${SUGGESTION}" | jq -r '.url' | sed "s/[{]arch[}]/amd64/g" | sed "s/[{]os[}]/freebsd/g")
if [ -z "${STORAGENODE_URL}" ]; then
  echo "Failed to determine suggested storage node download URL"
  exit 1
fi

echo "Storagenode download URL: ${STORAGENODE_URL}"
STORAGENODE_UPDATER_URL="https://github.com/storj/storj/releases/download/v${VERSION}/storagenode-updater_freebsd_amd64.zip"
IDENTITY_URL="https://github.com/storj/storj/releases/download/v${VERSION}/identity_freebsd_amd64.zip"

# Extract checksums from GitHub API response
STORAGENODE_CHECKSUM=$(echo "${GH_DATA}" | jq -r --arg url "$(basename ${STORAGENODE_URL})" '.assets[] | select(.name == $url) | .digest')
STORAGENODE_UPDATER_CHECKSUM=$(echo "${GH_DATA}" | jq -r --arg url "$(basename ${STORAGENODE_UPDATER_URL})" '.assets[] | select(.name == $url) | .digest')
IDENTITY_CHECKSUM=$(echo "${GH_DATA}" | jq -r --arg url "$(basename ${IDENTITY_URL})" '.assets[] | select(.name == $url) | .digest')

if [ -z "${STORAGENODE_CHECKSUM}" ] || [ -z "${IDENTITY_CHECKSUM}" ]; then
  echo "Failed to determine checksums for downloaded files"
  exit 1
fi

if ! mkdir -p /tmp/"${VERSION}"; then
  echo "Error: Cannot create temporary directory under /tmp"
  exit 1
fi

IDENTITY_ZIP=/tmp/${VERSION}/$(basename "${IDENTITY_URL}")
STORAGENODE_ZIP=/tmp/${VERSION}/$(basename "${STORAGENODE_URL}")
STORAGENODE_UPDATER_ZIP=/tmp/${VERSION}/$(basename ${STORAGENODE_UPDATER_URL})

TARGET_BIN_DIR="/usr/local/bin"

fetch()
{
  WHAT="${1}"
  WHERE="${2}"
  CHECKSUM="${3}"

  if [ ! -f "${WHERE}" ] ; then
    echo "Downloading ${WHAT} from ${WHERE}"
    curl --remove-on-error -L "${WHAT}" -o "${WHERE}"
  fi
  if [ ! -f "${WHERE}" ] ; then
    echo "Failed to download ${WHERE} from ${WHAT}"
    exit 1
  fi

  # Verify checksum if provided
  if [ -n "${CHECKSUM}" ]; then
    echo "Verifying checksum for ${WHERE}"
    FILE_CHECKSUM=$(sha256 -q "${WHERE}")
    if [ "sha256:${FILE_CHECKSUM}" != "${CHECKSUM}" ]; then
      echo "Checksum verification failed for ${WHERE}"
      echo "Expected: ${CHECKSUM}"
      echo "Actual: ${FILE_CHECKSUM}"
      exit 1
    fi
    echo "Checksum verification successful"
  fi
}

echo "Fetching executables from the internet"
fetch "${IDENTITY_URL}" "${IDENTITY_ZIP}" "${IDENTITY_CHECKSUM}"
fetch "${STORAGENODE_URL}" "${STORAGENODE_ZIP}" "${STORAGENODE_CHECKSUM}"
fetch "${STORAGENODE_UPDATER_URL}" "${STORAGENODE_UPDATER_ZIP}" "${STORAGENODE_UPDATER_CHECKSUM}"

echo "Stopping existing services"
service storagenode stop 2>/dev/null >/dev/null
service storagenode_updater stop 2>/dev/null >/dev/null

if [ -f "/etc/newsyslog.conf.d/storj.conf" ]; then
  echo "Fond storj log rotator config in the old location. Disabling it."
  mv "/etc/newsyslog.conf.d/storj.conf" "/etc/newsyslog.conf.d/storj.conf.disabled"
fi

echo "Copying rc scripts and replacement updater"
cp -rv overlay/ /

echo "Extracting downloaded binaries to ${TARGET_BIN_DIR}"
unzip -d "${TARGET_BIN_DIR}" -o "${IDENTITY_ZIP}"
unzip -d "${TARGET_BIN_DIR}" -o "${STORAGENODE_ZIP}"
unzip -d "${TARGET_BIN_DIR}" -o "${STORAGENODE_UPDATER_ZIP}"

IDENTITY_DIR="${IDENTITY_ROOT}/storagenode"

if [ ! -f "${IDENTITY_DIR}/identity.cert" ]; then
  echo "Generating new identity for storagenode"
  if ! su -m storagenode -c "identity create storagenode --config-dir \"${CONFIG_DIR}\" --identity-dir \"${IDENTITY_ROOT}\" --concurrency $(sysctl -n hw.ncpu) --difficulty 20"; then
    echo "Error: Failed to create identity"
    exit 1
  fi
else
  echo "Existing identity found in ${IDENTITY_DIR}"
fi

echo "Verifying identity files"
if [ 1 -ne "$(grep -c BEGIN "${IDENTITY_DIR}/ca.cert")" ]; then
  echo "Bad Identity: ca.cert"
  exit 1
fi

if [ 2 -ne "$(grep -c BEGIN "${IDENTITY_DIR}/identity.cert")" ]; then
  echo "Bad Identity: identity.cert"
  exit 1
fi

CONFIG_FILE="${CONFIG_DIR}/config.yaml"
if [ ! -f "${CONFIG_FILE}" ]; then
  echo "Configuring storagenode"
  if ! su -m storagenode -c "storagenode setup --storage.path \"${STORAGE_PATH}\" --config-dir \"${CONFIG_DIR}\" --identity-dir \"${IDENTITY_DIR}\" --operator.email \"${OPERATOR_EMAIL}\" --console.address \"${CONSOLE_ADDRESS}\" --operator.wallet \"${OPERATOR_WALLET}\" --operator.wallet-features \"${OPERATOR_WALLET_FEATURES}\" --contact.external-address \"${CONTACT_EXTERNAL_ADDRESS}\" --storage.allocated-disk-space \"${STORAGE_ALLOCATED_DISK_SPACE}\" --storage2.database-dir \"${DATABASE_DIR}\""; then
    echo "Error: Failed to configure storagenode"
    exit 1
  fi
else
  echo "Storagenode setup has already been performed (config file exists), skipping node setup"
fi

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
if ! service storagenode enable; then
  echo "Error: Failed to enable storagenode service"
  exit 1
fi
if ! service storagenode_updater enable; then
  echo "Error: Failed to enable storagenode_updater service"
  exit 1
fi
if ! service newsyslog enable; then
  echo "Error: Failed to enable newsyslog service"
  exit 1
fi
if ! service netwait enable; then
  echo "Error: Failed to enable netwait service"
  exit 1
fi

echo "Starting services"
if ! service storagenode start; then
  echo "Error: Failed to start storagenode service"
  exit 1
fi
if ! service storagenode_updater start; then
  echo "Error: Failed to start storagenode_updater service"
  exit 1
fi
if ! service newsyslog start; then
  echo "Error: Failed to start newsyslog service"
  exit 1
fi
if ! service netwait start; then
  echo "Error: Failed to start netwait service"
  exit 1
fi

echo "Installation completed successfully!"
echo "Your STORJ node is now running. You can manage it using the 'service' command:"
echo "  service storagenode status"
echo "  service storagenode_updater status"
echo "Logs can be found in /var/log/storagenode.log and /var/log/storagenode_updater.log"
