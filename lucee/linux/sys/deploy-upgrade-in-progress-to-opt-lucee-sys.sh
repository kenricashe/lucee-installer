#!/bin/bash

# chmod +x /path/to/this/script/deploy-upgrade-in-progress-to-opt-lucee-sys.sh
# sudo /path/to/this/script/deploy-upgrade-in-progress-to-opt-lucee-sys.sh

# require root
if [ "$(id -u)" != "0" ]; then
echo "This script must be run as root or with sudo."
exit 1
fi

THISPATH=$(dirname "$0")

FILES=(
	"get-lucee-sites-for-upgrade-in-progress.sh"
	"configure-sites-for-upgrade-in-progress.sh"
	"upgrade-in-progress.sh"
	"upgrade-in-progress.html"
	"lucee-404-routing.conf"
	"lucee-detect-upgrade.conf"
)

# Create apache-configs directory
mkdir -p /opt/lucee/sys/apache-configs

function copy_and_chmod() {
	if [[ "$1" == *.conf ]]; then
		# Copy .conf files to apache-configs directory
		cp ${THISPATH}/$1 /opt/lucee/sys/apache-configs/$1
		chmod 644 /opt/lucee/sys/apache-configs/$1
	else
		# Copy other files to main sys directory
		cp ${THISPATH}/$1 /opt/lucee/sys/$1
		chmod +x /opt/lucee/sys/$1
	fi
}

for file in "${FILES[@]}"; do
	copy_and_chmod "$file"
done
