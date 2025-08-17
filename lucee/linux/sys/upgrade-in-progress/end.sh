#!/bin/bash

# Source shared helper for IS_CPANEL (LUCEE_ROOT/UPG_DIR not needed here)
SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
. "${SCRIPT_DIR}/get-env.sh"

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

# Debian, Ubuntu, Pop!_OS, etc
if command -v a2enconf >/dev/null 2>&1; then
	echo "Enabling lucee-proxy configuration..."
	a2enconf lucee-proxy >/dev/null
	echo "Disabling lucee-upgrade-in-progress configuration..."
	a2disconf lucee-upgrade-in-progress >/dev/null
	echo "Reloading Apache..."
	if ! apache_reload; then
		echo "ERROR: Apache reload failed."
		exit 1
	fi

# Fedora, Red Hat, AlmaLinux, Rocky Linux, etc
elif [ -d /etc/httpd/conf.d ]; then
	if [ "$IS_CPANEL" = true ]; then
		cd /etc/apache2/conf.d || exit 1
	else
		cd /etc/httpd/conf.d || exit 1
	fi
	echo "Enabling lucee-proxy configuration..."
	mv -f lucee-proxy.conf.disabled lucee-proxy.conf
	echo "Disabling lucee-upgrade-in-progress configuration..."
	mv -f lucee-upgrade-in-progress.conf lucee-upgrade-in-progress.disabled
	if ! apache_reload; then
		exit 1
	fi
else
	echo "Unsupported environment (neither a2enconf nor /etc/httpd/conf.d detected)"
	exit 1
fi

rm -f /var/lucee-upgrade-in-progress

echo "DONE!"
