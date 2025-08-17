#!/bin/bash

# Shared environment for upgrade-in-progress scripts
# Sets LUCEE_ROOT, UPG_DIR (relative to this file), and IS_CPANEL.

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

# Detect cPanel (available to callers)
if [ -f "/usr/local/cpanel/cpanel" ]; then
	IS_CPANEL=true
else
	IS_CPANEL=false
fi

# Detect which web server type is available (available to callers)
# Will be one of: "apache2", "httpd", "apachectl", "apache2ctl", or "unknown"
detect_web_server() {
	if command -v systemctl >/dev/null 2>&1; then
		if systemctl list-units --type=service | grep -q '^apache2\.service'; then
			echo "apache2"
			return 0
		elif systemctl list-units --type=service | grep -q '^httpd\.service'; then
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
	
	echo "unknown"
	return 0
}

# Detect and set global SERVER_TYPE
SERVER_TYPE=$(detect_web_server)

# Reload Apache/httpd in a cross-distro way (uses graceful semantics where applicable)
# Returns 0 on success, non-zero on failure.
apache_graceful_reload() {
	# Emit service-specific messaging based on global SERVER_TYPE
	case "$SERVER_TYPE" in
		apache2)
			echo "Reloading apache2..."
			# Try systemd first if available
			if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service | grep -q '^apache2\.service'; then
				if ! ${SUDO} systemctl reload apache2; then
					echo "ERROR: apache2 reload failed."
					echo "Status output:"
					systemctl status apache2.service --no-pager -l || true
					return 1
				fi
				return 0
			# Fallback to apache2ctl if systemd not available
			elif command -v apache2ctl >/dev/null 2>&1; then
				if ! ${SUDO} apache2ctl -k graceful; then
					echo "ERROR: apache2ctl graceful reload failed."
					return 1
				fi
				return 0
			else
				echo "ERROR: No apache2 control command found."
				return 1
			fi
			;;
		httpd)
			echo "Reloading httpd..."
			# Try systemd first if available
			if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service | grep -q '^httpd\.service'; then
				if ! ${SUDO} systemctl reload httpd; then
					echo "ERROR: httpd reload failed."
					echo "Status output:"
					systemctl status httpd.service --no-pager -l || true
					return 1
				fi
				return 0
			# Fallback to direct httpd command if systemd not available
			elif command -v httpd >/dev/null 2>&1; then
				if ! ${SUDO} httpd -k graceful; then
					echo "ERROR: httpd graceful reload failed."
					return 1
				fi
				return 0
			# Try apachectl as last resort
			elif command -v apachectl >/dev/null 2>&1; then
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
		apachectl)
			echo "Reloading via apachectl -k graceful..."
			if ! ${SUDO} apachectl -k graceful; then
				echo "ERROR: apachectl graceful reload failed."
				return 1
			fi
			return 0
			;;
		apache2ctl)
			echo "Reloading via apache2ctl -k graceful..."
			if ! ${SUDO} apache2ctl -k graceful; then
				echo "ERROR: apache2ctl graceful reload failed."
				return 1
			fi
			return 0
			;;
		*)
			echo "Reloading web server..."
			echo "ERROR: No known Apache control command found to reload."
			return 1
			;;
	esac
}


# cPanel-specific graceful restart helper
# Rebuilds httpd configuration and performs a graceful restart.
# Returns 0 on success, non-zero on failure.
apache_cpanel_graceful_restart() {
	# Basic presence checks
	if [ "$IS_CPANEL" != true ]; then
		echo "Warning: apache_cpanel_graceful_restart called but IS_CPANEL != true."
		return 1
	fi
	if [ ! -x "/scripts/rebuildhttpdconf" ] || [ ! -x "/scripts/restartsrv_httpd" ]; then
		echo "ERROR: Required cPanel scripts not found: /scripts/rebuildhttpdconf or /scripts/restartsrv_httpd"
		return 1
	fi

	echo "Rebuilding httpd configuration..."
	if ! ${SUDO} /scripts/rebuildhttpdconf; then
		echo "ERROR: Failed to rebuild httpd configuration via /scripts/rebuildhttpdconf"
		return 1
	fi

	echo "Gracefully restarting httpd..."
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
