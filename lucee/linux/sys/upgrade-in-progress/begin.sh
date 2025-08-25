#!/bin/bash

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

# Source shared helper# Source environment variables and functions
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "${SCRIPT_DIR}/ENVIRONMENT.sh"
. "${SCRIPT_DIR}/shared-functions.sh"

# Helper function to check if SELinux is enabled
selinux_enabled() {
	if command -v getenforce >/dev/null 2>&1; then
		mode=$(getenforce 2>/dev/null)
		if [ "$mode" != "Disabled" ]; then
			return 0
		fi
	fi
	return 1
}

# Helper function to check and fix SELinux context for Apache config files
check_and_fix_selinux_context() {
	local file="$1"
	
	if ! selinux_enabled; then
		return 0
	fi
	
	if [ ! -f "$file" ]; then
		return 1
	fi
	
	echo "Checking SELinux context for $file"
	
	if command -v restorecon >/dev/null 2>&1; then
		# Suppress verbose output
		restorecon "$file" >/dev/null 2>&1 || {
			echo "Warning: restorecon failed, trying chcon fallback"
			if command -v chcon >/dev/null 2>&1; then
				chcon -t httpd_config_t "$file" >/dev/null 2>&1 || \
				echo "Warning: Failed to set SELinux context on $file"
			fi
		}
	elif command -v chcon >/dev/null 2>&1; then
		chcon -t httpd_config_t "$file" >/dev/null 2>&1 || \
		echo "Warning: Failed to set SELinux context on $file"
	else
		echo "Warning: SELinux is enabled but neither restorecon nor chcon commands are available."
		echo "Apache may not be able to read config files due to SELinux restrictions."
		return 1
	fi
	
	return 0
}

# preflight: check if Apache has been configured for upgrade-in-progress
if ! check_apache_configured; then
	echo "Error: Apache has not been configured for upgrade-in-progress."
	echo "Please run the 'Configure Apache' option from the menu first."
	exit 1
fi

# preflight: ensure detect include exists at the deployed UPG_DIR
DETECT_CONF="${UPG_DIR}/lucee-detect-upgrade.conf"
if [ ! -f "$DETECT_CONF" ]; then
	echo "Error: Required file not found: $DETECT_CONF"
	echo "Upgrade mode cannot be enabled safely without this include."
	echo "Ensure the upgrade-in-progress package is deployed to $UPG_DIR and try again."
	exit 1
fi

# Check for required include files and fix SELinux contexts if needed
REQUIRED_FILES=(
	"$UPG_DIR/ip-allow.conf"
	"$UPG_DIR/lucee-proxy-for-allowed-ip.conf"
)

MISSING_FILES=0
for file in "${REQUIRED_FILES[@]}"; do
	if [ ! -f "$file" ]; then
		echo "Error: Required file $file does not exist."
		MISSING_FILES=1
		continue
	fi
	
	# Check file permissions
	if [ "$(stat -c %a "$file" 2>/dev/null)" != "644" ]; then
		echo "Warning: File $file does not have 644 permissions. Fixing..."
		chmod 644 "$file"
	fi
	
	# Check and fix SELinux context if needed
	check_and_fix_selinux_context "$file"
done

if [ $MISSING_FILES -eq 1 ]; then
	echo "Error: One or more required files are missing."
	echo "You may need to run menu.sh to create ip-allow.conf and configure-apache.sh to create lucee-proxy-for-allowed-ip.conf"
	exit 1
fi

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
