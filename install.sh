#!/bin/sh

# version of storj to download
VERSION="v1.58.2"

# Identity token <email:hash>
IDENTITY_AUTH_TOKEN="CHANGE_ME"
# External address and port, setup port forwarding as needed
CONTACT_EXTERNAL_ADDRESS="example.com:28968"
# operator email address
OPERATOR_EMAIL="user@example.com"
# Wallet
OPERATOR_WALLET="0x0eC33087AFfed2924aB01579abc2c471BC6Da13C"
OPERATOR_WALLET_FEATURES=""
# Location where the store will be initialized.
STORAGE_PATH="/mnt/storj"
# ip to ping for network connectivity test
NETWAIT_IP=10.0.17.1
# Where to run console
CONSOLE_ADDRESS=":14002"

if [ "$IDENTITY_AUTH_TOKEN" == "CHANGE_ME" ]; then
	echo "Edit the script and specify required parameters:"
	echo "IDENTITY_AUTH_TOKEN, CONTACT_EXTERNAL_ADDRESS, OPERATOR_EMAIL, OPERATOR_WALLET, STORAGE_PATH"
	exit 1
fi

# Prerequisities

pkg install -y jq curl

# NOTE on storagenode-updater. As of today, storagenode updater does not know how to restart the service on freebsd. While it successfuly updates the executable it continues running the old one.
# Until the situation changes we include a simple shell script instead of storage node updater that ignores input parameters and simply does the job.


HOME="/root"

IDENTITY_CONFIG_DIR="${HOME}/.local/share/storj/identity"
IDENTITY_IDENTITY_DIR="${HOME}/.local/share/storj/identity"
STORAGNODE_CONFIG_DIR="${HOME}/.local/share/storj/storagenode"
STORAGNODE_IDENTITY_DIR="${HOME}/.local/share/storj/identity/storagenode"

STORAGENODE_URL="https://github.com/storj/storj/releases/download/${VERSION}/storagenode_freebsd_amd64.zip"

#STORAGENODE_UPDATER_URL="https://github.com/storj/storj/releases/download/${VERSION}/storagenode-updater_freebsd_amd64.zip"
IDENTITY_URL="https://github.com/storj/storj/releases/download/${VERSION}/identity_freebsd_amd64.zip"

mkdir -p /tmp/${VERSION}

IDENTITY_ZIP=/tmp/${VERSION}/$(basename ${IDENTITY_URL})
STORAGENODE_ZIP=/tmp/${VERSION}/$(basename ${STORAGENODE_URL})
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

echo "Extracting binaries to ${TARGET_BIN_DIR}"

unzip -d "${TARGET_BIN_DIR}" -o "${IDENTITY_ZIP}" 
unzip -d "${TARGET_BIN_DIR}" -o "${STORAGENODE_ZIP}" 
#unzip -d "${TARGET_BIN_DIR}" -o "${STORAGENODE_UPDATER_ZIP}" 


if [ ! -f "${STORAGNODE_IDENTITY_DIR}/identity.cert" ]; then
	identity create storagenode --config-dir "${IDENTITY_CONFIG_DIR}" --identity-dir "${IDENTITY_IDENTITY_DIR}"
	
else
	echo "Identity found in ${STORAGNODE_IDENTITY_DIR}"
fi

if [ "0" == "$(find /root/.local/share/storj/identity/storagenode -name "identity.*.cert" | wc -l)" ]; then 
	echo "Authorizing the storage node with identity ${IDENTITY_AUTH_TOKEN}"
	identity authorize storagenode "${IDENTITY_AUTH_TOKEN}"
else
	echo "Identity is authorized for at least one token. Authorization skipped"
fi

if [ "2" != "$(grep -c BEGIN ${HOME}/.local/share/storj/identity/storagenode/ca.cert)" ]; then 
		echo "Bad Identity"
		exit 1
fi

if [ "3" != "$(grep -c BEGIN ${HOME}/.local/share/storj/identity/storagenode/identity.cert)" ]; then
                echo "Bad Identity"
                exit 1
fi

if [ ! -f "${HOME}/.local/share/storj/storagenode/config.yaml" ]; then 
	storagenode setup --storage.path "$STORAGE_PATH"
fi


echo "Configuring netwait to wait for ${NETWAIT_IP}"
sysrc netwait_ip="${NETWAIT_IP}"

echo "Configuring storj"
sysrc storj_console_address="${CONSOLE_ADDRESS}"
sysrc storj_operator_email="${OPERATOR_EMAIL}"
sysrc storj_operator_wallet="${OPERATOR_WALLET}"
sysrc storj_operator_wallet_features="${OPERATOR_WALLET_FEATURES}"
sysrc storj_storage_path="${STORAGE_PATH}"
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
