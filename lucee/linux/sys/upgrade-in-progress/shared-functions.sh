#!/bin/bash

# Ensure the site exclusions file exists with sensible defaults.
ensure_default_exclusions_file() {
	if [ ! -f "$EXCLUSIONS_FILE" ] || [ ! -s "$EXCLUSIONS_FILE" ]; then
		${SUDO} mkdir -p "$(dirname "$EXCLUSIONS_FILE")" 2>/dev/null || true
		${SUDO} tee "$EXCLUSIONS_FILE" >/dev/null <<'EOF'
# Lucee site search exclusions
#
# Domain patterns:
#   exact domains: example.com
#   wildcard domains: *.example.com
# Path exclusions:
#   path: /var/www/html/some-static-site

# Common non-app / platform subdomains (cPanel, etc)
localhost
cpanel
whm
webmail
webdisk
mail
default
localhost
_wildcard_

# cPanel and control panel vhosts
proxy-subdomains-vhost

# Path exclusions (examples)
# path: /var/www/html/default
EOF
	fi
}

# Helper functions for handling newlines in different file creation scenarios

# Backup helper: mirror source path under ${BACKUP_ROOT}/${BACKUP_TS}
# Usage: backup_file /path/to/file
backup_file() {
	local src="$1"
	[ -f "$src" ] || return 0
	
	# Set backup variables if not already set
	: ${BACKUP_ROOT:="${UPG_DIR}/backups"}
	: ${BACKUP_TS:="$(date +%Y-%m-%d-%H%M%S)"}
	
	local dest="${BACKUP_ROOT}/${BACKUP_TS}${src}"
	local dest_dir
	dest_dir=$(dirname "$dest")
	mkdir -p "$dest_dir"
	cp -f "$src" "$dest"
	
	# Return success if backup was created
	[ -f "$dest" ]
}

# Helper function to strip all trailing newlines from a string
# Returns the cleaned string via echo
strip_trailing_newlines() {
	local content="$1"
	
	# Remove all trailing newlines
	while [ -n "$content" ] && [ "${content: -1}" = $'\n' ]; do
		content="${content%$'\n'}"
	done
	
	echo "$content"
}

# Write content to a file with exactly one newline at EOF
write_with_single_newline() {
	local content="$1"
	local file="$2"
	
	# Strip trailing newlines and add exactly one
	content=$(strip_trailing_newlines "$content")
	printf "%s\n" "$content" > "$file"
}

# Append content to a file with exactly one newline
append_with_single_newline() {
	local content="$1"
	local file="$2"
	
	# Strip trailing newlines and add exactly one
	content=$(strip_trailing_newlines "$content")
	printf "%s\n" "$content" >> "$file"
}

# Function to normalize whitespace in any configuration file
normalize_conf_whitespace() {
	local conf_file="$1"
	[ -f "$conf_file" ] || return 1
	
	# SAFETY CHECK: Make a backup first
	backup_file "$conf_file"
	
	local tmp
	tmp=$(mktemp)
	
	# Use cat to ensure we don't lose content
	cat "$conf_file" > "$tmp"
	
	# Only trim trailing whitespace - safer operation
	sed -i 's/[ \t]*$//' "$tmp"
	
	# Ensure exactly one newline at EOF (safer approach)
	if [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | wc -l)" -eq 0 ]; then
		# No newline at end, add one
		printf "\n" >> "$tmp"
	fi
	
	# If tmp is empty, don't proceed with the change
	if [ ! -s "$tmp" ]; then
		echo "ERROR: Empty output when processing $conf_file - ABORTING CHANGE"
		# Just clean up the temp file and return error
		rm -f "$tmp"
		return 1
	fi

	# Only overwrite if content changed
	if cmp -s "$conf_file" "$tmp"; then
		rm -f "$tmp"
		return 0
	fi

	# Preserve original permissions before overwriting
	local orig_perms
	orig_perms=$(stat -c %a "$conf_file" 2>/dev/null || echo "644")
	mv "$tmp" "$conf_file"
	chmod "$orig_perms" "$conf_file" 2>/dev/null || chmod 644 "$conf_file"
}

# Function to disable and remove an Apache configuration file
disable_and_remove_conf() {
	local conf_name="$1"
	local conf_path="/etc/apache2/conf-available/${conf_name}.conf"
	disable_conf "$conf_name"
	rm -f "$conf_path"
}

# Function to enable an Apache configuration file
enable_conf() {
	local conf_name="$1"
	local conf_path="/etc/apache2/conf-available/${conf_name}.conf"
	
	if [ ! -f "$conf_path" ]; then
		echo "ERROR: ${conf_name}.conf does not exist at $conf_path"
		return 1
	fi
	
	echo "Enabling ${conf_name}.conf..."
	if a2enconf "$conf_name" >/dev/null 2>&1; then
		echo "  - Successfully enabled ${conf_name}.conf"
		return 0
	else
		echo "  - Failed to enable ${conf_name}.conf"
		return 1
	fi
}

disable_conf() {
	local conf_name="$1"
	echo "Disabling ${conf_name}.conf..."
	if a2disconf "$conf_name" >/dev/null 2>&1; then
		echo "  - Successfully disabled ${conf_name}.conf"
		return 0
	else
		echo "  - ${conf_name}.conf was already disabled or not found"
		return 1
	fi
}
