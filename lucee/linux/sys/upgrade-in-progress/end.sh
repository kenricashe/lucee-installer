#!/bin/bash

# Source shared helper for IS_CPANEL (LUCEE_ROOT/UPG_DIR not needed here)
SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
. "${SCRIPT_DIR}/get-env.sh"
. "${SCRIPT_DIR}/shared-functions.sh"

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

# check_apache_configured function is now in get-env.sh

# preflight: check if Apache has been configured for upgrade-in-progress
if ! check_apache_configured; then
	echo "Error: Apache has not been configured for upgrade-in-progress."
	echo "Please run the 'Configure Apache' option from the menu first."
	exit 1
fi

# Debian, Ubuntu, Pop!_OS, etc
if [ "$IS_DEBIAN" = true ]; then
	enable_conf lucee-proxy
	disable_conf lucee-upgrade-in-progress
	if ! apache_reload; then
		echo "ERROR: Apache reload failed."
		exit 1
	fi

# Fedora, Red Hat, AlmaLinux, Rocky Linux, etc
elif [ -n "$CONF_DIR" ]; then
	cd "${CONF_DIR}" || exit 1
	echo "Enabling lucee-proxy configuration..."
	mv -f lucee-proxy.conf.disabled lucee-proxy.conf
	echo "Disabling lucee-upgrade-in-progress configuration..."
	mv -f lucee-upgrade-in-progress.conf lucee-upgrade-in-progress.disabled
	if ! apache_reload; then
		exit 1
	fi
else
	echo "Unsupported environment (Debian or RedHat family required)"
	exit 1
fi

rm -f /var/lucee-upgrade-in-progress

echo "DONE!"
