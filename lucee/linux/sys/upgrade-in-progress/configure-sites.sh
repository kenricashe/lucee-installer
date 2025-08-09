#!/bin/bash

# Deploy:
# cd /path/to/this/script
# cp ./configure-sites.sh /opt/lucee/sys/upgrade-in-progress/configure-sites.sh
# chmod +x /opt/lucee/sys/upgrade-in-progress/configure-sites.sh

# Update:
# cat ./configure-sites.sh | sudo tee /opt/lucee/sys/upgrade-in-progress/configure-sites.sh

# Execute:
# sudo /opt/lucee/sys/upgrade-in-progress/configure-sites.sh

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root or with sudo."
	exit 1
fi

SITES_FILE="/opt/lucee/sys/upgrade-in-progress/sites-configured.txt"
if [ ! -f "$SITES_FILE" ]; then
	echo "Lucee sites data file not found. You first need to run:"
	echo "sudo /opt/lucee/sys/upgrade-in-progress/get-lucee-sites.sh"
	echo "Then review and if necessary edit the .txt file"
	echo "from that before returning to this script."
	exit 1
fi

# prep cPanel flag
if [ -f "/usr/local/cpanel/cpanel" ]; then
	IS_CPANEL=true
	CPANEL_USERDATA_SSL_PATH="/etc/apache2/conf.d/userdata/ssl/2_4"
	CPANEL_USERDATA_STD_PATH="/etc/apache2/conf.d/userdata/std/2_4"
else
	IS_CPANEL=false
fi

# Apache config test helper: prefer apache2ctl, then apachectl, then httpd
apache_config_test() {
	if command -v apache2ctl >/dev/null 2>&1; then
		apache2ctl -t
	elif command -v apachectl >/dev/null 2>&1; then
		apachectl -t
	elif command -v httpd >/dev/null 2>&1; then
		httpd -t
	else
		echo "Warning: No apache control binary found for config test; skipping syntax check."
		return 0
	fi
}

# Ensure global Apache confs exist and are set to normal-state defaults
# Normal state: AJP/mod_cfml enabled; upgrade flag disabled
ensure_global_confs() {
	# Debian/Ubuntu
	if command -v a2enconf >/dev/null 2>&1; then
		conf_avail="/etc/apache2/conf-available"
		opt_file="/opt/lucee/sys/upgrade-in-progress/lucee-upgrade-in-progress.conf"
		if [ -f "$opt_file" ] && [ ! -f "${conf_avail}/lucee-upgrade-in-progress.conf" ]; then
			echo "Installing global lucee-upgrade-in-progress.conf into ${conf_avail}/"
			cp -f "$opt_file" "${conf_avail}/lucee-upgrade-in-progress.conf"
		fi
		# Ensure upgrade flag is disabled by default
		a2disconf lucee-upgrade-in-progress >/dev/null 2>&1 || true
		# Ensure AJP+mod_cfml is enabled if present in conf-available
		if [ -f "${conf_avail}/lucee-ajp-and-mod_cfml.conf" ]; then
			a2enconf lucee-ajp-and-mod_cfml >/dev/null 2>&1 || true
		fi
		# Warn if no AJP proxying detected in global config
		ajp_detected=false
		if [ -f "${conf_avail}/lucee-ajp-and-mod_cfml.conf" ] || [ -f "/etc/apache2/conf-enabled/lucee-ajp-and-mod_cfml.conf" ]; then
			ajp_detected=true
		elif grep -Rqi 'ajp://' /etc/apache2/ 2>/dev/null; then
			ajp_detected=true
		fi
		if [ "$ajp_detected" != true ]; then
			echo "Warning: AJP proxying not detected in global Apache config (Debian/Ubuntu). Normal operation expects AJP/mod_cfml enabled."
		fi
		return
	fi

	# RHEL family and cPanel
	if [ -d /etc/httpd/conf.d ] || [ -d /etc/apache2/conf.d ]; then
		if [ "$IS_CPANEL" = true ]; then
			confd="/etc/apache2/conf.d"
		else
			confd="/etc/httpd/conf.d"
		fi
		opt_file="/opt/lucee/sys/upgrade-in-progress/lucee-upgrade-in-progress.conf"
		# Ensure a disabled copy exists if neither form exists
		if [ -f "$opt_file" ] && [ ! -f "${confd}/lucee-upgrade-in-progress.disabled" ] && [ ! -f "${confd}/lucee-upgrade-in-progress.conf" ]; then
			echo "Installing global lucee-upgrade-in-progress.disabled into ${confd}/"
			cp -f "$opt_file" "${confd}/lucee-upgrade-in-progress.disabled"
		fi
		# Ensure normal state: upgrade flag disabled
		if [ -f "${confd}/lucee-upgrade-in-progress.conf" ]; then
			echo "Disabling lucee-upgrade-in-progress.conf (normal state)"
			mv -f "${confd}/lucee-upgrade-in-progress.conf" "${confd}/lucee-upgrade-in-progress.disabled"
		fi
		# Ensure AJP+mod_cfml is enabled (rename from .disabled if needed)
		if [ -f "${confd}/lucee-ajp-and-mod_cfml.conf.disabled" ] && [ ! -f "${confd}/lucee-ajp-and-mod_cfml.conf" ]; then
			echo "Enabling lucee-ajp-and-mod_cfml.conf (normal state)"
			mv -f "${confd}/lucee-ajp-and-mod_cfml.conf.disabled" "${confd}/lucee-ajp-and-mod_cfml.conf"
		fi
		# Warn if no AJP proxying detected in global config
		ajp_detected=false
		if [ -f "${confd}/lucee-ajp-and-mod_cfml.conf" ] || [ -f "${confd}/lucee-ajp-and-mod_cfml.conf.disabled" ]; then
			ajp_detected=true
		elif grep -Rqi 'ajp://' "$confd" 2>/dev/null; then
			ajp_detected=true
		fi
		if [ "$ajp_detected" != true ]; then
			echo "Warning: AJP proxying not detected in global Apache config (${confd}). Normal operation expects AJP/mod_cfml enabled."
		fi
		return
	fi
}

# Function to copy upgrade-in-progress.html to DocumentRoot
copy_upgrade_html() {
	local docroot=$1
	cp -f /opt/lucee/sys/upgrade-in-progress/upgrade-in-progress.html ${docroot}/upgrade-in-progress.html
	chown --reference=${docroot} ${docroot}/upgrade-in-progress.html 2>/dev/null || true
}

# Function to configure Debian sites
configure_site_debian() {
	local domain=$1
	local docroot=$2
	local site_type=$3
	
	echo "Processing $domain ($site_type site) with DocumentRoot: $docroot"
	
	# Copy upgrade-in-progress.html to DocumentRoot
	copy_upgrade_html "$docroot"
	
	# Check if the SSL site in sites-enabled is a regular file (not a symlink)
	# This would happen if a previous buggy version of the script replaced the symlink
	enabled_ssl_conf="/etc/apache2/sites-enabled/${domain}-ssl.conf"
	if [ -f "$enabled_ssl_conf" ] && [ ! -L "$enabled_ssl_conf" ]; then
		echo "  Found regular file instead of symlink at $enabled_ssl_conf"
		echo "  Restoring symlink structure..."
		
		# Get the site name without extension
		site_name="${domain}-ssl"
		
		# First manually remove the file to avoid a2dissite warnings
		rm -f "$enabled_ssl_conf"
		
		# Enable the site (creates a proper symlink)
		a2ensite "$site_name" > /dev/null 2>&1
		
		echo "  Symlink restored for $site_name"
	fi
	
	# Find the SSL site configuration file in sites-available directly
	ssl_conf_file="/etc/apache2/sites-available/${domain}-ssl.conf"
	if [ ! -f "$ssl_conf_file" ]; then
		# Try to find by ServerName
		ssl_conf_file=$(grep -l "ServerName $domain" /etc/apache2/sites-available/*-ssl.conf 2>/dev/null | head -1)
	fi
	
	if [ -f "$ssl_conf_file" ]; then
		echo "  Updating $ssl_conf_file"
		# Backup before editing
		cp -f "$ssl_conf_file" "${ssl_conf_file}.bak"
		
		# Remove any existing Lucee upgrade includes
		sed -i '/Include.*lucee-detect-upgrade.conf/d' "$ssl_conf_file"
		sed -i '/Include.*lucee-404-routing.conf/d' "$ssl_conf_file"
		
		# Replace all whitespace just before closing </VirtualHost> with '\n\n'
		sed -i ':a;N;$!ba;s/\n[[:space:]]*\n*[[:space:]]*<\/VirtualHost>/\n\n<\/VirtualHost>/' "$ssl_conf_file"

		# Add appropriate includes before the closing </VirtualHost>
		if [ "$site_type" = "root" ]; then
			# Root sites get both upgrade detection and 404 routing
			sed -i 's|</VirtualHost>|\tInclude /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf\n\tInclude /opt/lucee/sys/upgrade-in-progress/lucee-404-routing.conf\n\n</VirtualHost>|' "$ssl_conf_file"
		else
			# Non-root sites get only upgrade detection
			sed -i 's|</VirtualHost>|\tInclude /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf\n\n</VirtualHost>|' "$ssl_conf_file"
		fi
	else
		echo "  Warning: Could not find SSL configuration file for $domain"
	fi

	# Also update the HTTP (port 80) VirtualHost if present
	# Find the HTTP site configuration file in sites-available
	http_conf_file="/etc/apache2/sites-available/${domain}.conf"
	if [ ! -f "$http_conf_file" ]; then
		# Try to find by ServerName, excluding -ssl.conf
		http_conf_file=$(grep -l "ServerName $domain" /etc/apache2/sites-available/*.conf 2>/dev/null | grep -v -- '-ssl\.conf' | head -1)
	fi

	if [ -f "$http_conf_file" ]; then
		echo "  Updating $http_conf_file"
		# Backup before editing
		cp -f "$http_conf_file" "${http_conf_file}.bak"
		# Remove any existing Lucee upgrade includes
		sed -i '/Include.*lucee-detect-upgrade.conf/d' "$http_conf_file"
		sed -i '/Include.*lucee-404-routing.conf/d' "$http_conf_file"
		# Normalize whitespace before </VirtualHost>
		sed -i ':a;N;$!ba;s/\n[[:space:]]*\n*[[:space:]]*<\/VirtualHost>/\n\n<\/VirtualHost>/' "$http_conf_file"
		# Add appropriate includes before the closing </VirtualHost>
		if [ "$site_type" = "root" ]; then
			sed -i 's|</VirtualHost>|\tInclude /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf\n\tInclude /opt/lucee/sys/upgrade-in-progress/lucee-404-routing.conf\n\n</VirtualHost>|' "$http_conf_file"
		else
			sed -i 's|</VirtualHost>|\tInclude /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf\n\n</VirtualHost>|' "$http_conf_file"
		fi
		# Best-effort warning if HTTP VirtualHost may not redirect to HTTPS
		if ! grep -Eiq '(Redirect(\s+(permanent|temp|301|302))?\s+/?\s+https?://|RewriteRule\s+.*https://)' "$http_conf_file"; then
			echo "  Warning: HTTP vhost for $domain may not redirect to HTTPS. Ensure a proper 80->443 redirect is configured to avoid exposure over HTTP."
		fi
	else
		echo "  Info: No HTTP configuration file found for $domain"
	fi
}

# Function to configure cPanel sites
configure_site_cpanel() {
	local domain=$1
	local docroot=$2
	local site_type=$3
	
	echo "Processing cPanel site: $domain ($site_type site) with DocumentRoot: $docroot"
	
	# expected cPanel docroot: /home/user/public_html
	user=$(echo "$docroot" | awk -F '/' '{print $3}')
	
	# Copy upgrade-in-progress.html to DocumentRoot
	copy_upgrade_html "$docroot"
	
	# Create userdata directory
	mkdir -p ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}
	mkdir -p ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}
	
	# Create lucee.conf with appropriate includes
	if [ "$site_type" = "root" ]; then
		# Root sites get both upgrade detection and 404 routing
		cat > ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# /opt/lucee/sys/upgrade-in-progress/configure-sites.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
Include /opt/lucee/sys/upgrade-in-progress/lucee-404-routing.conf
EOF
		# Also create non-SSL userdata include
		cat > ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# /opt/lucee/sys/upgrade-in-progress/configure-sites.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
Include /opt/lucee/sys/upgrade-in-progress/lucee-404-routing.conf
EOF
	else
		# Non-root sites get only upgrade detection
		cat > ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# /opt/lucee/sys/upgrade-in-progress/configure-sites.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
EOF
		# Also create non-SSL userdata include
		cat > ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# /opt/lucee/sys/upgrade-in-progress/configure-sites.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
EOF
	fi
}

# Function to configure non-cPanel RedHat sites (placeholder)
configure_site_redhat() {
	local domain=$1
	local docroot=$2
	local site_type=$3
	
	echo "Non-cPanel RedHat configuration not implemented yet for $domain"
	echo "Pull requests are welcome!"
}

# Function to process all sites from the configuration file
process_sites() {
	local configure_func=$1
	
	# Get data from txt file
	while IFS= read -r line; do
		domain=$(echo "$line" | awk '{print $1}')
		docroot=$(echo "$line" | awk '{print $2}')
		site_type=$(echo "$line" | awk '{print $3}')
		
		$configure_func "$domain" "$docroot" "$site_type"
		
	done < $SITES_FILE
}

# Function to reload Apache
reload_apache() {
	local apache_service=$1
	echo "Reloading Apache..."
	systemctl reload $apache_service
}

# Main script execution
echo "Configuring Lucee sites for scripted 'Upgrade in Progress' notifications ..."

# Detect distribution and run appropriate code path
if command -v a2enconf >/dev/null 2>&1; then
	# Debian/Ubuntu path
	ensure_global_confs
	process_sites configure_site_debian
	# Validate Apache configuration before reload
	if ! apache_config_test; then
		echo "Apache configuration test FAILED. Aborting reload."
		exit 1
	fi
	reload_apache apache2
	
# Redhat/CentOS/AlmaLinux/etc
elif [ -d /etc/httpd/conf.d ]; then
	if [ "$IS_CPANEL" = true ]; then
		# cPanel path
		ensure_global_confs
		process_sites configure_site_cpanel
		
		# Rebuild Apache configuration and validate
		echo "Rebuilding Apache configuration..."
		/scripts/rebuildhttpdconf
		if ! apache_config_test; then
			echo "Apache configuration test FAILED. Aborting restart."
			exit 1
		fi
		echo "Gracefully restarting httpd..."
		/scripts/restartsrv_httpd --graceful
	else
		# Non-cPanel RedHat path
		ensure_global_confs
		process_sites configure_site_redhat
		# Validate Apache configuration before reload
		if ! apache_config_test; then
			echo "Apache configuration test FAILED. Aborting reload."
			exit 1
		fi
		reload_apache httpd
	fi
else
	echo "Unsupported environment (neither a2enconf nor /etc/httpd/conf.d detected)"
	exit 1
fi			
	
# /etc/apache2/conf.d/userdata/std/2_4/${user}/${domain}/upgrade-in-progress.conf

echo "DONE!"
