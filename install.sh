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
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: Must be run as root."
  exit 1
fi

if [ ! -w "${STORAGE_PATH}" ]; then
  echo "Error: Storage path ${STORAGE_PATH} not writable"
  exit 1
fi

# Validate that we can create files in the storage path
TEST_FILE="${STORAGE_PATH}/.storage_test"
if ! touch "${TEST_FILE}" 2>/dev/null; then
  echo "Error: Cannot create test file in storage path ${STORAGE_PATH}"
  exit 1
fi
rm -f "${TEST_FILE}"
echo "Storage path validation successful"

IDENTITY_ROOT="${STORAGE_PATH}/identity"
CONFIG_DIR="${STORAGE_PATH}/config"

mkdir -p "${CONFIG_DIR}" "${IDENTITY_ROOT}" || {
  echo "Error: Failed to create required directories"
  exit 1
}

echo "Installing required dependencies (jq, curl, unzip)"
pkg install -y jq curl unzip || {
  echo "Error: Failed to install dependencies"
  exit 1
}

echo "Ensuring storagenode user and group exist"
id -g storagenode >/dev/null 2>&1 || pw groupadd storagenode
id -u storagenode >/dev/null 2>&1 || pw useradd -n storagenode -G storagenode -s /nonexistent -h -

echo "Taking ownership of the storage and database directories"
chown -R storagenode:storagenode "${STORAGE_PATH}" || exit 1
chown -R storagenode:storagenode "${DATABASE_DIR}" || exit 1

# Version and download URLs
VERSION_CHECK_URL="https://version.storj.io"
SUGGESTION=$(curl -L "${VERSION_CHECK_URL}" 2>/dev/null | jq -r '.processes.storagenode.suggested')
VERSION=$(echo "${SUGGESTION}" | jq -r '.version')

[ -z "${VERSION}" ] && { echo "Failed to determine suggested version"; exit 1; }

echo "Suggested STORJ version: v${VERSION}"

GH_API_URL="https://api.github.com/repos/storj/storj/releases/latest"
GH_DATA=$(curl -L "${GH_API_URL}" 2>/dev/null)

STORAGENODE_URL=$(echo "${SUGGESTION}" | jq -r '.url' | sed "s/[{]arch[}]/amd64/g" | sed "s/[{]os[}]/freebsd/g")
STORAGENODE_UPDATER_URL="https://github.com/storj/storj/releases/download/v${VERSION}/storagenode-updater_freebsd_amd64.zip"
IDENTITY_URL="https://github.com/storj/storj/releases/download/v${VERSION}/identity_freebsd_amd64.zip"

STORAGENODE_CHECKSUM=$(echo "${GH_DATA}" | jq -r --arg url "$(basename ${STORAGENODE_URL})" '.assets[] | select(.name == $url) | .digest')
STORAGENODE_UPDATER_CHECKSUM=$(echo "${GH_DATA}" | jq -r --arg url "$(basename ${STORAGENODE_UPDATER_URL})" '.assets[] | select(.name == $url) | .digest')
IDENTITY_CHECKSUM=$(echo "${GH_DATA}" | jq -r --arg url "$(basename ${IDENTITY_URL})" '.assets[] | select(.name == $url) | .digest')

mkdir -p /tmp/"${VERSION}" || { echo "Error: Cannot create /tmp/${VERSION}"; exit 1; }

IDENTITY_ZIP=/tmp/${VERSION}/$(basename "${IDENTITY_URL}")
STORAGENODE_ZIP=/tmp/${VERSION}/$(basename "${STORAGENODE_URL}")
STORAGENODE_UPDATER_ZIP=/tmp/${VERSION}/$(basename ${STORAGENODE_UPDATER_URL})

TARGET_BIN_DIR="/usr/local/bin"

fetch() {
  URL="$1"
  DEST="$2"
  CHECKSUM="$3"

  if [ ! -f "${DEST}" ]; then
    echo "Downloading $(basename "$DEST")"
    curl --remove-on-error -L "$URL" -o "$DEST"
  fi
  [ ! -f "${DEST}" ] && { echo "Failed to download $URL"; exit 1; }

  if [ -n "$CHECKSUM" ]; then
    FILE_CHECKSUM=$(sha256 -q "$DEST")
    if [ "sha256:$FILE_CHECKSUM" != "$CHECKSUM" ]; then
      echo "Checksum verification failed for $DEST"
      exit 1
    fi
  fi
}

echo "Fetching executables"
fetch "${IDENTITY_URL}" "${IDENTITY_ZIP}" "${IDENTITY_CHECKSUM}"
fetch "${STORAGENODE_URL}" "${STORAGENODE_ZIP}" "${STORAGENODE_CHECKSUM}"
fetch "${STORAGENODE_UPDATER_URL}" "${STORAGENODE_UPDATER_ZIP}" "${STORAGENODE_UPDATER_CHECKSUM}"

echo "Stopping existing services"
service storagenode stop >/dev/null 2>&1 || true
service storagenode_updater stop >/dev/null 2>&1 || true

[ -f "/etc/newsyslog.conf.d/storj.conf" ] && mv "/etc/newsyslog.conf.d/storj.conf" "/etc/newsyslog.conf.d/storj.conf.disabled"

echo "Copying rc scripts overlay"
cp -rv overlay/ /

# safer install wrapper for binaries
install_bin() {
  ZIPFILE="$1"
  DESTDIR="$2"

  TMPDIR=$(mktemp -d)
  if unzip -q -d "$TMPDIR" "$ZIPFILE"; then
    echo "Installing binaries from $(basename "$ZIPFILE")"
    for f in "$TMPDIR"/*; do
      install -m 755 "$f" "$DESTDIR/"
    done
  else
    echo "Error: Failed to extract $ZIPFILE — keeping old binaries"
  fi
  rm -rf "$TMPDIR"
}

echo "Installing binaries"
install_bin "${IDENTITY_ZIP}" "${TARGET_BIN_DIR}"
install_bin "${STORAGENODE_ZIP}" "${TARGET_BIN_DIR}"
install_bin "${STORAGENODE_UPDATER_ZIP}" "${TARGET_BIN_DIR}"

IDENTITY_DIR="${IDENTITY_ROOT}/storagenode"

if [ -f "${IDENTITY_DIR}/identity.cert" ]; then
  echo "Existing identity found — preserving"
else
  echo "Generating new identity"
  su -m storagenode -c "identity create storagenode \
    --config-dir \"${CONFIG_DIR}\" \
    --identity-dir \"${IDENTITY_ROOT}\" \
    --concurrency $(sysctl -n hw.ncpu)" || {
      echo "Error: Failed to create identity"
      exit 1
  }
fi

echo "Verifying identity file"
if [ ! -f "${IDENTITY_DIR}/identity.cert" ]; then
  echo "Error: Missing identity.cert"
  exit 1
fi

CONFIG_FILE="${CONFIG_DIR}/config.yaml"
if [ ! -f "${CONFIG_FILE}" ]; then
  echo "Running storagenode setup"
  su -m storagenode -c "storagenode setup \
    --storage.path \"${STORAGE_PATH}\" \
    --config-dir \"${CONFIG_DIR}\" \
    --identity-dir \"${IDENTITY_DIR}\" \
    --operator.email \"${OPERATOR_EMAIL}\" \
    --console.address \"${CONSOLE_ADDRESS}\" \
    --operator.wallet \"${OPERATOR_WALLET}\" \
    --operator.wallet-features \"${OPERATOR_WALLET_FEATURES}\" \
    --contact.external-address \"${CONTACT_EXTERNAL_ADDRESS}\" \
    --storage.allocated-disk-space \"${STORAGE_ALLOCATED_DISK_SPACE}\" \
    --storage2.database-dir \"${DATABASE_DIR}\"" || {
      echo "Error: storagenode setup failed"
      exit 1
  }
else
  echo "Config already exists — preserving"
fi

# Configure services
sysrc netwait_ip="${NETWAIT_IP}"
sysrc storagenode_identity_dir="${IDENTITY_DIR}"
sysrc storagenode_config_dir="${CONFIG_DIR}"
sysrc storagenode_storage_path="${STORAGE_PATH}"
sysrc storagenode_updater_config_dir="${CONFIG_DIR}"
sysrc storagenode_updater_identity_dir="${IDENTITY_DIR}"

echo "Enabling services"
service storagenode enable || exit 1
service storagenode_updater enable || exit 1
service newsyslog enable || exit 1
service netwait enable || exit 1

echo "Starting services"
service storagenode start || exit 1
service storagenode_updater start || exit 1
service newsyslog start || exit 1
service netwait start || exit 1

echo "Installation completed successfully!"
