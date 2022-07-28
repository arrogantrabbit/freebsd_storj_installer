This is a simple script to download and configure STORJ as a service in FreeBSD. Tested in a 13.1-RELEASE jail on TrueNAS 13.1.


To use: clone the repo, edit the top of the install.sh to specify your data:

- `IDENTITY_AUTH_TOKEN` -- auth token from https://www.storj.io/host-a-node
- `CONTACT_EXTERNAL_ADDRESS` -- external FQDN and port your node will be accessible at. Configure port forwarding accordingly as needed.
- `OPERATOR_EMAIL` -- change to your email.
- `OPERATOR_WALLET` -- change to your wallet.
- `OPERATOR_WALLET_FEATURES` -- wallet features. See STORJ documentation.
- `STORAGE_PATH` -- path where the storage is mounted.
- `NETWAIT_IP` -- IP address of a host to be used for network connectivity testing.
- `CONSOLE_ADDRESS` -- optional interface and port where to run console. Omitting inteface address will listen on all interfaces.
- `VERSION` -- which version of storagenode to download from https://github.com/storj/storj/releases

Then run the install script. 

The script will initialize the identity, authorize it with the token, and init storage. 

Then it will create two rc services: `storj` and `storjupd`. The former one is storagenode, the latter one is updater.

Use `service` utility to control them. For example, `service storj start` or `service storj status`



