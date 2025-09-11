#!/bin/sh
set -eu

# --- Configuration (edit these) ---
CONTACT_EXTERNAL_ADDRESS="example.com:28967"
OPERATOR_EMAIL="user@example.com"
OPERATOR_WALLET="0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
OPERATOR_WALLET_FEATURES=""

STORAGE_PATH="/mnt/storagenode"
DATABASE_DIR="/mnt/storagenode"
NETWAIT_IP="1.1.1.1"
CONSOLE_ADDRESS=":14002"
STORAGE_ALLOCATED_DISK_SPACE="1.00 TB"

# --- Helpers ---
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo ">>> $*"; }

# --- Parameter sanity ---
[ "$OPERATOR_EMAIL" != "user@example.com" ] || \
    die "Edit this script and set CONTACT_EXTERNAL_ADDRESS, OPERATOR_EMAIL, OPERATOR_WALLET, STORAGE_PATH"

[ "$(id -u)" -eq 0 ] || \
    die "This script must be run as root"

[ -w "$STORAGE_PATH" ] || die "Storage path $STORAGE_PATH is not writable"

TEST_FILE="${STORAGE_PATH}/.storage_test"
touch "$TEST_FILE" || die "Cannot create files in $STORAGE_PATH"
rm -f "$TEST_FILE"

IDENTITY_ROOT="${STORAGE_PATH}/identity"
CONFIG_DIR="${STORAGE_PATH}/config"
mkdir -p "$CONFIG_DIR" "$IDENTITY_ROOT" || die "Failed to create config/identity dirs"

# --- Dependencies ---
for dep in jq curl unzip; do
    command -v $dep >/dev/null 2>&1 || pkg install -y $dep || die "Failed to install $dep"
done

# --- User/group ---
pw groupshow storagenode >/dev/null 2>&1 || pw groupadd -n storagenode
pw usershow storagenode >/dev/null 2>&1 || pw useradd -n storagenode -g storagenode -s /usr/sbin/nologin -h -

chown -R storagenode:storagenode "$STORAGE_PATH" "$DATABASE_DIR"

# --- Version discovery ---
VERSION_CHECK_URL="https://version.storj.io"
SUGGESTION=$(curl -fsSL "$VERSION_CHECK_URL" | jq -r '.processes.storagenode.suggested')
VERSION=$(echo "$SUGGESTION" | jq -r '.version') || die "Failed to parse version"
[ -n "$VERSION" ] || die "Empty version string"

STORAGENODE_URL=$(echo "$SUGGESTION" | jq -r '.url' | sed "s/{arch}/amd64/; s/{os}/freebsd/")
STORAGENODE_UPDATER_URL="https://github.com/storj/storj/releases/download/v${VERSION}/storagenode-updater_freebsd_amd64.zip"
IDENTITY_URL="https://github.com/storj/storj/releases/download/v${VERSION}/identity_freebsd_amd64.zip"

[ -n "$STORAGENODE_URL" ] || die "Failed to derive storagenode URL"

GH_API_URL="https://api.github.com/repos/storj/storj/releases/latest"
GH_DATA=$(curl -fsSL "$GH_API_URL")

get_digest() {
    echo "$GH_DATA" | jq -r --arg url "$(basename $1)" '.assets[] | select(.name == $url) | .digest'
}
STORAGENODE_CHECKSUM=$(get_digest "$STORAGENODE_URL")
STORAGENODE_UPDATER_CHECKSUM=$(get_digest "$STORAGENODE_UPDATER_URL")
IDENTITY_CHECKSUM=$(get_digest "$IDENTITY_URL")

TMPDIR="/tmp/${VERSION}"
mkdir -p "$TMPDIR"

IDENTITY_ZIP="$TMPDIR/$(basename "$IDENTITY_URL")"
STORAGENODE_ZIP="$TMPDIR/$(basename "$STORAGENODE_URL")"
STORAGENODE_UPDATER_ZIP="$TMPDIR/$(basename "$STORAGENODE_UPDATER_URL")"

fetch_file() {
    url=$1 dest=$2 checksum=$3
    [ -f "$dest" ] || curl -fL --retry 3 --connect-timeout 15 -o "$dest" "$url" || die "Download failed: $url"
    [ -n "$checksum" ] || return
    echo "Verifying $dest"
    [ "sha256:$(sha256 -q "$dest")" = "$checksum" ] || die "Checksum mismatch for $dest"
}
fetch_file "$IDENTITY_URL" "$IDENTITY_ZIP" "$IDENTITY_CHECKSUM"
fetch_file "$STORAGENODE_URL" "$STORAGENODE_ZIP" "$STORAGENODE_CHECKSUM"
fetch_file "$STORAGENODE_UPDATER_URL" "$STORAGENODE_UPDATER_ZIP" "$STORAGENODE_UPDATER_CHECKSUM"

# --- Stop old services ---
service storagenode stop >/dev/null 2>&1 || true
service storagenode_updater stop >/dev/null 2>&1 || true

# --- Deploy binaries ---
TARGET_BIN_DIR="/usr/local/bin"
unzip -o -d "$TARGET_BIN_DIR" "$IDENTITY_ZIP"
unzip -o -d "$TARGET_BIN_DIR" "$STORAGENODE_ZIP"
unzip -o -d "$TARGET_BIN_DIR" "$STORAGENODE_UPDATER_ZIP"

# --- Identity ---
IDENTITY_DIR="${IDENTITY_ROOT}/storagenode"
if [ ! -f "$IDENTITY_DIR/identity.cert" ]; then
    su -m storagenode -c "identity create storagenode \
        --config-dir \"$CONFIG_DIR\" \
        --identity-dir \"$IDENTITY_ROOT\" \
        --concurrency $(sysctl -n hw.ncpu)" || die "Identity creation failed"
fi

grep -q "BEGIN" "$IDENTITY_DIR/ca.cert" || die "Invalid ca.cert"
[ "$(grep -c BEGIN "$IDENTITY_DIR/identity.cert")" -eq 2 ] || die "Invalid identity.cert"

# --- Config ---
CONFIG_FILE="$CONFIG_DIR/config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    su -m storagenode -c "storagenode setup \
        --storage.path \"$STORAGE_PATH\" \
        --config-dir \"$CONFIG_DIR\" \
        --identity-dir \"$IDENTITY_DIR\" \
        --operator.email \"$OPERATOR_EMAIL\" \
        --console.address \"$CONSOLE_ADDRESS\" \
        --operator.wallet \"$OPERATOR_WALLET\" \
        --operator.wallet-features \"$OPERATOR_WALLET_FEATURES\" \
        --contact.external-address \"$CONTACT_EXTERNAL_ADDRESS\" \
        --storage.allocated-disk-space \"$STORAGE_ALLOCATED_DISK_SPACE\" \
        --storage2.database-dir \"$DATABASE_DIR\"" || die "Node setup failed"
fi

# --- rc.d configuration ---
sysrc netwait_ip="$NETWAIT_IP"
sysrc storagenode_identity_dir="$IDENTITY_DIR"
sysrc storagenode_config_dir="$CONFIG_DIR"
sysrc storagenode_storage_path="$STORAGE_PATH"
sysrc storagenode_updater_config_dir="$CONFIG_DIR"
sysrc storagenode_updater_identity_dir="$IDENTITY_DIR"

# --- Enable + start services ---
for svc in storagenode storagenode_updater newsyslog netwait; do
    sysrc "${svc}_enable=YES"
    service "$svc" restart || die "Failed to start $svc"
done

log "Installation completed successfully."
log "Check services with:"
log "  service storagenode status"
log "  service storagenode_updater status"
