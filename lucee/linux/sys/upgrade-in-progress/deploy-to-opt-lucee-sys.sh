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
	"configure-apache.sh"
	"get-env.sh"
	"menu.sh"
	"begin.sh"
	"end.sh"
	"upgrade-in-progress.html"
	"lucee-detect-upgrade.conf"
	"lucee-ajp-and-mod_cfml.conf"
	"lucee-upgrade-in-progress.conf"
)

# preflight: ensure all source files exist in the script directory
missing=()
for f in "${FILES[@]}"; do
	if [ ! -f "${THISPATH}/$f" ]; then
		missing+=("$f")
	fi
done
if [ ${#missing[@]} -gt 0 ]; then
	echo "Error: Missing source files in ${THISPATH}:"
	for m in "${missing[@]}"; do
		echo "  - $m"
	done
	exit 1
fi

# Prompt for Lucee root path and deploy there
DEFAULT_LUCEE_ROOT="/opt/lucee"
read -r -p "Enter target Lucee root path [${DEFAULT_LUCEE_ROOT}]: " INPUT_LUCEE_ROOT
LUCEE_ROOT="${INPUT_LUCEE_ROOT:-$DEFAULT_LUCEE_ROOT}"
DEST_DIR="${LUCEE_ROOT}/sys/upgrade-in-progress"
mkdir -p "$DEST_DIR"

function copy_and_chmod() {
    local src="${THISPATH}/$1"
    local dst="${DEST_DIR}/$1"
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
