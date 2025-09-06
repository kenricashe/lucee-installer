#!/bin/bash

# cPanel Simulation Toggle Script
# Usage: ./tests/cpanel.sh [on|off|status]

# strict error handling because this is a test script
set -euo pipefail

IS_DEBIAN=false
IS_CPANEL=true
HTTPD_ROOT="/etc/apache2"
CONF_DIR="/etc/apache2/conf.d"

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "${SCRIPT_DIR}/../ENVIRONMENT.sh"
. "${SCRIPT_DIR}/../shared-functions.sh"

primary_config="/etc/httpd/conf/httpd.conf"
cpanel_config="/etc/apache2/conf/httpd.conf"

CPANEL_FILES=(
	"$cpanel_config"
	"/usr/local/cpanel/cpanel"
	"/usr/local/cpanel/bin/check_cpanel_module_status"
	"/scripts/rebuildhttpdconf"
	"/scripts/restartsrv_httpd"
	"/etc/apache2/conf.d/userdata/ssl/2_4"
	"/etc/apache2/conf.d/userdata/std/2_4"
)

show_usage() {
	echo "Usage: $0 [on|off|status]"
	echo ""
	echo "Commands:"
	echo "  on     - Enable cPanel simulation (create dummy files)"
	echo "  off    - Disable cPanel simulation (remove dummy files, restore originals)"
	echo "  status - Show current simulation status"
	echo ""
	echo "This script creates cPanel simulation files for testing the toolkit in a non-cPanel environment."
}

detect_real_cpanel() {
	if [ -f "/usr/local/cpanel/version" ] || \
	   [ -f "/usr/local/cpanel/cpanel.config" ] || \
	   [ -f "/usr/local/cpanel/bin/cpwrap" ] || \
	   pgrep -f "cpsrvd" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

abort_if_real_cpanel() {
	if detect_real_cpanel; then
		echo "ERROR: Real cPanel environment detected. This script is for simulation only."
		echo "Aborting to prevent damage to real cPanel installation."
		exit 1
	fi
}

# Create cPanel simulation httpd.conf with all VirtualHost blocks
create_httpd_conf() {
	if [ -f "$primary_config" ] && [ ! -f "$cpanel_config" ]; then
		echo "  Creating /etc/apache2/conf/httpd.conf for cPanel simulation"
		mkdir -p /etc/apache2/conf
		
		# Start with header comment
		cat > "$cpanel_config" << EOF
# cPanel simulation dummy file - aggregated Apache configuration for testing
# This file is created by cpanel.sh for testing purposes only
# Generated on: $(date)

EOF
		
		# Copy the primary Apache config content
		cat "$primary_config" >> "$cpanel_config"
		
		# Find and append VirtualHost blocks from other .conf files using discovery
		echo "" >> "$cpanel_config"
		echo "# Additional VirtualHost blocks discovered from Apache configuration files" >> "$cpanel_config"
		echo "" >> "$cpanel_config"
		
		# Use sites-configured.txt which already contains the list of VirtualHost files (third column)
		# First check if the file exists
		if [ -f "${SITES_FILE}" ]; then
			awk '{print $3}' "${SITES_FILE}" | sort -u | while read -r conf_file; do
				# Skip the primary config since we already included it
				if [ -f "$conf_file" ] && [ "$conf_file" != "$primary_config" ]; then
					echo "# From: $conf_file" >> "$cpanel_config"
					if awk '
						/<VirtualHost/ { in_vhost=1; vhost_content=$0 "\n"; next }
						in_vhost && /<\/VirtualHost>/ { 
							vhost_content = vhost_content $0 "\n\n"
							print vhost_content
							in_vhost=0
							vhost_content=""
							next
						}
						in_vhost { vhost_content = vhost_content $0 "\n" }
					' "$conf_file" >> "$cpanel_config" 2>/dev/null; then
						:
					else
						echo "Warning: Failed to process VirtualHost blocks from $conf_file" >&2
					fi
				fi
			done
		fi
	fi
}

# Create /usr/local/cpanel/cpanel (detection file)
create_usr_local_cpanel_cpanel() {
	mkdir -p /usr/local/cpanel
	cat > /usr/local/cpanel/cpanel << 'EOF'
#!/bin/bash
# Dummy cPanel executable for simulation
echo "cPanel simulation mode - this is not real cPanel"
exit 0
EOF
	chmod +x /usr/local/cpanel/cpanel
	echo "  Created: /usr/local/cpanel/cpanel"
}

# Create /usr/local/cpanel/bin/check_cpanel_module_status
create_check_cpanel_module_status() {
	mkdir -p /usr/local/cpanel/bin
	cat > /usr/local/cpanel/bin/check_cpanel_module_status << 'EOF'
#!/bin/bash
# cPanel module status checker simulation - wrapper for actual Apache module detection

# Parse command line arguments
MODULE=""
while [[ $# -gt 0 ]]; do
	case $1 in
		--module=*)
			MODULE="${1#*=}"
			shift
			;;
		--module)
			MODULE="$2"
			shift 2
			;;
		*)
			shift
			;;
	esac
done

if [ -z "$MODULE" ]; then
	echo "Error: No module specified"
	exit 1
fi

# Map cPanel module names to Apache module names for detection
declare -A MODULE_MAP=(
	["mod_rewrite"]="rewrite"
	["mod_headers"]="headers"
	["mod_proxy"]="proxy"
	["mod_proxy_http"]="proxy_http"
	["mod_ssl"]="ssl"
	["mod_setenvif"]="setenvif"
)

# Check if module is supported, fallback to disabled for unknown modules
if [[ -v MODULE_MAP["$MODULE"] ]]; then
	APACHE_MODULE="${MODULE_MAP[$MODULE]}"
else
	echo "${MODULE}: disabled"
	exit 1
fi

# Check if module is actually enabled using Apache commands
check_module_enabled() {
	local mod_name="$1"
	
	# Try httpd -M first (RHEL/CentOS)
	if command -v httpd >/dev/null 2>&1; then
		if httpd -M 2>/dev/null | grep -q "${mod_name}_module"; then
			return 0
		fi
	fi
	
	# Try apache2ctl -M (Debian/Ubuntu)
	if command -v apache2ctl >/dev/null 2>&1; then
		if apache2ctl -M 2>/dev/null | grep -q "${mod_name}_module"; then
			return 0
		fi
	fi
	
	# Try apachectl as fallback
	if command -v apachectl >/dev/null 2>&1; then
		if apachectl -M 2>/dev/null | grep -q "${mod_name}_module"; then
			return 0
		fi
		# Also try syntax dump method
		if apachectl -t -D DUMP_MODULES 2>/dev/null | grep -q "${mod_name}_module"; then
			return 0
		fi
	fi
	
	return 1
}

# Check the actual module status
if check_module_enabled "$APACHE_MODULE"; then
	echo "${MODULE}: enabled"
	exit 0
else
	echo "${MODULE}: disabled"
	exit 1
fi
EOF
	chmod +x /usr/local/cpanel/bin/check_cpanel_module_status
	echo "  Created: /usr/local/cpanel/bin/check_cpanel_module_status"
}

# Create /scripts/rebuildhttpdconf
create_rebuildhttpdconf() {
	mkdir -p /scripts
	cat > /scripts/rebuildhttpdconf << 'EOF'
#!/bin/bash
# Dummy cPanel Apache config rebuild script for simulation

echo "cPanel simulation: rebuildhttpdconf"
echo "  Simulating Apache configuration rebuild..."

# Detect Apache configuration directory
if [ -d "/etc/apache2" ]; then
	APACHE_CONF_DIR="/etc/apache2"
	VHOST_DIR="/etc/apache2/sites-available"
elif [ -d "/etc/httpd" ]; then
	APACHE_CONF_DIR="/etc/httpd"
	VHOST_DIR="/etc/httpd/conf.d"
else
	echo "  Warning: Apache configuration directory not found"
	exit 0
fi

USERDATA_DIR="$APACHE_CONF_DIR/conf.d/userdata"

# Function to update userdata includes in a vhost file
update_userdata_includes() {
	local vhost_file="$1"
	local domain="$2"
	local user="$3"
	
	# Check for SSL and non-SSL userdata directories
	local ssl_userdata_dir="$USERDATA_DIR/ssl/2_4/$user/$domain"
	local std_userdata_dir="$USERDATA_DIR/std/2_4/$user/$domain"
	
	# Check if userdata .conf files exist
	local has_ssl_userdata=false
	local has_std_userdata=false
	
	if [ -d "$ssl_userdata_dir" ] && [ -n "$(find "$ssl_userdata_dir" -name "*.conf" 2>/dev/null)" ]; then
		has_ssl_userdata=true
	fi
	
	if [ -d "$std_userdata_dir" ] && [ -n "$(find "$std_userdata_dir" -name "*.conf" 2>/dev/null)" ]; then
		has_std_userdata=true
	fi
	
	# Create temporary file for modifications
	local temp_file=$(mktemp)
	local modified=false
	
	while IFS= read -r line; do
		# Check for existing userdata includes
		if [[ "$line" =~ ^[[:space:]]*#?[[:space:]]*Include.*userdata.*/$domain/\*\.conf ]]; then
			# Determine if this is SSL or standard userdata
			if [[ "$line" =~ /ssl/ ]]; then
				if [ "$has_ssl_userdata" = true ]; then
					# Uncomment if commented, or keep as-is if already uncommented
					echo "${line#*#}" | sed 's/^[[:space:]]*/    /' >> "$temp_file"
					echo "    Updated SSL userdata include for $domain"
				else
					# Comment out if not commented
					if [[ ! "$line" =~ ^[[:space:]]*# ]]; then
						echo "    #$line" >> "$temp_file"
						echo "    Commented out SSL userdata include for $domain (no files found)"
					else
						echo "$line" >> "$temp_file"
					fi
				fi
			else
				if [ "$has_std_userdata" = true ]; then
					# Uncomment if commented, or keep as-is if already uncommented
					echo "${line#*#}" | sed 's/^[[:space:]]*/    /' >> "$temp_file"
					echo "    Updated standard userdata include for $domain"
				else
					# Comment out if not commented
					if [[ ! "$line" =~ ^[[:space:]]*# ]]; then
						echo "    #$line" >> "$temp_file"
						echo "    Commented out standard userdata include for $domain (no files found)"
					else
						echo "$line" >> "$temp_file"
					fi
				fi
			fi
			modified=true
		else
			echo "$line" >> "$temp_file"
		fi
	done < "$vhost_file"
	
	# Add missing userdata includes if they don't exist
	if [ "$has_ssl_userdata" = true ] && ! grep -q "userdata/ssl.*/$domain/\*\.conf" "$vhost_file"; then
		echo "    Include \"$ssl_userdata_dir/*.conf\"" >> "$temp_file"
		echo "    Added SSL userdata include for $domain"
		modified=true
	fi
	
	if [ "$has_std_userdata" = true ] && ! grep -q "userdata/std.*/$domain/\*\.conf" "$vhost_file"; then
		echo "    Include \"$std_userdata_dir/*.conf\"" >> "$temp_file"
		echo "    Added standard userdata include for $domain"
		modified=true
	fi
	
	# Replace original file if modified
	if [ "$modified" = true ]; then
		mv "$temp_file" "$vhost_file"
	else
		rm "$temp_file"
	fi
}

# Process VirtualHost files
echo "  Processing VirtualHost configurations..."

if [ -d "$VHOST_DIR" ]; then
	for vhost_file in "$VHOST_DIR"/*.conf; do
		if [ -f "$vhost_file" ]; then
			# Extract domain and user from VirtualHost configuration
			while IFS= read -r line; do
				if [[ "$line" =~ ServerName[[:space:]]+([^[:space:]]+) ]]; then
					domain="${BASH_REMATCH[1]}"
					# Try to extract user from DocumentRoot or assume from domain
					user_line=$(grep -i "DocumentRoot" "$vhost_file" | head -1)
					if [[ "$user_line" =~ /home/([^/]+)/ ]]; then
						user="${BASH_REMATCH[1]}"
					else
						# Fallback: use domain name as user
						user=$(echo "$domain" | cut -d'.' -f1)
					fi
					
					echo "  Processing $domain (user: $user)"
					update_userdata_includes "$vhost_file" "$domain" "$user"
					break
				fi
			done < "$vhost_file"
		fi
	done
fi

# Test Apache configuration
if command -v apache2ctl >/dev/null 2>&1; then
	APACHE_CMD="apache2ctl"
elif command -v httpd >/dev/null 2>&1; then
	APACHE_CMD="httpd"
else
	echo "  Warning: No Apache command found, skipping config test"
	exit 0
fi

echo "  Testing Apache configuration..."
if $APACHE_CMD -t >/dev/null 2>&1; then
	echo "  Apache configuration test: OK"
	exit 0
else
	echo "  ERROR: Apache configuration test failed"
	$APACHE_CMD -t
	exit 1
fi
EOF
	chmod +x /scripts/rebuildhttpdconf
	echo "  Created: /scripts/rebuildhttpdconf"
}

# Create /scripts/restartsrv_httpd
create_restartsrv_httpd() {
	cat > /scripts/restartsrv_httpd << 'EOF'
#!/bin/bash
# Dummy cPanel Apache restart script for simulation

echo "cPanel simulation: restartsrv_httpd $*"

# Parse arguments
GRACEFUL=false
case "$1" in
	--graceful)
		GRACEFUL=true
		;;
esac

# Determine Apache service name and control command
if systemctl is-active apache2 >/dev/null 2>&1; then
	SERVICE="apache2"
	CMD="systemctl"
elif systemctl is-active httpd >/dev/null 2>&1; then
	SERVICE="httpd"
	CMD="systemctl"
elif service apache2 status >/dev/null 2>&1; then
	SERVICE="apache2"
	CMD="service"
elif service httpd status >/dev/null 2>&1; then
	SERVICE="httpd"
	CMD="service"
else
	echo "  Warning: No Apache service found, simulating restart"
	exit 0
fi

if [ "$GRACEFUL" = true ]; then
	echo "  Performing graceful Apache restart..."
	if [ "$CMD" = "systemctl" ]; then
		systemctl reload "$SERVICE"
	else
		service "$SERVICE" reload
	fi
else
	echo "  Performing Apache restart..."
	if [ "$CMD" = "systemctl" ]; then
		systemctl restart "$SERVICE"
	else
		service "$SERVICE" restart
	fi
fi

echo "  Apache restart completed"
EOF
	chmod +x /scripts/restartsrv_httpd
	echo "  Created: /scripts/restartsrv_httpd"
}

create_dummy_files() {

	echo "Creating cPanel simulation files..."
	
	create_httpd_conf
	create_usr_local_cpanel_cpanel
	create_check_cpanel_module_status
	create_rebuildhttpdconf
	create_restartsrv_httpd

	# Create userdata directories
	mkdir -p /etc/apache2/conf.d/userdata/ssl/2_4
	mkdir -p /etc/apache2/conf.d/userdata/std/2_4
	echo "  Created: /etc/apache2/conf.d/userdata directories"
	
}

remove_dummy_files() {

	echo "Removing cPanel simulation files..."
	rm -rf /etc/apache2
	rm -rf /usr/local/cpanel
	rm -rf /scripts
}

show_status() {

	echo ""
	echo "cPanel Simulation Status:"
	echo ""
	
	if detect_real_cpanel; then
		echo ""
		echo "Oops! Real cPanel environment detected. This script is for simulation only."
		exit 0
	fi

	local all_exist=true
	for file in "${CPANEL_FILES[@]}"; do
		if [ -e "$file" ]; then
			echo "  ✓ $file (exists)"
		else
			echo "  ✗ $file (missing)"
			all_exist=false
		fi
	done
	
	echo ""
	if [ "$all_exist" = true ]; then
		echo "Status: cPanel simulation is ENABLED"
		
		# Test the detection
		if [ -f "/usr/local/cpanel/cpanel" ]; then
			echo "Detection test: cPanel would be detected as present"
		fi
	else
		echo "Status: cPanel simulation is DISABLED"
	fi
}

# Main script logic

abort_if_real_cpanel

case "${1:-}" in
	"on")
		create_dummy_files
		echo ""
		echo "✓ cPanel simulation ENABLED"
		echo ""
		echo "You can now test the toolkit in cPanel mode."
		echo "Use '$0 off' to disable simulation."
		;;
	"off")
		remove_dummy_files
		echo ""
		echo "✓ cPanel simulation DISABLED"
		;;
	"status")
		show_status
		;;
	*)
		show_usage
		exit 1
		;;
esac
