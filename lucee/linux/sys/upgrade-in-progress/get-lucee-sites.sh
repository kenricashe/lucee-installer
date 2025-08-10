#!/bin/bash

# sudo /opt/lucee/sys/upgrade-in-progress/get-lucee-sites.sh

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

TXTPATH_ALL_DATA="${UPG_DIR}/sites-configured.txt"
TXTPATH_ONLY_DOMAINS="${UPG_DIR}/active-domains.txt"

# Detect cPanel and set RedHat httpd.conf path
if [ -f "/usr/local/cpanel/cpanel" ]; then
	IS_CPANEL=true
	RHEL_HTTPD_CONF="/etc/apache2/conf/httpd.conf"
else
	IS_CPANEL=false
	RHEL_HTTPD_CONF="/etc/httpd/conf/httpd.conf"
fi

# Function to get domains from Debian/Ubuntu systems
get_domains_debian() {
	# Get list of domains from enabled sites
	# Only include SSL sites (-ssl.conf) and exclude 000-default-ssl.conf
	enabled_ssl_sites=$(a2query -s | grep -v '^000-default' | grep -E '.*-ssl' | cut -d' ' -f1 | sed 's/-ssl$//')
	for site in $enabled_ssl_sites; do
		conf_file="/etc/apache2/sites-enabled/${site}-ssl.conf"
		if [ -f "$conf_file" ]; then
			grep -i 'ServerName' "$conf_file" | awk '{print $2}'
		fi
	done | sort -u
}

# Function to get DocumentRoot for a domain on Debian/Ubuntu systems
get_docroot_debian() {
	local domain=$1
	local conf_file=$(grep -l "ServerName $domain" /etc/apache2/sites-enabled/*-ssl.conf 2>/dev/null | head -1)
	grep -A 10 -B 5 "ServerName $domain" "$conf_file" | grep -i "DocumentRoot" | awk '{print $2}' | head -1
}

# Function to get domains from RedHat/CentOS systems
get_domains_redhat() {
	grep -i 'ServerName' "$RHEL_HTTPD_CONF" | awk '{print $2}' | 
	grep -vE '^(cpanel|webmail|whm|mail|webdisk|default|bounce|_wildcard_|proxy-subdomains-vhost|acpaneltest|mta1|news)(\.|$)' | 
	sort -u
}

# Function to get DocumentRoot for a domain on RedHat/CentOS systems
get_docroot_redhat() {
	local domain=$1
	grep -A 10 -B 5 "ServerName $domain" "$RHEL_HTTPD_CONF" | grep -i "DocumentRoot" | awk '{print $2}' | head -1
}

# Function to save results to file
save_results() {
	local get_docroot_func=$1

	echo "Saving results ..."

	> $TXTPATH_ALL_DATA
	> $TXTPATH_ONLY_DOMAINS

	while IFS= read -r site; do
		if [ -z "$site" ]; then
			continue
		fi
		docroot=$($get_docroot_func "$site")
		if [ -n "$docroot" ]; then
			echo "$site $docroot" >> $TXTPATH_ALL_DATA
			echo "$site" >> $TXTPATH_ONLY_DOMAINS
		else
			echo "Warning: Skipping $site (DocumentRoot not found)"
		fi
	done <<< "$domains"

	echo ""
	echo "Review and if necessary edit the results file:"
	echo ""
	echo "sudo nano $TXTPATH_ALL_DATA"
	echo ""
	echo "Then run:"
	echo ""
	echo "sudo ${UPG_DIR}/configure-sites.sh"
	echo ""
	echo "A domains-only file was also saved as:"
	echo ""
	echo "$TXTPATH_ONLY_DOMAINS"
	echo ""
}

# Main script execution
echo "Analyzing Lucee sites..."

# Detect distribution and run appropriate code path
if command -v a2enconf >/dev/null 2>&1; then
	# Debian/Ubuntu path
	domains=$(get_domains_debian)
	save_results get_docroot_debian
	
# Redhat/CentOS/AlmaLinux/etc
elif [ -d /etc/httpd/conf.d ]; then
	# RedHat/CentOS path
	domains=$(get_domains_redhat)
	save_results get_docroot_redhat
fi

echo "DONE!"
