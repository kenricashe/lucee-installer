#!/bin/bash

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

# Source shared helper for LUCEE_ROOT, UPG_DIR, IS_CPANEL
SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
. "${SCRIPT_DIR}/get-env.sh"
. "${SCRIPT_DIR}/shared-functions.sh"

# preflight: ensure detect include exists at the deployed UPG_DIR
DETECT_CONF="${UPG_DIR}/lucee-detect-upgrade.conf"
if [ ! -f "$DETECT_CONF" ]; then
	echo "Error: Required file not found: $DETECT_CONF"
	echo "Upgrade mode cannot be enabled safely without this include."
	echo "Ensure the upgrade-in-progress package is deployed to $UPG_DIR and try again."
	exit 1
fi

if ! check_apache_configured; then
	echo "Error: Apache has not been configured for upgrade-in-progress."
	echo "Please run the 'Configure Apache' option from the menu first."
	exit 1
fi

# IS_CPANEL is provided by get-env.sh

# The flag file is referenced by cron jobs, etc, to abort during 
# Lucee upgrade (just before or after Lucee is stopped).
# It is not used by Apache because Define on Apache start/reload
# is more efficient than checking for the file's existence on every request.
touch /var/lucee-upgrade-in-progress

# Debian, Ubuntu, Pop!_OS, etc
if [ "$IS_DEBIAN" = true ]; then
	enable_conf lucee-upgrade-in-progress
	disable_conf lucee-proxy
	if ! apache_reload; then
		exit 1
	fi

# Fedora, Red Hat, AlmaLinux, Rocky Linux, etc
elif [ -n "$CONF_DIR" ]; then
	cd "${CONF_DIR}" || exit 1
	echo "Enabling lucee-upgrade-in-progress configuration..."
	mv -f lucee-upgrade-in-progress.disabled lucee-upgrade-in-progress.conf
	echo "Disabling lucee-proxy configuration..."
	mv -f lucee-proxy.conf lucee-proxy.conf.disabled
	if ! apache_reload; then
		exit 1
	fi

else
	echo "Unsupported environment (Debian or RedHat family required)"
	exit 1
fi

echo "DONE!"
