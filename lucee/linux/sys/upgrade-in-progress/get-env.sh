#!/bin/bash

# Shared environment for upgrade-in-progress scripts
# Sets LUCEE_ROOT, UPG_DIR (relative to this file), and IS_CPANEL.

if command -v a2enconf >/dev/null 2>&1; then
	IS_DEBIAN=true
else
	IS_DEBIAN=false
fi

# Detect conf.d if any
if [ -d /etc/httpd/conf.d ]; then
	CONF_DIR="/etc/httpd/conf.d"
elif [ -d /etc/apache2/conf.d ]; then
	CONF_DIR="/etc/apache2/conf.d"
else
	CONF_DIR=""
fi

# Abort if unsupported environment
if [ "$IS_DEBIAN" = false ] && [ -z "$CONF_DIR" ]; then
	echo "ERROR: Unsupported environment"
	echo "The two main Linux families are supported:"
	echo "Debian, Ubuntu, Pop!_OS, etc (with a2enconf)"
	echo "Fedora, Red Hat, AlmaLinux, Rocky Linux, etc (with conf.d)"
	exit 1
fi

if [ -f "/usr/local/cpanel/cpanel" ]; then
	IS_CPANEL=true
else
	IS_CPANEL=false
fi

# Determine library directory, resolving symlinks where available
LIB_PATH="${BASH_SOURCE[0]:-$0}"
if command -v readlink >/dev/null 2>&1; then
	# Prefer fully resolved path for robustness
	RESOLVED="$(readlink -f "$LIB_PATH" 2>/dev/null)"
	if [ -n "$RESOLVED" ]; then
		LIB_PATH="$RESOLVED"
	fi
fi
LIB_DIR="$(cd -P "$(dirname "$LIB_PATH")" && pwd)"

# Lucee root is two directories up from upgrade-in-progress
LUCEE_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
LUCEE_ROOT="${LUCEE_ROOT%/}"
UPG_DIR="${LUCEE_ROOT}/sys/upgrade-in-progress"
SITES_FILE="${UPG_DIR}/sites-configured.txt"

# Determine sudo prefix for privileged actions
SUDO=""
if [ "$(id -u)" != "0" ]; then
	SUDO="sudo"
fi

# Detect which Apache controller is available to callers
# Will be one of: "apache2", "httpd", "apachectl", "apache2ctl"
# Abort if none are found
detect_apache_controller() {

	if command -v systemctl >/dev/null 2>&1; then
		if systemctl list-units --type=service | grep -q '^[[:space:]]*apache2\.service'; then
			echo "apache2"
			return 0
		elif systemctl list-units --type=service | grep -q '^[[:space:]]*httpd\.service'; then
			echo "httpd"
			return 0
		fi
	fi
	
	if command -v apachectl >/dev/null 2>&1; then
		echo "apachectl"
		return 0
	elif command -v apache2ctl >/dev/null 2>&1; then
		echo "apache2ctl"
		return 0
	fi
	
	echo ""
	echo "ERROR: No Apache controller found."
	echo "Requires httpd, apache2, apache2ctl, or apachectl"
	exit 1
}

# Detect and set global APACHE_CONTROLLER
APACHE_CONTROLLER=$(detect_apache_controller)

# Check if Apache has been configured for upgrade-in-progress
check_apache_configured() {
	# Debian, Ubuntu, Pop!_OS, etc
	if [ "$IS_DEBIAN" = true ]; then
		if [ ! -f "/etc/apache2/conf-available/lucee-upgrade-in-progress.conf" ]; then
			return 1
		fi
		return 0
	# Fedora, Red Hat, AlmaLinux, Rocky Linux, etc
	elif [ -n "$CONF_DIR" ]; then
		if [ ! -f "${CONF_DIR}/lucee-upgrade-in-progress.conf" ]; then
			return 1
		fi
		return 0
	fi
	
	# Unsupported environment
	return 1
}

# Reload Apache/httpd in a cross-distro way (uses graceful semantics where applicable)
apache_graceful_reload() {
	echo ""
	# Emit service-specific messaging based on global APACHE_CONTROLLER
	case "$APACHE_CONTROLLER" in
		apache2)
			# Try systemd first if available
			if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service | grep -q '^[[:space:]]*apache2\.service'; then
				echo "Reloading Apache via systemctl reload apache2..."
				if ! ${SUDO} systemctl reload apache2; then
					echo ""
					echo "ERROR: reload failed. Status output:"
					echo ""
					systemctl status apache2.service --no-pager -l || true
					return 1
				fi
				return 0
			# Fallback to apache2ctl if systemd not available
			elif command -v apache2ctl >/dev/null 2>&1; then
				echo "Reloading Apache via apache2ctl -k graceful..."
				if ! ${SUDO} apache2ctl -k graceful; then
					echo ""
					echo "ERROR: reload failed."
					return 1
				fi
				return 0
			else
				echo "ERROR: No apache2 control command found."
				return 1
			fi
			;;
		apachectl)
			echo "Reloading Apache via apachectl -k graceful..."
			if ! ${SUDO} apachectl -k graceful; then
				echo "ERROR: apachectl graceful reload failed."
				return 1
			fi
			return 0
			;;
		apache2ctl)
			echo "Reloading Apache via apache2ctl -k graceful..."
			if ! ${SUDO} apache2ctl -k graceful; then
				echo "ERROR: apache2ctl graceful reload failed."
				return 1
			fi
			return 0
			;;
		httpd)
			# Try systemd first if available
			if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service | grep -q '^[[:space:]]*httpd\.service'; then
				echo "Reloading Apache via systemctl reload httpd..."
				if ! ${SUDO} systemctl reload httpd; then
					echo "ERROR: httpd reload failed."
					echo "Status output:"
					systemctl status httpd.service --no-pager -l || true
					return 1
				fi
				return 0
			# Fallback to direct httpd command if systemd not available
			elif command -v httpd >/dev/null 2>&1; then
				echo "Reloading Apache via httpd -k graceful..."
				if ! ${SUDO} httpd -k graceful; then
					echo "ERROR: httpd graceful reload failed."
					return 1
				fi
				return 0
			# Try apachectl as last resort
			elif command -v apachectl >/dev/null 2>&1; then
				echo "Reloading Apache via apachectl -k graceful..."
				if ! ${SUDO} apachectl -k graceful; then
					echo "ERROR: apachectl graceful reload failed."
					return 1
				fi
				return 0
			else
				echo "ERROR: No httpd control command found."
				return 1
			fi
			;;
		*)
			echo "ERROR: No known Apache control command found to reload."
			return 1
			;;
	esac
}


# cPanel-specific graceful restart helper
# Rebuilds httpd configuration and performs a graceful restart.
# Returns 0 on success, non-zero on failure.
apache_cpanel_graceful_restart() {
	
	echo ""

	# Basic presence checks
	if [ "$IS_CPANEL" != true ]; then
		echo "ERROR: cPanel required for apache_cpanel_graceful_restart()"
		exit 1
	fi
	if [ ! -x "/scripts/rebuildhttpdconf" ] || [ ! -x "/scripts/restartsrv_httpd" ]; then
		echo "ERROR: Required cPanel scripts not found: /scripts/rebuildhttpdconf or /scripts/restartsrv_httpd"
		exit 1
	fi

	echo "Running /scripts/rebuildhttpdconf..."
	if ! ${SUDO} /scripts/rebuildhttpdconf; then
		echo "ERROR: Failed to rebuild httpd configuration via /scripts/rebuildhttpdconf"
		return 1
	fi

	echo "Running /scripts/restartsrv_httpd --graceful..."
	if ! ${SUDO} /scripts/restartsrv_httpd --graceful; then
		echo "ERROR: Failed to gracefully restart httpd via /scripts/restartsrv_httpd --graceful"
		return 1
	fi

	return 0
}

apache_reload() {
	if [ "$IS_CPANEL" = true ]; then
		apache_cpanel_graceful_restart
		return $?
	else
		apache_graceful_reload
		return $?
	fi
}
