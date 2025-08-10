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

# Match any local ErrorDocument 404 pointing to a .cf* target (cfm/cfml/cfc/cfs), case-insensitive
# Used to classify sites as with404/no404
ERROR404_REGEX='^[[:space:]]*ErrorDocument[[:space:]]+404[[:space:]]+/[^[:space:]]*\.(cfm|cfml|cfc|cfs)([^[:alnum:]_]|$)'

# Function to analyze sites and detect presence of local 404 ErrorDocument directive
analyze_sites() {
	local domains=$1
	local get_docroot_func=$2

	# Arrays to store categorized sites
	sites_with_local_404=()
	sites_without_local_404=()

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

		# Detect directive in vhost/.htaccess, platform-aware
		has404=false
		if command -v a2enconf >/dev/null 2>&1; then
			# Debian/Ubuntu: check -ssl and non-ssl vhost files and docroot .htaccess
			ssl_conf_file="/etc/apache2/sites-available/${domain}-ssl.conf"
			if [ ! -f "$ssl_conf_file" ]; then
				ssl_conf_file=$(grep -l "ServerName $domain" /etc/apache2/sites-available/*-ssl.conf 2>/dev/null | head -1)
			fi
			if [ -f "$ssl_conf_file" ] && grep -qiE "$ERROR404_REGEX" "$ssl_conf_file"; then
				has404=true
			fi
			if [ "$has404" = false ]; then
				http_conf_file="/etc/apache2/sites-available/${domain}.conf"
				if [ ! -f "$http_conf_file" ]; then
					http_conf_file=$(grep -l "ServerName $domain" /etc/apache2/sites-available/*.conf 2>/dev/null | grep -v -- '-ssl\.conf' | head -1)
				fi
				if [ -f "$http_conf_file" ] && grep -qiE "$ERROR404_REGEX" "$http_conf_file"; then
					has404=true
				fi
			fi
			if [ "$has404" = false ] && [ -f "$docroot/.htaccess" ]; then
				if grep -qiE "$ERROR404_REGEX" "$docroot/.htaccess"; then
					has404=true
				fi
			fi
		elif [ "$IS_CPANEL" = true ]; then
			# cPanel: check userdata includes and docroot .htaccess
			user=$(echo "$docroot" | awk -F '/' '{print $3}')
			ssl_dir="/etc/apache2/conf.d/userdata/ssl/2_4/${user}/${domain}"
			std_dir="/etc/apache2/conf.d/userdata/std/2_4/${user}/${domain}"
			if [ -d "$ssl_dir" ] && grep -Rqs -i -E "$ERROR404_REGEX" "$ssl_dir"; then
				has404=true
			elif [ -d "$std_dir" ] && grep -Rqs -i -E "$ERROR404_REGEX" "$std_dir"; then
				has404=true
			elif [ -f "$docroot/.htaccess" ] && grep -qiE "$ERROR404_REGEX" "$docroot/.htaccess"; then
				has404=true
			fi
		else
			# Non-cPanel RHEL not fully implemented; best-effort: docroot .htaccess
			if [ -f "$docroot/.htaccess" ] && grep -qiE "$ERROR404_REGEX" "$docroot/.htaccess"; then
				has404=true
			fi
		fi

		if [ "$has404" = true ]; then
			echo "  Found local 404 ErrorDocument directive"
			sites_with_local_404+=("$domain")
		else
			echo "  No local 404 ErrorDocument directive found"
			sites_without_local_404+=("$domain")
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

	echo "Sites WITH local 404 ErrorDocument (${#sites_with_local_404[@]}):"
	for site in "${sites_with_local_404[@]}"; do
		echo "  - $site"
	done
	echo ""

	echo "Sites WITHOUT local 404 ErrorDocument (${#sites_without_local_404[@]}):"
	for site in "${sites_without_local_404[@]}"; do
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

	for site in "${sites_with_local_404[@]}"; do
		docroot=$($get_docroot_func "$site")
		echo "$site $docroot with404" >> $TXTPATH_ALL_DATA
		echo "$site" >> $TXTPATH_ONLY_DOMAINS
	done
	for site in "${sites_without_local_404[@]}"; do
		docroot=$($get_docroot_func "$site")
		echo "$site $docroot no404" >> $TXTPATH_ALL_DATA
		echo "$site" >> $TXTPATH_ONLY_DOMAINS
	done

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
