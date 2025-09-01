# FreeBSD STORJ Node Installer

This script automates the installation and configuration of a STORJ storage node on FreeBSD. It has been tested in a 13.1-RELEASE jail on TrueNAS 13.1.

## Configuration

Before running the script, edit the top of `install.sh` to specify your parameters:

- `CONTACT_EXTERNAL_ADDRESS` - External FQDN and port your node will be accessible at (e.g., `example.com:28967`)
- `OPERATOR_EMAIL` - Your email address for node management
- `OPERATOR_WALLET` - Your STORJ wallet address (e.g., `0x...`)
- `OPERATOR_WALLET_FEATURES` - Wallet features (see STORJ documentation)
- `STORAGE_PATH` - Path where storage will be mounted (must be writable)
- `NETWAIT_IP` - IP address for network connectivity testing (default: `1.1.1.1`)
- `CONSOLE_ADDRESS` - Optional interface and port for console (default: `:14002`)
- `STORAGE_ALLOCATED_DISK_SPACE` - Amount of disk space to allocate (default: `1.00 TB`)

## Installation

1. Clone the repository:
   ```sh
   git clone https://github.com/your-repo/freebsd-storj-installer.git
   cd freebsd-storj-installer
   ```

2. Edit `install.sh` to set your configuration parameters

3. Run the installation script as root:
   ```sh
   sudo ./install.sh
   ```

## What the Script Does

The installation script performs the following steps:

1. Checks that required parameters are set and storage path is writable
2. Installs `jq`, `curl`, and `unzip` 
3. Creates the `storagenode` user and group if they don't exist
4. Determines the latest suggested version from STORJ's version API
5. Downloads and verifies checksums for STORJ binaries from GitHub
6. Copies RC scripts and configures FreeBSD services
7. Generates node identity if needed
8. Configures the storagenode with your parameters
9. Enables and starts the storagenode and updater services

## Service Management

After installation, you can manage the services using FreeBSD's `service` utility:

- Check status: `sudo service storagenode status`
- Start service: `sudo service storagenode start`
- Stop service: `sudo service storagenode stop`
- Restart service: `sudo service storagenode restart`

Similarly, for the updater:
- `sudo service storagenode_updater {start|stop|restart|status}`

## Security Notes

- The script includes checksum verification for downloaded binaries to prevent tampering
- Services run with appropriate permissions (storagenode as user `storagenode`, updater as root)

## Known Issues

- As of today, storagenode updater does not know how to restart the service on freebsd: 
See https://github.com/storj/storj/issues/5333. While it successfully updates the executable, the old one continues 
running. Until the situation changes we include a simple shell script instead of storagenode-updater that ignores input 
parameters and simply does the job
- The custom updater script uses SIGKILL as a fallback for process termination because bash does not forward SIGTERM to backgrounded process

## License

This project is licensed under the BSD 3-Clause License. See the [LICENSE](LICENSE) file for details.
