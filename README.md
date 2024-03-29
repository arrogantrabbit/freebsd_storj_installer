This is a simple script to download and configure STORJ as a service in FreeBSD. Tested in a 13.1-RELEASE jail on 
TrueNAS 13.1.

To use: clone the repo, edit the top of the install.sh to specify your data:

- `IDENTITY_AUTH_TOKEN` -- auth token from https://www.storj.io/host-a-node
- `CONTACT_EXTERNAL_ADDRESS` -- external FQDN and port your node will be accessible at. Configure port forwarding accordingly as needed.
- `OPERATOR_EMAIL` -- change to your email.
- `OPERATOR_WALLET` -- change to your wallet.
- `OPERATOR_WALLET_FEATURES` -- wallet features. See STORJ documentation.
- `STORAGE_PATH` -- path where the storage is mounted.
- `NETWAIT_IP` -- IP address of a host to be used for network connectivity testing.
- `CONSOLE_ADDRESS` -- optional interface and port where to run console. Omitting inteface address will listen on all interfaces.

Then run the "install" script. 

The script will perform the following: 

- determine the suggested version of storage node as defined by https://version.storj.io, download, and install the executables.
- create the `storagenode` local user
- initialize the identity, authorize it with the token, and init storage. 
- create and start two rc services: `storagenode` and `storagenode_updater`. The former one is storagenode, runs  as user "storagenode", the latter one is updater, runs as root.

Use `service` utility to control them. For example, `service storagenode start` or `service storagenode status`

Note on storagenode-updater: As of today, storagenode updater does not know how to restart the service on freebsd: 
See https://github.com/storj/storj/issues/5333. While it successfully updates the executable, the old one continues 
running. Until the situation changes we include a simple shell script instead of storagenode-updater that ignores input 
parameters and simply does the job.

