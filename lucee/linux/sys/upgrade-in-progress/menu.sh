#!/bin/bash

# Interactive menu for Lucee "Upgrade in Progress" toolkit
# Location (after deploy): /opt/lucee/sys/upgrade-in-progress/menu.sh

# Determine script directory and source shared env
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "${SCRIPT_DIR}/get-env.sh"

press_enter_to_continue() {
	printf "\nPress Enter to continue..."
	read -r _
}

run_get_sites() {
	clear
	${SUDO} "${UPG_DIR}/get-lucee-sites.sh"
}

run_edit_sites() {
	if [ ! -f "${SITES_FILE}" ]; then
		print "\nSites file not found: ${SITES_FILE}\n\nRun option 1 first to generate it."
		return
	fi
	${SUDO} ${EDITOR:-nano} "${SITES_FILE}"
}

run_configure_apache() {
	clear
	${SUDO} "${UPG_DIR}/configure-apache.sh"
}

run_begin() {
	clear
	${SUDO} "${UPG_DIR}/begin.sh"
}

run_end() {
	clear
	${SUDO} "${UPG_DIR}/end.sh"
}

while true; do
	clear
	echo "------------------------------------------"
	echo " 'Upgrade in Progress' for Lucee + Apache"
	if [ -e "/var/lucee-upgrade-in-progress" ]; then
		echo "Current Server Status: UPGRADE IN PROGRESS"
	else
		echo " Current Server Status: NORMAL OPERATIONS"
	fi
	echo " (based on /var/lucee-upgrade-in-progress)"
	echo "------------------------------------------"
	echo ""
	echo "1. Get/Edit Apache Site Data"
	echo ""
	echo "2. View/Edit Apache Site Data File"
	echo ""
	echo "3. Configure Apache"
	echo ""
	echo "4. Begin 'Upgrade in Progress'"
	echo ""
	echo "5. End 'Upgrade in Progress'"
	echo ""
	echo "q. Quit"
	echo ""
	read -r -p "Select an option [1-5 or q]: " choice
	case "${choice}" in
		1)
			run_get_sites
			;;
		2)
			run_edit_sites
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
