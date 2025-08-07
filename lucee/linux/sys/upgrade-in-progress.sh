#!/bin/bash

MODE=$1

if [ "$MODE" != "begin" ] && [ "$MODE" != "end" ]; then
	echo "Usage: $0 [begin|end]"
	exit 1
fi

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

# prep cPanel flag
if [ -f "/usr/local/cpanel/cpanel" ]; then
	IS_CPANEL=true
else
	IS_CPANEL=false
fi

if [ "$MODE" == "begin" ]; then

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
			echo "Restarting httpd..."
			/scripts/restartsrv_httpd
		else
			echo "Reloading httpd..."
			systemctl reload httpd
		fi
	
	else
		echo "Unsupported environment (neither a2enconf nor /etc/httpd/conf.d detected)"
		exit 1
	fi

elif [ "$MODE" == "end" ]; then

	# Debian/Ubuntu/etc
	if command -v a2enconf >/dev/null 2>&1; then
		echo "Enabling lucee-ajp-and-mod_cfml configuration..."
		a2enconf lucee-ajp-and-mod_cfml >/dev/null
		echo "Disabling lucee-upgrade-in-progress configuration..."
		a2disconf lucee-upgrade-in-progress >/dev/null
		echo "Reloading Apache..."
		systemctl reload apache2

	# Redhat/CentOS/AlmaLinux/etc
	elif [ -d /etc/httpd/conf.d ]; then
		if [ "$IS_CPANEL" = true ]; then
			cd /etc/apache2/conf.d || exit 1
		else
			cd /etc/httpd/conf.d || exit 1
		fi
		echo "Enabling lucee-ajp-and-mod_cfml configuration..."
		mv -f lucee-ajp-and-mod_cfml.conf.disabled lucee-ajp-and-mod_cfml.conf
		echo "Disabling lucee-upgrade-in-progress configuration..."
		mv -f lucee-upgrade-in-progress.conf lucee-upgrade-in-progress.disabled
		if [ "$IS_CPANEL" = true ]; then
			echo "Rebuilding httpd.conf..."
			/scripts/rebuildhttpdconf
			echo "Restarting httpd..."
			/scripts/restartsrv_httpd
		else
			echo "Reloading httpd..."
			systemctl reload httpd
		fi
	else
		echo "Unsupported environment (neither a2enconf nor /etc/httpd/conf.d detected)"
		exit 1
	fi
fi

echo "DONE!"
