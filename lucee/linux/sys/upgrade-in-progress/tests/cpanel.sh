#!/bin/bash

# cPanel Simulation Toggle Script
# Usage: ./tests/cpanel.sh [on|off|status]

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root or with sudo."
	exit 1
fi

set -euo pipefail

CPANEL_FILES=(
	"/usr/local/cpanel/cpanel"
	"/usr/local/cpanel/bin/check_cpanel_module_status"
	"/scripts/rebuildhttpdconf"
	"/scripts/restartsrv_httpd"
)

BACKUP_DIR="/tmp/cpanel-sim-backup"

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

backup_existing_files() {
	echo "Backing up any existing files..."
	mkdir -p "$BACKUP_DIR"
	
	for file in "${CPANEL_FILES[@]}"; do
		if [ -e "$file" ]; then
			echo "  Backing up: $file"
			mkdir -p "$BACKUP_DIR$(dirname "$file")"
			cp -a "$file" "$BACKUP_DIR$file"
		fi
	done
}

restore_files() {
	if [ -d "$BACKUP_DIR" ]; then
		echo "Restoring original files..."
		for file in "${CPANEL_FILES[@]}"; do
			backup_file="$BACKUP_DIR$file"
			if [ -e "$backup_file" ]; then
				echo "  Restoring: $file"
				mkdir -p "$(dirname "$file")"
				cp -a "$backup_file" "$file"
			fi
		done
		echo "Removing backup directory..."
		rm -rf "$BACKUP_DIR"
	fi
}

create_dummy_files() {
	echo "Creating cPanel simulation files..."
	
	# Create /usr/local/cpanel/cpanel (detection file)
	mkdir -p /usr/local/cpanel
	cat > /usr/local/cpanel/cpanel << 'EOF'
#!/bin/bash
# Dummy cPanel executable for simulation
echo "cPanel simulation mode - this is not real cPanel"
exit 0
EOF
	chmod +x /usr/local/cpanel/cpanel
	echo "  Created: /usr/local/cpanel/cpanel"
	
	# Create /usr/local/cpanel/bin/check_cpanel_module_status
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
	
	# Create /scripts/rebuildhttpdconf
	mkdir -p /scripts
	cat > /scripts/rebuildhttpdconf << 'EOF'
#!/bin/bash
# Dummy cPanel Apache config rebuild script for simulation

echo "cPanel simulation: rebuildhttpdconf"
echo "  Simulating Apache configuration rebuild..."

# In real cPanel, this rebuilds the entire Apache configuration
# For simulation, we just check if Apache config is valid
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
	
	# Create /scripts/restartsrv_httpd
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

remove_dummy_files() {

	echo "Removing cPanel simulation files..."
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
	
	if [ -d "$BACKUP_DIR" ]; then
		echo ""
		echo "Backup directory exists: $BACKUP_DIR"
		echo "Original files can be restored with: $0 off"
	fi
}

# Main script logic
case "${1:-}" in
	"on")
		abort_if_real_cpanel
		backup_existing_files
		create_dummy_files
		echo ""
		echo "✓ cPanel simulation ENABLED"
		echo ""
		echo "You can now test the toolkit in cPanel mode."
		echo "Use '$0 off' to disable simulation and restore original files."
		;;
	"off")
		abort_if_real_cpanel
		remove_dummy_files
		restore_files
		echo ""
		echo "✓ cPanel simulation DISABLED"
		echo "Original files have been restored (if any existed)."
		;;
	"status")
		show_status
		;;
	*)
		show_usage
		exit 1
		;;
esac
