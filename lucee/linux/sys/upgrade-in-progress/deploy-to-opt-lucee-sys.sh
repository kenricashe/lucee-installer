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
	"begin.sh"
	"end.sh"
	"upgrade-in-progress.html"
	"lucee-404-routing.conf"
	"lucee-detect-upgrade.conf"
	"lucee-ajp-and-mod_cfml.conf"
	"lucee-upgrade-in-progress.conf"
)

# Create required directories
mkdir -p /opt/lucee/sys/upgrade-in-progress

function copy_and_chmod() {
	local src="${THISPATH}/$1"
	local dst="/opt/lucee/sys/upgrade-in-progress/$1"
	cp "$src" "$dst"
	if [[ "$1" == *.sh ]]; then
		chmod +x "$dst"
	else
		chmod 644 "$dst"
	fi
}

for file in "${FILES[@]}"; do
	copy_and_chmod "$file"
done
