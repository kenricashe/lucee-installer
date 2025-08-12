#!/bin/bash

# Interactive menu for Lucee "Upgrade in Progress" toolkit
# Location (after deploy): /opt/lucee/sys/upgrade-in-progress/menu.sh

# Determine script directory and source shared env
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "${SCRIPT_DIR}/get-env.sh"

# Determine sudo prefix for privileged actions
SUDO=""
if [ "$(id -u)" != "0" ]; then
	SUDO="sudo"
fi

SITES_FILE="${UPG_DIR}/sites-configured.txt"

press_enter_to_continue() {
	printf "\nPress Enter to continue..."
	read -r _
}

run_get_sites() {
	echo "\nAnalyzing Apache to build sites list..."
	${SUDO} "${UPG_DIR}/get-lucee-sites.sh"
}

run_edit_sites() {
	if [ ! -f "${SITES_FILE}" ]; then
		echo "\nSites file not found: ${SITES_FILE}"
		echo "Run option 1 first to generate it."
		return
	fi
	EDITOR_CMD="${EDITOR:-nano}"
	if [ "$(id -u)" = "0" ]; then
		${EDITOR_CMD} "${SITES_FILE}"
	else
		${SUDO} ${EDITOR_CMD} "${SITES_FILE}"
	fi
}

run_configure_apache() {
	echo "\nConfiguring Apache (globals + per-site includes)..."
	${SUDO} "${UPG_DIR}/configure-apache.sh"
}

run_begin() {
	echo "\nBeginning 'Upgrade in Progress'..."
	${SUDO} "${UPG_DIR}/begin.sh"
}

run_end() {
	echo "\nEnding 'Upgrade in Progress'..."
	${SUDO} "${UPG_DIR}/end.sh"
}

while true; do
	echo ""
	echo "Lucee Upgrade Menu (${UPG_DIR})"
	echo "--------------------------------"
	echo "1) Get Apache Site Data"
	echo "2) View/Edit Apache Site Data"
	echo "3) Configure Apache"
	echo "4) Begin 'Upgrade in Progress'"
	echo "5) End 'Upgrade in Progress'"
	echo "q) Quit"
	echo ""
	read -r -p "Select an option [1-5 or q]: " choice
	case "${choice}" in
		1)
			run_get_sites
			press_enter_to_continue
			;;
		2)
			run_edit_sites
			press_enter_to_continue
			;;
		3)
			run_configure_apache
			press_enter_to_continue
			;;
		4)
			run_begin
			press_enter_to_continue
			;;
		5)
			run_end
			press_enter_to_continue
			;;
		q|Q)
			echo "Exiting."
			exit 0
			;;
		*)
			echo "Invalid selection."
			;;
	esac
done
