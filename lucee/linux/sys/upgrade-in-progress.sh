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

if [ "$MODE" == "begin" ]; then

	# Debian/Ubuntu/etc
	if command -v a2enconf >/dev/null 2>&1; then
		echo "Enabling lucee-upgrade-in-progress configuration..."
		a2enconf lucee-upgrade-in-progress >/dev/null
		echo "Disabling lucee-ajp-and-mod_cfml configuration..."
		a2disconf lucee-ajp-and-mod_cfml >/dev/null
		echo "Restarting Apache..."
		systemctl restart apache2
	
	# Redhat/CentOS/AlmaLinux/etc
	elif [ -d /etc/httpd/conf.d ]; then
		cd /etc/httpd/conf.d || exit 1
		echo "Enabling lucee-upgrade-in-progress configuration..."
		mv -f lucee-upgrade-in-progress.disabled lucee-upgrade-in-progress
		echo "Disabling lucee-ajp-and-mod_cfml configuration..."
		mv -f lucee-ajp-and-mod_cfml.conf lucee-ajp-and-mod_cfml.conf.disabled
		echo "Rebuilding httpd configuration..."
		/scripts/rebuildhttpdconf
		echo "Restarting httpd..."
		/scripts/restartsrv_httpd
	
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
		echo "Restarting Apache..."
		systemctl restart apache2
	
	# Redhat/CentOS/AlmaLinux/etc
	elif [ -d /etc/httpd/conf.d ]; then
		cd /etc/httpd/conf.d || exit 1
		echo "Enabling lucee-ajp-and-mod_cfml configuration..."
		mv -f lucee-ajp-and-mod_cfml.conf.disabled lucee-ajp-and-mod_cfml.conf
		echo "Disabling lucee-upgrade-in-progress configuration..."
		mv -f lucee-upgrade-in-progress lucee-upgrade-in-progress.disabled
		echo "Rebuilding httpd configuration..."
		/scripts/rebuildhttpdconf
		echo "Restarting httpd..."
		/scripts/restartsrv_httpd
	
	else
		echo "Unsupported environment (neither a2enconf nor /etc/httpd/conf.d detected)"
		exit 1
	fi
fi

echo "DONE!"
