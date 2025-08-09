#!/bin/bash

# chmod +x /path/to/this/script/deploy-to-opt-lucee-sys.sh
# sudo /path/to/this/script/deploy-to-opt-lucee-sys.sh

# require root
if [ "$(id -u)" != "0" ]; then
echo "This script must be run as root or with sudo."
exit 1
fi

THISPATH=$(dirname "$0")

FILES=(
	"get-lucee-sites.sh"
	"configure-sites.sh"
	"upgrade-in-progress.sh"
	"begin.sh"
	"end.sh"
	"upgrade-in-progress.html"
	"lucee-404-routing.conf"
	"lucee-detect-upgrade.conf"
)

# Create required directories
mkdir -p /opt/lucee/sys/apache-configs
mkdir -p /opt/lucee/sys/upgrade-in-progress

function copy_and_chmod() {
	if [[ "$1" == *.conf ]]; then
		# Copy .conf files to apache-configs directory
		cp ${THISPATH}/$1 /opt/lucee/sys/apache-configs/$1
		chmod 644 /opt/lucee/sys/apache-configs/$1
	else
		# Copy other files to upgrade-in-progress directory
		cp ${THISPATH}/$1 /opt/lucee/sys/upgrade-in-progress/$1
		chmod +x /opt/lucee/sys/upgrade-in-progress/$1
	fi
}

for file in "${FILES[@]}"; do
	copy_and_chmod "$file"
done
