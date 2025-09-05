#!/bin/bash

# uninstall.sh - Remove Lucee upgrade-in-progress system and restore original configurations
# This script discovers and removes all upgrade-related modifications from the system

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "${SCRIPT_DIR}/ENVIRONMENT.sh"
. "${SCRIPT_DIR}/shared-functions.sh"

# Default options
PREVIEW_MODE=true
PREVIEW_PREFIX="[PREVIEW] "
VERBOSE=false
BACKUP_BEFORE_REMOVE=true
FORCE=false
INTERACTIVE=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
	case $1 in
		--execute|-x)
			PREVIEW_MODE=false
			PREVIEW_PREFIX=""
			shift
			;;
		--verbose|-v)
			VERBOSE=true
			shift
			;;
		--no-backup)
			BACKUP_BEFORE_REMOVE=false
			shift
			;;
		--force|-f)
			FORCE=true
			INTERACTIVE=false
			PREVIEW_MODE=false
			PREVIEW_PREFIX=""
			shift
			;;
		--yes|-y)
			INTERACTIVE=false
			shift
			;;
		--help|-h)
			cat <<EOF
Usage: $0 [OPTIONS]

Remove Lucee upgrade-in-progress system and restore original configurations.

OPTIONS:
    --execute, -x      Execute changes immediately (default is preview mode)
    --verbose, -v      Enable verbose output
    --no-backup        Skip creating backups before removal
    --force, -f        Force removal without prompts (implies --execute)
    --yes, -y          Answer yes to all prompts (implies --execute)
    --help, -h         Show this help message

DESCRIPTION:
    This script discovers all upgrade-related configurations and removes them:
    - VirtualHost files with upgrade Include directives
    - Per-site include files
    - Upgrade HTML files (upgrade-in-progress.html)
    - Modified .htaccess files
    - Proxy configuration files
    - Legacy upgrade files
    - Upgrade flag files

    By default, shows a preview of pending changes and prompts for confirmation.
    Use --execute to skip preview. Backups are created before removal unless --no-backup is used.

EXAMPLES:
    $0                 # Preview changes, then prompt for confirmation
    $0 --execute       # Execute changes immediately with prompts
    $0 --force         # Execute changes without prompts
    $0 --verbose --yes # Execute with detailed output, no prompts

EOF
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			echo "Use --help for usage information."
			exit 1
			;;
	esac
done

# Function to log verbose messages
log_verbose() {
	if [ "$VERBOSE" = true ]; then
		echo "[VERBOSE] $*" >&2
	fi
}

# Function to log actions
log_action() {
	echo "[ACTION] $*"
}

# Function to execute or simulate commands
execute_or_simulate() {
	local action="$1"
	shift
	
	if [ "$PREVIEW_MODE" = true ]; then
		if [ "$action" = "remove_include_directive" ]; then
			local file="$1"
			local pattern="$2"
			local matching_lines
			matching_lines=$(grep "$pattern" "$file" 2>/dev/null || true)
			if [ -n "$matching_lines" ]; then
				echo "Would remove from $file:"
				echo "$matching_lines" | sed 's/^/  /'
			else
				echo "No matching lines found in $file for pattern: $pattern"
			fi
		else
			echo "Would execute: $action $*"
		fi
	else
		log_action "$action $*"
		case "$action" in
			"remove_file")
				rm -f "$1"
				;;
			"remove_dir")
				rm -rf "$1"
				;;
			"restore_file")
				cp --no-preserve=all "$1" "$2"
				;;
			"remove_include_directive")
				local file="$1"
				local pattern="$2"
				sed_i_nopreserve "\|$pattern|d" "$file"
				;;
			"apache_reload")
				apache_reload || exit 1
				;;
		esac
	fi
}

# Function to prompt user for confirmation
confirm_action() {
	local message="$1"
	
	if [ "$INTERACTIVE" = false ]; then
		return 0
	fi
	
	echo -n "$message (y/N): "
	read -r response
	echo ""  # Add newline after response
	case "$response" in
		[yY]|[yY][eE][sS])
			return 0
			;;
		*)
			return 1
			;;
	esac
}

# Function to restore original ErrorDocument 404 directives from backups
restore_original_errordocument_404() {
	local vhost_file="$1"
	
	# Skip in preview mode
	if [ "$PREVIEW_MODE" = true ]; then
		return 0
	fi
	
	log_verbose "Searching for original ErrorDocument 404 in backups for: $vhost_file"
	
	# Find backup versions, but limit to direct backup directories (not nested ones)
	local backup_files
	backup_files=$(find "${BACKUP_ROOT}" -maxdepth 2 -path "*${vhost_file}" 2>/dev/null | sort -r)
	
	if [ -z "$backup_files" ]; then
		log_verbose "No backups found for $vhost_file"
		return 0
	fi
	
	# Search through backups from most recent to oldest
	local original_errordoc
	while IFS= read -r backup_file; do
		if [ -f "$backup_file" ]; then
			log_verbose "Checking backup: $backup_file"
			# Look for ErrorDocument 404 lines that aren't commented out
			original_errordoc=$(grep -E "^[[:space:]]*ErrorDocument[[:space:]]+404[[:space:]]+" "$backup_file" 2>/dev/null | head -1)
			if [ -n "$original_errordoc" ]; then
				log_verbose "Found original ErrorDocument 404: $original_errordoc"
				
				# Check if current file already has an ErrorDocument 404
				if ! grep -q "^[[:space:]]*ErrorDocument[[:space:]]\+404[[:space:]]" "$vhost_file" 2>/dev/null; then
					if [ "$PREVIEW_MODE" = true ]; then
						echo "Would restore to $vhost_file:"
						echo "  $original_errordoc"
					else
						# Find a good place to insert it (after DocumentRoot, before </VirtualHost>)
						local insert_line
						insert_line=$(grep -n "DocumentRoot\|</VirtualHost>" "$vhost_file" | grep "DocumentRoot" | tail -1 | cut -d: -f1)
						if [ -n "$insert_line" ]; then
							# Insert after DocumentRoot line
							sed_i_nopreserve "${insert_line}a\\\t${original_errordoc}" "$vhost_file"
							log_action "Restored original ErrorDocument 404 to: $vhost_file"
						else
							# Fallback: insert before </VirtualHost>
							sed_i_nopreserve "/<\/VirtualHost>/i\\\t${original_errordoc}" "$vhost_file"
							log_action "Restored original ErrorDocument 404 to: $vhost_file"
						fi
					fi
				else
					log_verbose "ErrorDocument 404 already exists in $vhost_file"
				fi
				return 0
			fi
		fi
	done <<< "$backup_files"
	
	log_verbose "No original ErrorDocument 404 found in any backup for $vhost_file"
}

# Function to remove Include directives from VirtualHost files
remove_include_directives() {
	local vhost_file="$1"
	
	if [ ! -f "$vhost_file" ]; then
		return 0
	fi
	
	log_verbose "Checking for upgrade Include directives in: $vhost_file"
	
	# Backup if requested and not in preview mode
	if [ "$BACKUP_BEFORE_REMOVE" = true ] && [ "$PREVIEW_MODE" = false ]; then
		backup_file "$vhost_file"
	fi
	
	# Remove Include directives that reference upgrade-in-progress files
	local patterns=(
		"Include.*${HTTPD_LUCEE_ROOT}"
	)
	
	local modified=false
	for pattern in "${patterns[@]}"; do
		if grep -q "$pattern" "$vhost_file" 2>/dev/null; then
			execute_or_simulate "remove_include_directive" "$vhost_file" "$pattern"
			modified=true
		fi
	done
	
	if [ "$modified" = true ] && [ "$PREVIEW_MODE" = false ]; then
		log_action "Removed upgrade Include directives from: $vhost_file"
		
		# Try to restore original ErrorDocument 404 directives from backups
		restore_original_errordocument_404 "$vhost_file"
	fi
}

# Function to restore .htaccess files from backups
restore_htaccess_files() {
	local htaccess_file="$1"
	
	if [ ! -f "$htaccess_file" ]; then
		return 0
	fi
	
	log_verbose "Checking .htaccess file: $htaccess_file"
	
	# Look for backup in the backup directory
	local backup_pattern="${BACKUP_ROOT}/*${htaccess_file}"
	local latest_backup
	latest_backup=$(find ${BACKUP_ROOT} -path "*${htaccess_file}" 2>/dev/null | sort -r | head -1)
	
	if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
		if confirm_action "Restore $htaccess_file from backup $latest_backup?"; then
			execute_or_simulate "restore_file" "$latest_backup" "$htaccess_file"
		fi
	else
		# Check if file contains upgrade-related content
		if grep -q "upgrade-in-progress\|lucee-upgrade" "$htaccess_file" 2>/dev/null; then
			if confirm_action "Remove upgrade content from $htaccess_file (no backup found)?"; then
				if [ "$BACKUP_BEFORE_REMOVE" = true ] && [ "$PREVIEW_MODE" = false ]; then
					backup_file "$htaccess_file"
				fi
				# Remove upgrade-related lines
				execute_or_simulate "remove_include_directive" "$htaccess_file" "upgrade-in-progress"
				execute_or_simulate "remove_include_directive" "$htaccess_file" "lucee-upgrade"
			fi
		fi
	fi
}

# Function to process all uninstall operations
process_uninstall_operations() {
	local vhost_files="$1"
	local proxy_configs="$2"
	local upgrade_configs="$3"
	local modified_htaccess="$4"
	local upgrade_html_files="$5"
	local site_includes="$6"
	local legacy_files="$7"

	# Remove VirtualHost Include directives
	if [ -n "$vhost_files" ]; then
		echo "${PREVIEW_PREFIX}Processing VirtualHost files with upgrade Include directives..."
		while IFS= read -r vhost_file; do
			[ -n "$vhost_file" ] && remove_include_directives "$vhost_file"
		done <<< "$vhost_files"
		echo ""
	fi
	
	# Remove proxy configuration files (except lucee-proxy.conf)
	if [ -n "$proxy_configs" ]; then
		echo "${PREVIEW_PREFIX}Removing upgrade-specific proxy configuration files..."
		while IFS= read -r proxy_file; do
			if [ -n "$proxy_file" ] && [ -f "$proxy_file" ]; then
				# Skip lucee-proxy.conf - it should remain for continued Lucee functionality
				if [[ "$proxy_file" == *"lucee-proxy.conf" ]]; then
					log_verbose "Preserving lucee-proxy.conf: $proxy_file"
					continue
				fi
				
				# Disable and remove Apache configuration (Debian/Ubuntu)
				if [ "$IS_DEBIAN" = true ]; then
					local conf_name
					conf_name=$(basename "$proxy_file" .conf)
					if [ "$BACKUP_BEFORE_REMOVE" = true ]; then
						backup_file "$proxy_file"
					fi
					if [ "$PREVIEW_MODE" = true ]; then
						echo "Would execute: disable_and_remove_conf $conf_name"
					else
						disable_and_remove_conf "$conf_name"
					fi
				else
					# Non-Debian systems: just remove the file
					if [ "$BACKUP_BEFORE_REMOVE" = true ]; then
						backup_file "$proxy_file"
					fi
					execute_or_simulate "remove_file" "$proxy_file"
				fi
			fi
		done <<< "$proxy_configs"
		echo ""
	fi
	
	# Remove upgrade configuration files
	if [ -n "$upgrade_configs" ]; then
		echo "${PREVIEW_PREFIX}Removing upgrade configuration files..."
		while IFS= read -r upgrade_file; do
			if [ -n "$upgrade_file" ] && [ -f "$upgrade_file" ]; then
				# Disable and remove Apache configuration (Debian/Ubuntu)
				if [ "$IS_DEBIAN" = true ]; then
					local conf_name
					conf_name=$(basename "$upgrade_file" .conf)
					if [ "$BACKUP_BEFORE_REMOVE" = true ]; then
						backup_file "$upgrade_file"
					fi
					if [ "$PREVIEW_MODE" = true ]; then
						echo "Would execute: disable_and_remove_conf $conf_name"
					else
						disable_and_remove_conf "$conf_name"
					fi
				else
					# Non-Debian systems: just remove the file
					if [ "$BACKUP_BEFORE_REMOVE" = true ]; then
						backup_file "$upgrade_file"
					fi
					execute_or_simulate "remove_file" "$upgrade_file"
				fi
			fi
		done <<< "$upgrade_configs"
		echo ""
	fi
	
	# Process .htaccess files
	if [ -n "$modified_htaccess" ]; then
		echo "${PREVIEW_PREFIX}Processing modified .htaccess files..."
		while IFS= read -r htaccess_file; do
			[ -n "$htaccess_file" ] && restore_htaccess_files "$htaccess_file"
		done <<< "$modified_htaccess"
		echo ""
	fi
	
	# Remove upgrade HTML files
	if [ -n "$upgrade_html_files" ]; then
		echo "${PREVIEW_PREFIX}Removing upgrade HTML files..."
		while IFS= read -r html_file; do
			if [ -n "$html_file" ] && [ -f "$html_file" ]; then
				if [ "$BACKUP_BEFORE_REMOVE" = true ]; then
					backup_file "$html_file"
				fi
				execute_or_simulate "remove_file" "$html_file"
			fi
		done <<< "$upgrade_html_files"
		echo ""
	fi
	
	# Remove per-site include files
	if [ -n "$site_includes" ]; then
		echo "${PREVIEW_PREFIX}Removing per-site include files..."
		while IFS= read -r include_file; do
			if [ -n "$include_file" ] && [ -f "$include_file" ]; then
				if [ "$BACKUP_BEFORE_REMOVE" = true ]; then
					backup_file "$include_file"
				fi
				execute_or_simulate "remove_file" "$include_file"
			fi
		done <<< "$site_includes"
		echo ""
	fi
	
	# Remove legacy files
	if [ -n "$legacy_files" ]; then
		echo "${PREVIEW_PREFIX}Removing legacy upgrade files..."
		while IFS= read -r legacy_file; do
			if [ -n "$legacy_file" ] && [ -f "$legacy_file" ]; then
				if [ "$BACKUP_BEFORE_REMOVE" = true ]; then
					backup_file "$legacy_file"
				fi
				execute_or_simulate "remove_file" "$legacy_file"
			fi
		done <<< "$legacy_files"
		echo ""
	fi
	
	# Remove upgrade flag file
	if [ -f "/var/lucee-upgrade-in-progress" ]; then
		echo "${PREVIEW_PREFIX}Removing upgrade flag file..."
		if [ "$BACKUP_BEFORE_REMOVE" = true ]; then
			backup_file "/var/lucee-upgrade-in-progress"
		fi
		execute_or_simulate "remove_file" "/var/lucee-upgrade-in-progress"
		echo ""
	fi
	
	# Reload Apache configuration
	if [ "$PREVIEW_MODE" = false ]; then
		echo "${PREVIEW_PREFIX}Reloading Apache configuration..."
		execute_or_simulate "apache_reload"
		echo ""
	fi
	
	# Summary
	if [ "$PREVIEW_MODE" = true ]; then
		return  # Don't show summary in preview mode, handled by caller
	else
		local total_items=0
		[ -n "$vhost_files" ] && total_items=$((total_items + $(echo "$vhost_files" | wc -l)))
		[ -n "$proxy_configs" ] && total_items=$((total_items + $(echo "$proxy_configs" | wc -l)))
		[ -n "$upgrade_configs" ] && total_items=$((total_items + $(echo "$upgrade_configs" | wc -l)))
		[ -n "$modified_htaccess" ] && total_items=$((total_items + $(echo "$modified_htaccess" | wc -l)))
		[ -n "$upgrade_html_files" ] && total_items=$((total_items + $(echo "$upgrade_html_files" | wc -l)))
		[ -n "$site_includes" ] && total_items=$((total_items + $(echo "$site_includes" | wc -l)))
		[ -n "$legacy_files" ] && total_items=$((total_items + $(echo "$legacy_files" | wc -l)))
		
		echo "Uninstall complete. $total_items items processed."
		if [ "$BACKUP_BEFORE_REMOVE" = true ]; then
			echo "Backups created in: ${BACKUP_ROOT}/${BACKUP_TS}"
		fi
	fi
}

# Main uninstall function
main() {
	echo "Lucee Upgrade-in-Progress System Uninstaller"
	echo "============================================="
	echo ""
	
	log_verbose "Environment: Debian=$IS_DEBIAN, cPanel=$IS_CPANEL"
	log_verbose "Lucee Root: $LUCEE_ROOT"
	log_verbose "Upgrade Dir: $UPG_DIR"
	
	# Discover current configurations
	echo "Discovering current upgrade configurations..."
	local discovery_output
	discovery_output=$(discover_apache_configs "json" "false")
	
	if [ -z "$discovery_output" ]; then
		echo "No upgrade configurations found."
		exit 0
	fi
	
	# Parse JSON output to get file lists
	local vhost_files proxy_configs upgrade_configs modified_htaccess upgrade_html_files site_includes legacy_files
	
	# Extract file arrays from JSON (handle multi-line arrays)
	vhost_files=$(echo "$discovery_output" | sed -n '/"vhost_files": \[/,/\]/p' | grep -o '"/[^"]*"' | sed 's/"//g' | grep -v '^$')
	proxy_configs=$(echo "$discovery_output" | sed -n '/"proxy_configs": \[/,/\]/p' | grep -o '"/[^"]*"' | sed 's/"//g' | grep -v '^$')
	upgrade_configs=$(echo "$discovery_output" | sed -n '/"upgrade_configs": \[/,/\]/p' | grep -o '"/[^"]*"' | sed 's/"//g' | grep -v '^$')
	modified_htaccess=$(echo "$discovery_output" | sed -n '/"modified_htaccess": \[/,/\]/p' | grep -o '"/[^"]*"' | sed 's/"//g' | grep -v '^$')
	upgrade_html_files=$(echo "$discovery_output" | sed -n '/"upgrade_html_files": \[/,/\]/p' | grep -o '"/[^"]*"' | sed 's/"//g' | grep -v '^$')
	site_includes=$(echo "$discovery_output" | sed -n '/"site_includes": \[/,/\]/p' | grep -o '"/[^"]*"' | sed 's/"//g' | grep -v '^$')
	legacy_files=$(echo "$discovery_output" | sed -n '/"legacy_files": \[/,/\]/p' | grep -o '"/[^"]*"' | sed 's/"//g' | grep -v '^$')
	
	# Count total items to remove
	local total_items=0
	[ -n "$vhost_files" ] && total_items=$((total_items + $(echo "$vhost_files" | wc -l)))
	[ -n "$proxy_configs" ] && total_items=$((total_items + $(echo "$proxy_configs" | wc -l)))
	[ -n "$upgrade_configs" ] && total_items=$((total_items + $(echo "$upgrade_configs" | wc -l)))
	[ -n "$modified_htaccess" ] && total_items=$((total_items + $(echo "$modified_htaccess" | wc -l)))
	[ -n "$upgrade_html_files" ] && total_items=$((total_items + $(echo "$upgrade_html_files" | wc -l)))
	[ -n "$site_includes" ] && total_items=$((total_items + $(echo "$site_includes" | wc -l)))
	[ -n "$legacy_files" ] && total_items=$((total_items + $(echo "$legacy_files" | wc -l)))
	
	if [ "$total_items" -eq 0 ]; then
		echo "No upgrade configurations found to remove."
		exit 0
	fi
	
	echo "Found $total_items upgrade-related items to process."
	echo ""
	
	# If in preview mode, show preview and prompt for confirmation
	if [ "$PREVIEW_MODE" = true ]; then
		echo "PREVIEW OF PENDING CHANGES:"
		echo "============================"
		echo ""
		
		# Run through all operations in preview mode
		process_uninstall_operations "$vhost_files" "$proxy_configs" "$upgrade_configs" "$modified_htaccess" "$upgrade_html_files" "$site_includes" "$legacy_files"
		
		echo ""
		echo "Preview complete. $total_items items would be processed."
		echo ""
		
		if [ "$FORCE" = false ]; then
			if confirm_action "Execute these changes now?"; then
				PREVIEW_MODE=false
				PREVIEW_PREFIX=""
				echo ""
				echo "EXECUTING CHANGES:"
				echo "=================="
				echo ""
				process_uninstall_operations "$vhost_files" "$proxy_configs" "$upgrade_configs" "$modified_htaccess" "$upgrade_html_files" "$site_includes" "$legacy_files"
			else
				echo "Uninstall cancelled."
				exit 0
			fi
		fi
	else
		# Direct execution mode
		if [ "$FORCE" = false ]; then
			if ! confirm_action "Proceed with uninstall?"; then
				echo "Uninstall cancelled."
				exit 0
			fi
			echo ""
		fi
		process_uninstall_operations "$vhost_files" "$proxy_configs" "$upgrade_configs" "$modified_htaccess" "$upgrade_html_files" "$site_includes" "$legacy_files"
	fi
}

# Run main function
main
