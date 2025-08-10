#!/bin/bash

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

# Resolve this script directory and compute LUCEE_ROOT and UPG_DIR
SOURCE="${BASH_SOURCE[0]:-$0}"
while [ -L "$SOURCE" ]; do
	DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
	LINK="$(readlink "$SOURCE")"
	if [[ "$LINK" != /* ]]; then
		SOURCE="$DIR/$LINK"
	else
		SOURCE="$LINK"
	fi
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
LUCEE_ROOT="$("$SCRIPT_DIR/get-lucee-root.sh")"
UPG_DIR="${LUCEE_ROOT}/sys/upgrade-in-progress"

# preflight: ensure detect include exists at the deployed UPG_DIR
DETECT_CONF="${UPG_DIR}/lucee-detect-upgrade.conf"
if [ ! -f "$DETECT_CONF" ]; then
	echo "Error: Required file not found: $DETECT_CONF"
	echo "Upgrade mode cannot be enabled safely without this include."
	echo "Ensure the upgrade-in-progress package is deployed to $UPG_DIR and try again."
	exit 1
fi

# prep cPanel flag
if [ -f "/usr/local/cpanel/cpanel" ]; then
	IS_CPANEL=true
else
	IS_CPANEL=false
fi

# The flag file is referenced by cron jobs, etc, to abort during 
# Lucee upgrade (just before or after Lucee is stopped).
# It is not used by Apache because Define on Apache start/reload
# is more efficient than checking for the file's existence on every request.
touch /var/lucee-upgrade-in-progress

# Debian/Ubuntu/etc
if command -v a2enconf >/dev/null 2>&1; then
	echo "Enabling lucee-upgrade-in-progress configuration..."
	a2enconf lucee-upgrade-in-progress >/dev/null
	echo "Disabling lucee-ajp-and-mod_cfml configuration..."
	a2disconf lucee-ajp-and-mod_cfml >/dev/null
	echo "Reloading Apache..."
	systemctl reload apache2

# Redhat/CentOS/AlmaLinux/etc
elif [ -d /etc/httpd/conf.d ]; then
	if [ "$IS_CPANEL" = true ]; then
		cd /etc/apache2/conf.d || exit 1
	else
		cd /etc/httpd/conf.d || exit 1
	fi
	echo "Enabling lucee-upgrade-in-progress configuration..."
	mv -f lucee-upgrade-in-progress.disabled lucee-upgrade-in-progress.conf
	echo "Disabling lucee-ajp-and-mod_cfml configuration..."
	mv -f lucee-ajp-and-mod_cfml.conf lucee-ajp-and-mod_cfml.conf.disabled
	if [ "$IS_CPANEL" = true ]; then
		echo "Rebuilding httpd configuration..."
		/scripts/rebuildhttpdconf
		echo "Gracefully restarting httpd..."
		/scripts/restartsrv_httpd --graceful
	else
		echo "Reloading httpd..."
		systemctl reload httpd
	fi

else
	echo "Unsupported environment (neither a2enconf nor /etc/httpd/conf.d detected)"
	exit 1
fi

echo "DONE!"
