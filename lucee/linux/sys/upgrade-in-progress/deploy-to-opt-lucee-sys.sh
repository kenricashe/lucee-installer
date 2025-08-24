#!/bin/bash

# chmod +x /path/to/this/script/deploy-to-opt-lucee-sys.sh
# sudo /path/to/this/script/deploy-to-opt-lucee-sys.sh

# require root
if [ "$(id -u)" != "0" ]; then
echo "This script must be run as root or with sudo."
exit 1
fi

THISPATH=$(dirname "$0")

# Source helpers for newline handling
. "${THISPATH}/shared-functions.sh"

FILES=(
	"get-lucee-sites.sh"
	"configure-apache.sh"
	"ENVIRONMENT.sh"
	"menu.sh"
	"begin.sh"
	"end.sh"
	"lucee-upgrade-in-progress.html"
	"lucee-detect-upgrade.conf"
	"lucee-upgrade-in-progress.conf"
	"shared-functions.sh"
	"dev-reset.sh"
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

# Use Lucee root path from command line argument or prompt for it
DEFAULT_LUCEE_ROOT="/opt/lucee"

# Check if a path was provided as an argument
if [ -n "$1" ]; then
	LUCEE_ROOT="$1"
	echo "Using provided Lucee root path: $LUCEE_ROOT"
else
	# No argument provided, prompt for input
	read -r -p "Enter target Lucee root path [${DEFAULT_LUCEE_ROOT}]: " INPUT_LUCEE_ROOT
	LUCEE_ROOT="${INPUT_LUCEE_ROOT:-$DEFAULT_LUCEE_ROOT}"
fi

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

# Rewrite Include paths inside lucee-detect-upgrade.conf to match selected LUCEE_ROOT
CONF_FILE="${DEST_DIR}/lucee-detect-upgrade.conf"
if [ -f "$CONF_FILE" ]; then
	# Escape '&' for sed replacement safety
	ESC_LUCEE_ROOT="${LUCEE_ROOT//&/\\&}"
	sed -i "s|/opt/lucee|${ESC_LUCEE_ROOT}|g" "$CONF_FILE"
fi
