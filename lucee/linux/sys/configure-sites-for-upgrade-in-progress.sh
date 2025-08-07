#!/bin/bash

# Deploy:
# cd /path/to/this/script
# cp ./configure-sites-for-upgrade-in-progress.sh /opt/lucee/sys/configure-sites-for-upgrade-in-progress.sh
# chmod +x /opt/lucee/sys/configure-sites-for-upgrade-in-progress.sh

# Update:
# cat ./configure-sites-for-upgrade-in-progress.sh | sudo tee /opt/lucee/sys/configure-sites-for-upgrade-in-progress.sh

# Execute:
# sudo /opt/lucee/sys/configure-sites-for-upgrade-in-progress.sh

# require root
if [ "$(id -u)" != "0" ]; then
echo "This script must be run as root or with sudo."
exit 1
fi

SITES_FILE="/opt/lucee/sys/sites-configured-for-upgrade-in-progress.txt"
if [ ! -f "$SITES_FILE" ]; then
	echo "Lucee sites data file not found. You first need to run:"
	echo "sudo /opt/lucee/sys/get-lucee-sites-for-upgrade-in-progress.sh"
	echo "Then review and if necessary edit the .txt file"
	echo "from that before returning to this script."
	exit 1
fi

# prep cPanel flag
if [ -f "/usr/local/cpanel/cpanel" ]; then
	IS_CPANEL=true
else
	IS_CPANEL=false
	echo "This script has not been completed yet for non-cPanel environments."
	echo "Pull requests are welcome!"
	exit 1
fi

# Debian/Ubuntu/etc
if command -v a2enconf >/dev/null 2>&1; then
	echo "The script hasn't been completed yet for Debian/Ubuntu/etc"
	exit 1

# Redhat/CentOS/AlmaLinux/etc
elif [ -d /etc/httpd/conf.d ]; then
	echo "Configuring Lucee sites for scripted 'Upgrade in Progress' notifications ..."
	
	# Get data from /opt/lucee/sys/sites-configured-for-upgrade-in-progress.txt
	while IFS= read -r line; do
		domain=$(echo "$line" | awk '{print $1}')
		docroot=$(echo "$line" | awk '{print $2}')
		site_type=$(echo "$line" | awk '{print $3}')
		
		if [ "$IS_CPANEL" = true ]; then
			# expected cPanel docroot: /home/user/public_html
			user=$(echo "$docroot" | awk -F '/' '{print $3}')
			# if not exists, copy upgrade-in-progress.conf to cPanel userdata directory
			# if [ ! -f /etc/apache2/conf.d/userdata/ssl/2_4/${user}/${domain}/upgrade-in-progress.conf ]; then
				mkdir -p /etc/apache2/conf.d/userdata/ssl/2_4/${user}/${domain}
				cp -f /opt/lucee/sys/upgrade-in-progress-${site_type}.conf /etc/apache2/conf.d/userdata/ssl/2_4/${user}/${domain}/upgrade-in-progress.conf
			# fi
			# if not exists, copy upgrade-in-progress.html to docroot
			# if [ ! -f ${docroot}/upgrade-in-progress.html ]; then
				cp -f /opt/lucee/sys/upgrade-in-progress.html ${docroot}/upgrade-in-progress.html
				chown --reference=${docroot} ${docroot}/upgrade-in-progress.html
			# fi
		
		else
			# not developed yet
			echo "This section has not been completed yet for non-cPanel environments."
			echo "Pull requests are welcome!"
			exit 1
		fi
		
	
	done < /opt/lucee/sys/sites-configured-for-upgrade-in-progress.txt
	
	# Reload or rebuild/restart Apache
	if [ "$IS_CPANEL" = true ]; then
		echo "Rebuilding httpd configuration..."
		/scripts/rebuildhttpdconf
		echo "Restarting httpd..."
		/scripts/restartsrv_httpd
	elif command -v a2enconf >/dev/null 2>&1; then
		echo "Reloading Apache..."
		systemctl reload apache2
	elif [ -d /etc/httpd/conf.d ]; then
		echo "Reloading httpd..."
		systemctl reload httpd
	else
		echo "Unsupported environment (neither a2enconf nor /etc/httpd/conf.d detected)"
		exit 1
	fi

fi			
	
# /etc/apache2/conf.d/userdata/std/2_4/${user}/${domain}/upgrade-in-progress.conf

echo "DONE!"
