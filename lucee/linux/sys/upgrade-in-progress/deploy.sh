#!/bin/bash

# chmod +x /path/to/this/script/deploy.sh
# sudo /path/to/this/script/deploy.sh

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "${SCRIPT_DIR}/ENVIRONMENT.sh"
. "${SCRIPT_DIR}/shared-functions.sh"

FILES=(
	"ENVIRONMENT.sh"
	"shared-functions.sh"
	"menu.sh"
	"get-lucee-sites.sh"
	"configure-apache.sh"
	"get-current-configs.sh"
	"begin.sh"
	"end.sh"
	"lucee-detect-upgrade.conf"
	"lucee-upgrade-in-progress.conf"
	"lucee-upgrade-in-progress.html"
	"uninstall.sh"
	"tests/dev-reset.sh"
	"tests/cpanel.sh"
)

# preflight: ensure all source files exist in the script directory
missing=()
for f in "${FILES[@]}"; do
	if [ ! -f "${SCRIPT_DIR}/$f" ]; then
		missing+=("$f")
	fi
done
if [ ${#missing[@]} -gt 0 ]; then
	echo "Error: Missing source files in ${SCRIPT_DIR}:"
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
	echo ""
	echo "Using Lucee root path: $LUCEE_ROOT"
else
	# No argument provided, prompt for input
	read -r -p "Enter target Lucee root path [${DEFAULT_LUCEE_ROOT}]: " INPUT_LUCEE_ROOT
	LUCEE_ROOT="${INPUT_LUCEE_ROOT:-$DEFAULT_LUCEE_ROOT}"
fi

UPG_DIR="${LUCEE_ROOT}/sys/upgrade-in-progress"
mkdir -p "$UPG_DIR/tests"

function copy_and_chmod() {
	local src="${SCRIPT_DIR}/$1"
	local dst="${UPG_DIR}/$1"
	cp -f --no-preserve=all "$src" "$dst"
	if [[ "$1" == *.sh ]]; then
		chmod +x "$dst"
	fi
}

for file in "${FILES[@]}"; do
	copy_and_chmod "$file"
done

# Rewrite Include paths inside lucee-detect-upgrade.conf to match selected LUCEE_ROOT
CONF_FILE="${UPG_DIR}/lucee-detect-upgrade.conf"
if [ -f "$CONF_FILE" ]; then
	# Escape '&' for sed replacement safety
	ESC_HTTPD_LUCEE_ROOT="${HTTPD_LUCEE_ROOT//&/\\&}"
	# replace the template's hardcoded /etc/apache2 with the actual path e.g. /etc/httpd
	sed -i "s|/etc/apache2|${ESC_HTTPD_LUCEE_ROOT}|g" "$CONF_FILE"
fi

echo "Deployment to ${UPG_DIR} completed successfully."
