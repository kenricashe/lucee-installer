#!/bin/bash

# Ensure the site exclusions file exists with sensible defaults.
ensure_default_exclusions_file() {
	if [ ! -f "$EXCLUSIONS_FILE" ] || [ ! -s "$EXCLUSIONS_FILE" ]; then
		${SUDO} mkdir -p "$(dirname "$EXCLUSIONS_FILE")" 2>/dev/null || true
		${SUDO} tee "$EXCLUSIONS_FILE" >/dev/null <<'EOF'
# Lucee site search exclusions
#
# Domain patterns:
#   exact domains: example.com
#   wildcard domains: *.example.com
# Path exclusions:
#   path: /var/www/html/some-static-site

# Common non-app / platform subdomains (cPanel, etc)
localhost
cpanel
whm
webmail
webdisk
mail
default
localhost
_wildcard_

# cPanel and control panel vhosts
proxy-subdomains-vhost

# Path exclusions (examples)
# path: /var/www/html/default
EOF
	fi
}

# Helper functions for handling newlines in different file creation scenarios

# Backup helper: mirror source path under ${BACKUP_ROOT}/${BACKUP_TS}
# Usage: backup_file /path/to/file
backup_file() {
	local src="$1"
	[ -f "$src" ] || return 0
	
	# Set backup variables if not already set
	: ${BACKUP_ROOT:="${UPG_DIR}/backups"}
	: ${BACKUP_TS:="$(date +%Y-%m-%d-%H%M%S)"}
	
	local dest="${BACKUP_ROOT}/${BACKUP_TS}${src}"
	
	# Skip if backup already exists for this timestamp
	[ -f "$dest" ] && return 0
	
	local dest_dir
	dest_dir=$(dirname "$dest")
	mkdir -p "$dest_dir"
	cp -f "$src" "$dest"
	
	# Return success if backup was created
	[ -f "$dest" ]
}

backup_folder() {
	local src="$1"
	
	# Set backup variables if not already set
	: ${BACKUP_ROOT:="${UPG_DIR}/backups"}
	: ${BACKUP_TS:="$(date +%Y-%m-%d-%H%M%S)"}
	
	local dest_dir
	dest_dir="${BACKUP_ROOT}/${BACKUP_TS}${src}"
	mkdir -p "$dest_dir"
	
	# Copy contents of source directory to destination
	cp -rf "$src/"* "$dest_dir/" 2>/dev/null || true
	
	# Return success if backup was created
	[ -d "$dest_dir" ]
}

# Helper function to strip all trailing newlines from a string
# Returns the cleaned string via echo
strip_trailing_newlines() {
	local content="$1"
	
	# Remove all trailing newlines
	while [ -n "$content" ] && [ "${content: -1}" = $'\n' ]; do
		content="${content%$'\n'}"
	done
	
	echo "$content"
}

# Write content to a file with exactly one newline at EOF
write_with_single_newline() {
	local content="$1"
	local file="$2"
	
	# Strip trailing newlines and add exactly one
	content=$(strip_trailing_newlines "$content")
	printf "%s\n" "$content" > "$file"
}

# Append content to a file with exactly one newline
append_with_single_newline() {
	local content="$1"
	local file="$2"
	
	# Strip trailing newlines and add exactly one
	content=$(strip_trailing_newlines "$content")
	printf "%s\n" "$content" >> "$file"
}

# Function to normalize whitespace in any configuration file
normalize_conf_whitespace() {
	local conf_file="$1"
	[ -f "$conf_file" ] || return 1
	
	# SAFETY CHECK: Make a backup first
	backup_file "$conf_file"
	
	local tmp
	tmp=$(mktemp)
	
	# Use cat to ensure we don't lose content
	cat "$conf_file" > "$tmp"
	
	# Only trim trailing whitespace - safer operation
	sed -i 's/[ \t]*$//' "$tmp"
	
	# Ensure exactly one newline at EOF (safer approach)
	if [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | wc -l)" -eq 0 ]; then
		# No newline at end, add one
		printf "\n" >> "$tmp"
	fi
	
	# If tmp is empty, don't proceed with the change
	if [ ! -s "$tmp" ]; then
		echo "ERROR: Empty output when processing $conf_file - ABORTING CHANGE"
		# Just clean up the temp file and return error
		rm -f "$tmp"
		return 1
	fi

	# Only overwrite if content changed
	if cmp -s "$conf_file" "$tmp"; then
		rm -f "$tmp"
		return 0
	fi

	# Preserve original permissions before overwriting
	local orig_perms
	orig_perms=$(stat -c %a "$conf_file" 2>/dev/null || echo "644")
	mv "$tmp" "$conf_file"
	chmod "$orig_perms" "$conf_file" 2>/dev/null || chmod 644 "$conf_file"
}

# Function to disable and remove an Apache configuration file
disable_and_remove_conf() {
	local conf_name="$1"
	local conf_path="/etc/apache2/conf-available/${conf_name}.conf"
	disable_conf "$conf_name"
	rm -f "$conf_path"
}

# Function to enable an Apache configuration file
enable_conf() {
	local conf_name="$1"
	local conf_path="/etc/apache2/conf-available/${conf_name}.conf"
	
	if [ ! -f "$conf_path" ]; then
		echo "ERROR: ${conf_name}.conf does not exist at $conf_path"
		return 1
	fi
	
	echo "Enabling ${conf_name}.conf..."
	if a2enconf "$conf_name" >/dev/null 2>&1; then
		echo "  - Successfully enabled ${conf_name}.conf"
		return 0
	else
		echo "  - Failed to enable ${conf_name}.conf"
		return 1
	fi
}

disable_conf() {
	local conf_name="$1"
	echo "Disabling ${conf_name}.conf..."
	if a2disconf "$conf_name" >/dev/null 2>&1; then
		echo "  - Successfully disabled ${conf_name}.conf"
		return 0
	else
		echo "  - ${conf_name}.conf was already disabled or not found"
		return 1
	fi
}

# ============================================================================
# Apache Configuration Discovery Functions
# ============================================================================

# Discover all Apache configuration files that contain Lucee upgrade-related content
# Returns: JSON-formatted data about discovered configurations
discover_apache_configs() {
	local output_format="${1:-json}"  # json, text, or paths-only
	local show_progress="${2:-false}"  # true to show progress messages
	local temp_file
	temp_file=$(mktemp)
	
	# Initialize discovery results
	local -A discovered_configs
	local -a vhost_files
	local -a proxy_configs
	local -a upgrade_configs
	local -a modified_htaccess
	local -a upgrade_html_files
	local -a site_includes
	local -a modified_primary_configs
	local -a legacy_files
	
	# Determine Apache configuration directories based on distribution
	local apache_dirs=()
	if [ "$IS_DEBIAN" = true ]; then
		apache_dirs=("/etc/apache2")
	elif [ "$IS_CPANEL" = true ]; then
		apache_dirs=("/usr/local/apache/conf" "/etc/apache2" "/etc/httpd")
	else
		apache_dirs=("/etc/httpd" "/etc/apache2")
	fi
	
	# Add any additional directories from ENVIRONMENT.sh
	[ -n "$CONF_DIR" ] && apache_dirs+=("$CONF_DIR")
	[ -n "$SITES_AVAILABLE_DIR" ] && apache_dirs+=("$(dirname "$SITES_AVAILABLE_DIR")")
	
	# Search for configuration files
	for apache_dir in "${apache_dirs[@]}"; do
		[ -d "$apache_dir" ] || continue
		
		if [ "$show_progress" = "true" ]; then
			echo "Scanning Apache directory: $apache_dir" >&2
		fi
		
		# Find VirtualHost files with upgrade-related Include directives
		# Only check sites-available and sites-enabled directories for actual VirtualHost files
		for vhost_dir in "$apache_dir/sites-available" "$apache_dir/sites-enabled"; do
			if [ -d "$vhost_dir" ]; then
				while IFS= read -r -d '' vhost_file; do
					if grep -q "Include.*upgrade-in-progress.*lucee-detect-upgrade\.conf" "$vhost_file" 2>/dev/null; then
						vhost_files+=("$vhost_file")
					fi
				done < <(find "$vhost_dir" -maxdepth 1 -type f -name "*.conf" -print0 2>/dev/null)
			fi
		done
		
		# Find lucee-proxy.conf files
		while IFS= read -r -d '' proxy_file; do
			proxy_configs+=("$proxy_file")
		done < <(find "$apache_dir" -type f -name "*lucee-proxy*" -print0 2>/dev/null)
		
		# Find upgrade-in-progress configuration files
		while IFS= read -r -d '' upgrade_file; do
			upgrade_configs+=("$upgrade_file")
		done < <(find "$apache_dir" -type f -name "*upgrade-in-progress*" -print0 2>/dev/null)
	done
	
	# Search for modified .htaccess files (containing commented ErrorDocument 404)
	if [ "$show_progress" = "true" ]; then
		echo "Checking .htaccess files in DocumentRoots..." >&2
	fi
	
	# Use associative array to avoid duplicates
	local -A seen_htaccess
	
	# Check all Apache directories for VirtualHost files to find DocumentRoots
	for apache_dir in "${apache_dirs[@]}"; do
		[ -d "$apache_dir" ] || continue
		
		# Look in sites-available directories
		for sites_dir in "$apache_dir/sites-available" "$apache_dir/sites-enabled"; do
			if [ -d "$sites_dir" ]; then
				for vhost_file in "$sites_dir"/*.conf; do
					[ -f "$vhost_file" ] || continue
					local docroot
					docroot=$(grep -i '^[[:space:]]*DocumentRoot' "$vhost_file" | head -1 | awk '{print $2}' | tr -d '"')
					if [ -n "$docroot" ] && [ -f "${docroot}/.htaccess" ] && [ -z "${seen_htaccess["${docroot}/.htaccess"]}" ]; then
						if grep -q "# NOTE: ErrorDocument 404 moved\|# ErrorDocument.*404.*\.cfm" "${docroot}/.htaccess" 2>/dev/null; then
							modified_htaccess+=("${docroot}/.htaccess")
							seen_htaccess["${docroot}/.htaccess"]=1
						fi
					fi
				done
			fi
		done
	done
	
	# Search for upgrade-in-progress.html files in DocumentRoots
	if [ "$show_progress" = "true" ]; then
		echo "Searching for upgrade HTML files..." >&2
	fi
	
	# Use associative array to avoid duplicates
	local -A seen_html
	
	# First, search in known DocumentRoots from VirtualHost files
	for apache_dir in "${apache_dirs[@]}"; do
		[ -d "$apache_dir" ] || continue
		
		for sites_dir in "$apache_dir/sites-available" "$apache_dir/sites-enabled"; do
			if [ -d "$sites_dir" ]; then
				for vhost_file in "$sites_dir"/*.conf; do
					[ -f "$vhost_file" ] || continue
					local docroot
					docroot=$(grep -i '^[[:space:]]*DocumentRoot' "$vhost_file" | head -1 | awk '{print $2}' | tr -d '"')
					if [ -n "$docroot" ] && [ -f "${docroot}/lucee-upgrade-in-progress.html" ] && [ -z "${seen_html["${docroot}/lucee-upgrade-in-progress.html"]}" ]; then
						upgrade_html_files+=("${docroot}/lucee-upgrade-in-progress.html")
						seen_html["${docroot}/lucee-upgrade-in-progress.html"]=1
					fi
				done
			fi
		done
	done
	
	# Also do a broader search in common web directories
	while IFS= read -r -d '' html_file; do
		if [ -z "${seen_html["$html_file"]}" ]; then
			upgrade_html_files+=("$html_file")
			seen_html["$html_file"]=1
		fi
	done < <(find /var/www /home -maxdepth 3 -name "*upgrade-in-progress.html" -type f 2>/dev/null | head -10)
	
	# Search for per-site include directories (avoid duplicates)
	local include_dirs=()
	local -A seen_dirs
	
	if [ -n "$UPG_DIR" ] && [ -d "${UPG_DIR}/site-includes-for-404" ]; then
		include_dirs+=("${UPG_DIR}/site-includes-for-404")
		seen_dirs["${UPG_DIR}/site-includes-for-404"]=1
	fi
	
	if [ -d "/opt/lucee/sys/upgrade-in-progress/site-includes-for-404" ] && [ -z "${seen_dirs['/opt/lucee/sys/upgrade-in-progress/site-includes-for-404']}" ]; then
		include_dirs+=("/opt/lucee/sys/upgrade-in-progress/site-includes-for-404")
	fi
	
	for include_dir in "${include_dirs[@]}"; do
		if [ "$show_progress" = "true" ]; then
			echo "Checking per-site includes: $include_dir" >&2
		fi
		while IFS= read -r -d '' include_file; do
			site_includes+=("$include_file")
		done < <(find "$include_dir" -type f -name "*.conf" -print0 2>/dev/null)
	done
	
	# Check primary Apache configuration files for modifications
	if [ "$show_progress" = "true" ]; then
		echo "Checking primary Apache configuration files..." >&2
	fi
	
	local primary_config
	if primary_config=$(find_primary_apache_config); then
		if has_lucee_proxy_config "$primary_config"; then
			modified_primary_configs+=("$primary_config")
		fi
	fi
	
	# Sort all arrays alphabetically
	if [ ${#vhost_files[@]} -gt 0 ]; then
		IFS=$'\n' vhost_files=($(sort <<<"${vhost_files[*]}"))
	fi
	if [ ${#proxy_configs[@]} -gt 0 ]; then
		IFS=$'\n' proxy_configs=($(sort <<<"${proxy_configs[*]}"))
	fi
	if [ ${#upgrade_configs[@]} -gt 0 ]; then
		IFS=$'\n' upgrade_configs=($(sort <<<"${upgrade_configs[*]}"))
	fi
	if [ ${#modified_htaccess[@]} -gt 0 ]; then
		IFS=$'\n' modified_htaccess=($(sort <<<"${modified_htaccess[*]}"))
	fi
	if [ ${#upgrade_html_files[@]} -gt 0 ]; then
		IFS=$'\n' upgrade_html_files=($(sort <<<"${upgrade_html_files[*]}"))
	fi
	if [ ${#site_includes[@]} -gt 0 ]; then
		IFS=$'\n' site_includes=($(sort <<<"${site_includes[*]}"))
	fi
	if [ ${#modified_primary_configs[@]} -gt 0 ]; then
		IFS=$'\n' modified_primary_configs=($(sort <<<"${modified_primary_configs[*]}"))
	fi
	
	# Search for legacy files from older versions of the upgrade system
	if [ "$show_progress" = "true" ]; then
		echo "Searching for legacy upgrade files..." >&2
	fi
	
	# Legacy files in Apache conf directories
	for apache_dir in "${apache_dirs[@]}"; do
		[ -d "$apache_dir" ] || continue
		
		# Legacy files in conf.d
		if [ -d "$apache_dir/conf.d" ]; then
			# Old lucee-ajp-and-mod_cfml.conf (now lucee-proxy.conf)
			if [ -f "$apache_dir/conf.d/lucee-ajp-and-mod_cfml.conf" ]; then
				legacy_files+=("$apache_dir/conf.d/lucee-ajp-and-mod_cfml.conf")
			fi
			
			# Disabled upgrade config
			if [ -f "$apache_dir/conf.d/lucee-upgrade-in-progress.disabled" ]; then
				legacy_files+=("$apache_dir/conf.d/lucee-upgrade-in-progress.disabled")
			fi
			
			# cPanel userdata upgrade configs
			if [ -d "$apache_dir/conf.d/userdata" ]; then
				while IFS= read -r -d '' userdata_file; do
					legacy_files+=("$userdata_file")
				done < <(find "$apache_dir/conf.d/userdata" -name "*upgrade-in-progress*" -type f -print0 2>/dev/null)
			fi
		fi
	done
	
	# Legacy files in /opt/lucee/sys (pre-upgrade-in-progress subdirectory)
	if [ -d "/opt/lucee/sys" ]; then
		local legacy_patterns=(
			"configure-sites-for-upgrade-in-progress.sh"
			"get-lucee-sites-for-upgrade-in-progress.sh"
			"sites-configured-for-upgrade-in-progress.txt"
			"upgrade-in-progress.html"
			"upgrade-in-progress-nonroot.conf"
			"upgrade-in-progress-root.conf"
			"upgrade-in-progress.sh"
		)
		
		for pattern in "${legacy_patterns[@]}"; do
			if [ -f "/opt/lucee/sys/$pattern" ]; then
				legacy_files+=("/opt/lucee/sys/$pattern")
			fi
		done
	fi
	
	# Sort legacy files
	if [ ${#legacy_files[@]} -gt 0 ]; then
		IFS=$'\n' legacy_files=($(sort <<<"${legacy_files[*]}"))
	fi
	
	# Generate output based on format
	case "$output_format" in
		"json")
			cat > "$temp_file" <<EOF
{
	"discovery_timestamp": "$(date -Iseconds)",
	"environment": {
		"is_debian": $IS_DEBIAN,
		"is_cpanel": $IS_CPANEL,
		"lucee_root": "$LUCEE_ROOT",
		"upgrade_dir": "$UPG_DIR"
	},
	"vhost_files": [
$(printf '		"%s"' "${vhost_files[@]}" | sed 's/$/,/' | sed '$s/,$//')
	],
	"proxy_configs": [
$(printf '		"%s"' "${proxy_configs[@]}" | sed 's/$/,/' | sed '$s/,$//')
	],
	"upgrade_configs": [
$(printf '		"%s"' "${upgrade_configs[@]}" | sed 's/$/,/' | sed '$s/,$//')
	],
	"modified_htaccess": [
$(printf '		"%s"' "${modified_htaccess[@]}" | sed 's/$/,/' | sed '$s/,$//')
	],
	"upgrade_html_files": [
$(printf '		"%s"' "${upgrade_html_files[@]}" | sed 's/$/,/' | sed '$s/,$//')
	],
	"site_includes": [
$(printf '\t\t"%s"' "${site_includes[@]}" | sed 's/$/,/' | sed '$s/,$//')
	],
	"modified_primary_configs": [
$(printf '\t\t"%s"' "${modified_primary_configs[@]}" | sed 's/$/,/' | sed '$s/,$//')
	],
	"legacy_files": [
$(printf '\t\t"%s"' "${legacy_files[@]}" | sed 's/$/,/' | sed '$s/,$//')
	]
}
EOF
			;;
		"text")
			{
				echo "Apache Configuration Discovery Report"
				echo "Generated: $(date)"
				echo ""
				echo "Environment:"
				echo "  Debian: $IS_DEBIAN"
				echo "  cPanel: $IS_CPANEL"
				echo "  Lucee Root: $LUCEE_ROOT"
				echo "  Upgrade Dir: $UPG_DIR"
				echo ""
				echo "Modified primary Apache configs (${#modified_primary_configs[@]}):"
				printf "  %s\n" "${modified_primary_configs[@]}"
				echo ""
				echo "VirtualHost files with upgrade modifications (${#vhost_files[@]}):"
				printf "  %s\n" "${vhost_files[@]}"
				echo ""
				echo "Lucee proxy configuration files (${#proxy_configs[@]}):"
				printf "  %s\n" "${proxy_configs[@]}"
				echo ""
				echo "Upgrade-in-progress configuration files (${#upgrade_configs[@]}):"
				printf "  %s\n" "${upgrade_configs[@]}"
				echo ""
				echo "Modified .htaccess files (${#modified_htaccess[@]}):"
				printf "  %s\n" "${modified_htaccess[@]}"
				echo ""
				echo "Upgrade HTML files (${#upgrade_html_files[@]}):"
				printf "  %s\n" "${upgrade_html_files[@]}"
				echo ""
				echo "Per-site include files (${#site_includes[@]}):"
				printf "  %s\n" "${site_includes[@]}"
				echo ""
				echo "Legacy files from older versions (${#legacy_files[@]}):"
				printf "  %s\n" "${legacy_files[@]}"
			} > "$temp_file"
			;;
		"paths-only")
			{
				printf "%s\n" "${vhost_files[@]}"
				printf "%s\n" "${proxy_configs[@]}"
				printf "%s\n" "${upgrade_configs[@]}"
				printf "%s\n" "${modified_htaccess[@]}"
				printf "%s\n" "${upgrade_html_files[@]}"
				printf "%s\n" "${site_includes[@]}"
				printf "%s\n" "${modified_primary_configs[@]}"
			printf "%s\n" "${legacy_files[@]}"
			} > "$temp_file"
			;;
	esac
	
	cat "$temp_file"
	rm -f "$temp_file"
}

# Get detailed information about a specific VirtualHost configuration
# Usage: get_vhost_details /path/to/vhost.conf
get_vhost_details() {
	local vhost_file="$1"
	[ -f "$vhost_file" ] || return 1
	
	local temp_file
	temp_file=$(mktemp)
	
	# Extract key information from VirtualHost
	local server_name
	local server_alias
	local document_root
	local port
	local has_upgrade_blocks=false
	local has_includes=false
	
	server_name=$(grep -i '^[[:space:]]*ServerName' "$vhost_file" | head -1 | awk '{print $2}' | tr -d '"')
	server_alias=$(grep -i '^[[:space:]]*ServerAlias' "$vhost_file" | awk '{for(i=2;i<=NF;i++) printf "%s ", $i}' | sed 's/ $//')
	document_root=$(grep -i '^[[:space:]]*DocumentRoot' "$vhost_file" | head -1 | awk '{print $2}' | tr -d '"')
	port=$(grep -oE ':[0-9]+>' "$vhost_file" | head -1 | tr -d ':>')
	
	if grep -q "LUCEE_UPGRADE_IN_PROGRESS" "$vhost_file" 2>/dev/null; then
		has_upgrade_blocks=true
	fi
	
	if grep -q "Include.*upgrade-in-progress" "$vhost_file" 2>/dev/null; then
		has_includes=true
	fi
	
	cat > "$temp_file" <<EOF
{
	"file_path": "$vhost_file",
	"server_name": "$server_name",
	"server_alias": "$server_alias",
	"document_root": "$document_root",
	"port": "${port:-80}",
	"has_upgrade_blocks": $has_upgrade_blocks,
	"has_upgrade_includes": $has_includes,
	"file_size": $(stat -c%s "$vhost_file" 2>/dev/null || echo 0),
	"last_modified": "$(stat -c%Y "$vhost_file" 2>/dev/null || echo 0)"
}
EOF
	
	cat "$temp_file"
	rm -f "$temp_file"
}

# Find the primary Apache configuration file for the current system
# Returns the path to httpd.conf, apache2.conf, etc.
find_primary_apache_config() {
	local primary_config=""
	
	if [ "$IS_DEBIAN" = true ]; then
		primary_config="/etc/apache2/apache2.conf"
	elif [ "$IS_CPANEL" = true ]; then
		# cPanel typically uses httpd.conf
		if [ -f "/usr/local/apache/conf/httpd.conf" ]; then
			primary_config="/usr/local/apache/conf/httpd.conf"
		elif [ -f "/etc/httpd/conf/httpd.conf" ]; then
			primary_config="/etc/httpd/conf/httpd.conf"
		fi
	else
		# RHEL/CentOS
		primary_config="/etc/httpd/conf/httpd.conf"
	fi
	
	# Verify the file exists
	if [ -f "$primary_config" ]; then
		echo "$primary_config"
		return 0
	else
		return 1
	fi
}

# Check if a file contains Lucee proxy configuration
# Usage: has_lucee_proxy_config /path/to/config/file
has_lucee_proxy_config() {
	local config_file="$1"
	[ -f "$config_file" ] || return 1
	
	# Look for common Lucee proxy patterns
	if grep -qi 'ProxyPassMatch.*\.cf[mc]\|ProxyPassMatch.*\.lucee\|ProxyPass.*:8888\|ProxyPass.*ajp:' "$config_file" 2>/dev/null; then
		return 0
	else
		return 1
	fi
}
