#!/bin/bash

# sudo /opt/lucee/sys/get-lucee-sites-for-upgrade-in-progress.sh

# require root
if [ "$(id -u)" != "0" ]; then
echo "This script must be run as root"
exit 1
fi

# Debian/Ubuntu/etc
if command -v a2enconf >/dev/null 2>&1; then
	echo "Analyzing Lucee sites..."
	# Get list of domains from enabled sites
	# Only include SSL sites (-ssl.conf) and exclude 000-default-ssl.conf
	enabled_ssl_sites=$(a2query -s | grep -v '^000-default' | grep -E '.*-ssl' | cut -d' ' -f1 | sed 's/-ssl$//')
	domains=$(for site in $enabled_ssl_sites; do
		conf_file="/etc/apache2/sites-enabled/${site}-ssl.conf"
		if [ -f "$conf_file" ]; then
			grep -i 'ServerName' "$conf_file" | awk '{print $2}'
		fi
	done | sort -u)

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
		
		# Find DocumentRoot for this domain
		conf_file=$(grep -l "ServerName $domain" /etc/apache2/sites-enabled/*-ssl.conf 2>/dev/null | head -1)
		docroot=$(grep -A 10 -B 5 "ServerName $domain" "$conf_file" | grep -i "DocumentRoot" | awk '{print $2}' | head -1)
		
		if [ -z "$docroot" ] || [ ! -d "$docroot" ]; then
			echo "  Warning: Could not find DocumentRoot for $domain or directory does not exist"
			continue
		fi
		
		echo "  DocumentRoot: $docroot"
		
		# Check for index.cfm or Application.cf* in DocumentRoot or any subfolder
		index_files=$(find "$docroot" -name "index.cfm" -o -name "Application.cfm" -o -name "Application.cfc" 2>/dev/null)
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
	
	# Summary report
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

	# Save space-delimited file with three columns: domain DocumentRoot site_type
	# where site_type is root (for index.cfm or Application.cf* in DocumentRoot)
	# or nonroot (for any other .cfm files in DocumentRoot or subfolders)
	
	echo "Saving to: /opt/lucee/sys/sites-configured-for-upgrade-in-progress.txt"
	
	> /opt/lucee/sys/sites-configured-for-upgrade-in-progress.txt
	
	for site in "${sites_with_index_cfm[@]}"; do
		conf_file=$(grep -l "ServerName $site" /etc/apache2/sites-enabled/*-ssl.conf 2>/dev/null | head -1)
		docroot=$(grep -A 10 -B 5 "ServerName $site" "$conf_file" | grep -i "DocumentRoot" | awk '{print $2}' | head -1)
		echo "$site $docroot root" >> /opt/lucee/sys/sites-configured-for-upgrade-in-progress.txt
	done
	for site in "${sites_with_other_cfm[@]}"; do
		conf_file=$(grep -l "ServerName $site" /etc/apache2/sites-enabled/*-ssl.conf 2>/dev/null | head -1)
		docroot=$(grep -A 10 -B 5 "ServerName $site" "$conf_file" | grep -i "DocumentRoot" | awk '{print $2}' | head -1)
		echo "$site $docroot nonroot" >> /opt/lucee/sys/sites-configured-for-upgrade-in-progress.txt
	done

	echo ""
	echo "Review and if necessary edit that file, then run:"
	echo ""
	echo "sudo /opt/lucee/sys/configure-sites-for-upgrade-in-progress.sh"
	echo ""

# Redhat/CentOS/AlmaLinux/etc
elif [ -d /etc/httpd/conf.d ]; then
	echo "Analyzing Lucee sites..."
	
	# Get list of domains
	domains=$(grep -i 'ServerName' /etc/apache2/conf/httpd.conf | awk '{print $2}' | grep -vE '^(cpanel|webmail|whm|mail|webdisk|default|bounce|_wildcard_|proxy-subdomains-vhost|acpaneltest|mta1|news)(\.|$)' | sort -u)
	
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
		
		# Find DocumentRoot for this domain
		docroot=$(grep -A 10 -B 5 "ServerName $domain" /etc/apache2/conf/httpd.conf | grep -i "DocumentRoot" | awk '{print $2}' | head -1)
		
		if [ -z "$docroot" ] || [ ! -d "$docroot" ]; then
			echo "  Warning: Could not find DocumentRoot for $domain or directory does not exist"
			continue
		fi
		
		echo "  DocumentRoot: $docroot"
		
		# Check for index.cfm or Application.cf* in DocumentRoot or any subfolder
		index_files=$(find "$docroot" -name "index.cfm" -o -name "Application.cfm" -o -name "Application.cfc" 2>/dev/null)
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
	
	# Summary report
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

	# Save space-delimited file with three columns: domain DocumentRoot site_type
	# where site_type is root (for index.cfm or Application.cf* in DocumentRoot)
	# or nonroot (for any other .cfm files in DocumentRoot or subfolders)

	# Expected .txt file contents:

	# domain DocumentRoot site_type
	# 3legtorso.com /home/threelegtorso/public_html root
	# etc ...
	# furious.com /home/furious/public_html nonroot
	# etc ...

	echo "Saving to: /opt/lucee/sys/sites-configured-for-upgrade-in-progress.txt"
	
	for site in "${sites_with_index_cfm[@]}"; do
		docroot=$(grep -A 10 -B 5 "ServerName $site" /etc/apache2/conf/httpd.conf | grep -i "DocumentRoot" | awk '{print $2}' | head -1)
		echo "$site $docroot root" >> /opt/lucee/sys/sites-configured-for-upgrade-in-progress.txt
	done
	for site in "${sites_with_other_cfm[@]}"; do
		docroot=$(grep -A 10 -B 5 "ServerName $site" /etc/apache2/conf/httpd.conf | grep -i "DocumentRoot" | awk '{print $2}' | head -1)
		echo "$site $docroot nonroot" >> /opt/lucee/sys/sites-configured-for-upgrade-in-progress.txt
	done

	echo ""
	echo "Review and if necessary edit that file, then run:"
	echo ""
	echo "sudo /opt/lucee/sys/configure-sites-for-upgrade-in-progress.sh"
	echo ""

fi

# /etc/apache2/conf.d/userdata/std/2_4/${user}/${domain}/upgrade-in-progress.conf

echo "DONE!"
