#!/bin/bash

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

# Source shared helper for LUCEE_ROOT, UPG_DIR, IS_CPANEL
SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
. "${SCRIPT_DIR}/get-env.sh"

# preflight: ensure detect include exists at the deployed UPG_DIR
DETECT_CONF="${UPG_DIR}/lucee-detect-upgrade.conf"
if [ ! -f "$DETECT_CONF" ]; then
	echo "Error: Required file not found: $DETECT_CONF"
	echo "Upgrade mode cannot be enabled safely without this include."
	echo "Ensure the upgrade-in-progress package is deployed to $UPG_DIR and try again."
	exit 1
fi

# IS_CPANEL is provided by get-env.sh

# The flag file is referenced by cron jobs, etc, to abort during 
# Lucee upgrade (just before or after Lucee is stopped).
# It is not used by Apache because Define on Apache start/reload
# is more efficient than checking for the file's existence on every request.
touch /var/lucee-upgrade-in-progress

# Debian, Ubuntu, Pop!_OS, etc
if command -v a2enconf >/dev/null 2>&1; then
	echo "Enabling lucee-upgrade-in-progress configuration..."
	a2enconf lucee-upgrade-in-progress >/dev/null
	echo "Disabling lucee-proxy configuration..."
	a2disconf lucee-proxy >/dev/null
	echo "Reloading Apache..."
	if ! apache_reload; then
		exit 1
	fi

# Fedora, Red Hat, AlmaLinux, Rocky Linux, etc
elif [ -d /etc/httpd/conf.d ]; then
	if [ "$IS_CPANEL" = true ]; then
		cd /etc/apache2/conf.d || exit 1
	else
		cd /etc/httpd/conf.d || exit 1
	fi
	echo "Enabling lucee-upgrade-in-progress configuration..."
	mv -f lucee-upgrade-in-progress.disabled lucee-upgrade-in-progress.conf
	echo "Disabling lucee-proxy configuration..."
	mv -f lucee-proxy.conf lucee-proxy.conf.disabled
	if ! apache_reload; then
		exit 1
	fi

else
	echo "Unsupported environment (neither a2enconf nor /etc/httpd/conf.d detected)"
	exit 1
fi

echo "DONE!"
