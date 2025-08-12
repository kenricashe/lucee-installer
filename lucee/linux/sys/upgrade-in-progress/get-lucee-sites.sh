#!/bin/bash

# sudo /opt/lucee/sys/upgrade-in-progress/get-lucee-sites.sh

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

# Source shared helper for LUCEE_ROOT, UPG_DIR, IS_CPANEL
SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
. "${SCRIPT_DIR}/get-env.sh"

TXTPATH_ALL_DATA="${UPG_DIR}/sites-configured.txt"
TXTPATH_ONLY_DOMAINS="${UPG_DIR}/active-domains.txt"

# Set RedHat httpd.conf path
if [ "$IS_CPANEL" = true ]; then
	RHEL_HTTPD_CONF="/etc/apache2/conf/httpd.conf"
else
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

	echo ""
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
	echo "$TXTPATH_ALL_DATA"
	echo ""
	echo "A domains-only file (just in case you need it) was also saved as:"
	echo ""
	echo "$TXTPATH_ONLY_DOMAINS"
	echo ""
	echo "In the next step you will view the results file using the nano editor."
	echo ""
	echo "If there are any sites that you want to exempt from being Lucee-disabled"
	echo "during 'Upgrade in Progress' sessions, simply remove them from the file."
	echo ""
	echo "Press Enter to continue..."
	read -r _
}

# Main script execution
# If previous results exist, back them up and prompt to continue
if [ -f "$TXTPATH_ALL_DATA" ]; then
	# Centralized backup root and timestamp (mirrors original path under backup root)
	BACKUP_ROOT="${UPG_DIR}/backups"
	BACKUP_TS="$(date +%Y-%m-%d-%H%M%S)"
	BACKUP_DEST="${BACKUP_ROOT}/${BACKUP_TS}${TXTPATH_ALL_DATA}"
	# Ensure destination directory exists, then copy
	BACKUP_DIR="$(dirname "$BACKUP_DEST")"
	mkdir -p "$BACKUP_DIR"
	if cp -f "$TXTPATH_ALL_DATA" "$BACKUP_DEST"; then
		echo ""
		echo "Existing file backed up to: $BACKUP_DEST"
	else
		echo ""
		echo "ERROR: Failed to back up existing file. Aborting."
		exit 1
	fi
	# Prompt until a valid answer (default Yes)
	while :; do
		echo ""
		echo -n "Continue and overwrite $TXTPATH_ALL_DATA? [Y/n] "
		read -r _ans
		if [ -z "$_ans" ] || [ "$_ans" = "Y" ] || [ "$_ans" = "y" ]; then
			break
		fi
		if [ "$_ans" = "N" ] || [ "$_ans" = "n" ]; then
			echo ""
			echo "Aborted by user."
			exit 0
		fi
		echo ""
		echo "Please enter Y or n."
	done
fi

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

# View/Edit sites file
${SUDO} ${EDITOR:-nano} "${SITES_FILE}"
