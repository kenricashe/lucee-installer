#!/bin/bash

# sudo /opt/lucee/sys/upgrade-in-progress/get-lucee-sites.sh

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

TXTPATH_ALL_DATA="/opt/lucee/sys/upgrade-in-progress/sites-configured.txt"
TXTPATH_ONLY_DOMAINS="/opt/lucee/sys/upgrade-in-progress/active-domains.txt"

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

# Function to analyze sites and categorize them
analyze_sites() {
	local domains=$1
	local get_docroot_func=$2
	
	# Arrays to store categorized sites
	sites_with_index_cfm=()
	sites_with_other_cfm=()
	sites_without_cfm=()
	
	# Iterate through each domain
	while IFS= read -r domain; do
		if [ -z "$domain" ]; then
			continue
		fi
		
		echo "Checking domain: $domain"
		
		# Find DocumentRoot for this domain using the provided function
		docroot=$($get_docroot_func "$domain")
		
		if [ -z "$docroot" ] || [ ! -d "$docroot" ]; then
			echo "  Warning: Could not find DocumentRoot for $domain or directory does not exist"
			continue
		fi
		
		echo "  DocumentRoot: $docroot"
		
		# Check for index.cfm or Application.cf* in DocumentRoot only (not subfolders)
		index_files=$(find "$docroot" -maxdepth 1 -type f \( -iname "index.cfm" -o -iname "Application.cfm" -o -iname "Application.cfc" \) 2>/dev/null)
		if [ -n "$index_files" ]; then
			echo "  ✓ Found index.cfm or Application.cf*"
			sites_with_index_cfm+=("$domain")
		else
			echo "  ✗ No index.cfm or Application.cf* found"
			# Check for any other .cfm files in DocumentRoot and subdirectories
			other_cfm_files=$(find "$docroot" -name "*.cfm" -type f 2>/dev/null | head -5)
			if [ -n "$other_cfm_files" ]; then
				echo "  ✓ Found other .cfm files:"
				echo "$other_cfm_files" | while read -r cfm_file; do
					echo "    - $(basename "$cfm_file") in $(dirname "$cfm_file")"
				done
				sites_with_other_cfm+=("$domain")
			else
				echo "  ✗ No .cfm files found"
				sites_without_cfm+=("$domain")
			fi
		fi
		
		echo ""
	done <<< "$domains"
}

# Function to generate summary report
generate_summary() {
	echo "=========================================="
	echo "LUCEE SITE ANALYSIS SUMMARY"
	echo "=========================================="
	echo ""
	
	echo "Sites with index.cfm or Application.cf* in DocumentRoot (${#sites_with_index_cfm[@]}):"
	for site in "${sites_with_index_cfm[@]}"; do
		echo "  - $site"
	done
	echo ""
	
	echo "Sites with other .cfm files but no index.cfm or Application.cf* (${#sites_with_other_cfm[@]}):"
	for site in "${sites_with_other_cfm[@]}"; do
		echo "  - $site"
	done
	echo ""
	
	echo "Sites with no .cfm files (${#sites_without_cfm[@]}):"
	for site in "${sites_without_cfm[@]}"; do
		echo "  - $site"
	done
	echo ""
}

# Function to save results to file
save_results() {
	local get_docroot_func=$1
	
	echo "Saving results ..."
	
	> $TXTPATH_ALL_DATA
	> $TXTPATH_ONLY_DOMAINS
	
	for site in "${sites_with_index_cfm[@]}"; do
		docroot=$($get_docroot_func "$site")
		echo "$site $docroot root" >> $TXTPATH_ALL_DATA
		echo "$site" >> $TXTPATH_ONLY_DOMAINS
	done
	for site in "${sites_with_other_cfm[@]}"; do
		docroot=$($get_docroot_func "$site")
		echo "$site $docroot nonroot" >> $TXTPATH_ALL_DATA
		echo "$site" >> $TXTPATH_ONLY_DOMAINS
	done

	echo ""
	echo "Review and if necessary edit the results file:"
	echo ""
	echo "sudo nano $TXTPATH_ALL_DATA"
	echo ""
	echo "Then run:"
	echo ""
	echo "sudo /opt/lucee/sys/upgrade-in-progress/configure-sites.sh"
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
	analyze_sites "$domains" get_docroot_debian
	generate_summary
	save_results get_docroot_debian
	
# Redhat/CentOS/AlmaLinux/etc
elif [ -d /etc/httpd/conf.d ]; then
	# RedHat/CentOS path
	domains=$(get_domains_redhat)
	analyze_sites "$domains" get_docroot_redhat
	generate_summary
	save_results get_docroot_redhat
fi

echo "DONE!"
