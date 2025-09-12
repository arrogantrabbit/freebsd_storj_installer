#!/bin/sh

# ======== CONFIGURATION ========
CONTACT_EXTERNAL_ADDRESS="example.com:28967"
OPERATOR_EMAIL="user@example.com"
OPERATOR_WALLET="0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
OPERATOR_WALLET_FEATURES=""
STORAGE_PATH="/mnt/storagenode"
DATABASE_DIR="/mnt/storagenode"
NETWAIT_IP="1.1.1.1"
CONSOLE_ADDRESS=":14002"
STORAGE_ALLOCATED_DISK_SPACE="1.00 TB"
# =================================

die() {
  echo "Error: $*" >&2
  exit 1
}

# --- sanity checks ---
[ "$OPERATOR_EMAIL" = "user@example.com" ] && die "Required configuration parameters not set. Refer to README.md."
[ "$(id -u)" -eq 0 ] || die "Must be run as root"
[ -w "${STORAGE_PATH}" ] || die "Storage path ${STORAGE_PATH} not writable"

TEST_FILE="${STORAGE_PATH}/.storage_test"
touch "${TEST_FILE}" 2>/dev/null || die "Cannot create test file in ${STORAGE_PATH}"
rm -f "${TEST_FILE}"
echo "Storage path validation successful"

IDENTITY_ROOT="${STORAGE_PATH}/identity"
CONFIG_DIR="${STORAGE_PATH}/config"
BLOBS_DIR="${STORAGE_PATH}/blobs"

mkdir -p "${CONFIG_DIR}" "${IDENTITY_ROOT}" || die "Failed to create required directories"

# --- dependencies ---
echo "Installing required dependencies (jq, curl, unzip)"
pkg install -y jq curl unzip || die "Failed to install dependencies"

# --- system user ---
echo "Ensuring storagenode user and group exist"
id -g storagenode >/dev/null 2>&1 || pw groupadd storagenode
id -u storagenode >/dev/null 2>&1 || pw useradd -n storagenode -G storagenode -s /nonexistent -h -

echo "Taking ownership of storage and database directories"
chown -R storagenode:storagenode "${STORAGE_PATH}" "${DATABASE_DIR}" || die "Failed to chown storage dirs"

# --- version discovery ---
VERSION_CHECK_URL="https://version.storj.io"
SUGGESTION=$(curl -L "${VERSION_CHECK_URL}" 2>/dev/null | jq -r '.processes.storagenode.suggested')
VERSION=$(echo "${SUGGESTION}" | jq -r '.version')
[ -z "${VERSION}" ] && die "Failed to determine suggested version"

echo "Suggested STORJ version: v${VERSION}"

GH_API_URL="https://api.github.com/repos/storj/storj/releases/latest"
GH_DATA=$(curl -L "${GH_API_URL}" 2>/dev/null)

STORAGENODE_URL=$(echo "${SUGGESTION}" | jq -r '.url' | sed "s/[{]arch[}]/amd64/g" | sed "s/[{]os[}]/freebsd/g")
STORAGENODE_UPDATER_URL="https://github.com/storj/storj/releases/download/v${VERSION}/storagenode-updater_freebsd_amd64.zip"
IDENTITY_URL="https://github.com/storj/storj/releases/download/v${VERSION}/identity_freebsd_amd64.zip"

STORAGENODE_CHECKSUM=$(echo "${GH_DATA}" | jq -r --arg url "$(basename ${STORAGENODE_URL})" '.assets[] | select(.name == $url) | .digest')
STORAGENODE_UPDATER_CHECKSUM=$(echo "${GH_DATA}" | jq -r --arg url "$(basename ${STORAGENODE_UPDATER_URL})" '.assets[] | select(.name == $url) | .digest')
IDENTITY_CHECKSUM=$(echo "${GH_DATA}" | jq -r --arg url "$(basename ${IDENTITY_URL})" '.assets[] | select(.name == $url) | .digest')

mkdir -p /tmp/"${VERSION}" || die "Cannot create /tmp/${VERSION}"
IDENTITY_ZIP=/tmp/${VERSION}/$(basename "${IDENTITY_URL}")
STORAGENODE_ZIP=/tmp/${VERSION}/$(basename "${STORAGENODE_URL}")
STORAGENODE_UPDATER_ZIP=/tmp/${VERSION}/$(basename ${STORAGENODE_UPDATER_URL})

# --- fetch helper ---
fetch() {
  URL="$1"
  DEST="$2"
  CHECKSUM="$3"

  if [ ! -f "${DEST}" ]; then
    echo "Downloading $(basename "$DEST")"
    curl --remove-on-error -L "$URL" -o "$DEST" || die "Failed to download $URL"
  fi

  if [ -n "$CHECKSUM" ]; then
    FILE_CHECKSUM=$(sha256 -q "$DEST")
    [ "sha256:$FILE_CHECKSUM" = "$CHECKSUM" ] || die "Checksum mismatch for $(basename "$DEST")"
  fi
}

echo "Fetching executables"
fetch "${IDENTITY_URL}" "${IDENTITY_ZIP}" "${IDENTITY_CHECKSUM}"
fetch "${STORAGENODE_URL}" "${STORAGENODE_ZIP}" "${STORAGENODE_CHECKSUM}"
fetch "${STORAGENODE_UPDATER_URL}" "${STORAGENODE_UPDATER_ZIP}" "${STORAGENODE_UPDATER_CHECKSUM}"

# --- stop services ---
echo "Stopping existing services"
for svc in storagenode storagenode_updater; do
  service "$svc" stop >/dev/null 2>&1 || true
done

[ -f "/etc/newsyslog.conf.d/storj.conf" ] && mv "/etc/newsyslog.conf.d/storj.conf" "/etc/newsyslog.conf.d/storj.conf.disabled"

echo "Copying rc scripts overlay"
cp -rv overlay/ /

# --- binary install with backup ---
install_bin() {
  ZIPFILE="$1"
  DESTDIR="$2"
  TMPDIR=$(mktemp -d)

  if unzip -q -d "$TMPDIR" "$ZIPFILE"; then
    echo "Installing binaries from $(basename "$ZIPFILE")"
    for f in "$TMPDIR"/*; do
      base=$(basename "$f")
      target="$DESTDIR/$base"
      if [ -f "$target" ]; then
        n=1
        while [ -f "$target.bak.$n" ]; do
          n=$((n+1))
        done
        echo "Backing up existing $base to $target.bak.$n"
        cp "$target" "$target.bak.$n" || die "Failed to backup $target"
      fi
      install -m 755 "$f" "$target" || die "Failed to install $f"
    done
  else
    echo "Warning: Failed to extract $ZIPFILE — keeping old binaries"
  fi
  rm -rf "$TMPDIR"
}

echo "Installing binaries"
install_bin "${IDENTITY_ZIP}" "/usr/local/bin"
install_bin "${STORAGENODE_ZIP}" "/usr/local/bin"
install_bin "${STORAGENODE_UPDATER_ZIP}" "/usr/local/bin"

# --- identity ---
IDENTITY_DIR="${IDENTITY_ROOT}/storagenode"
if [ -f "${IDENTITY_DIR}/identity.cert" ]; then
  echo "Existing identity found — preserving"
else
  echo "Generating new identity"
  su -m storagenode -c "identity create storagenode \
    --config-dir \"${CONFIG_DIR}\" \
    --identity-dir \"${IDENTITY_ROOT}\" \
    --concurrency $(sysctl -n hw.ncpu)" || die "Failed to create identity"
fi

[ -f "${IDENTITY_DIR}/identity.cert" ] || die "Missing identity.cert after setup"

# --- config ---
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
    --storage2.database-dir \"${DATABASE_DIR}\"" || die "storagenode setup failed"
else
  echo "Config already exists — preserving"
fi

# --- rc.conf ---
sysrc netwait_ip="${NETWAIT_IP}"
sysrc storagenode_identity_dir="${IDENTITY_DIR}"
sysrc storagenode_config_dir="${CONFIG_DIR}"
sysrc storagenode_storage_path="${STORAGE_PATH}"
sysrc storagenode_updater_config_dir="${CONFIG_DIR}"
sysrc storagenode_updater_identity_dir="${IDENTITY_DIR}"

# --- services ---
SERVICES="storagenode storagenode_updater newsyslog netwait"

echo "Enabling services"
for svc in $SERVICES; do
  service "$svc" enable || die "Failed to enable $svc"
done

echo "Starting services"
for svc in $SERVICES; do
  service "$svc" start || die "Failed to start $svc"
done

echo "Installation completed successfully!"
