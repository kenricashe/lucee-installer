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

# Function to normalize whitespace in any configuration file
normalize_conf_whitespace() {
	local conf_file="$1"
	[ -f "$conf_file" ] || return 1
	
	local tmp
	tmp=$(mktemp)
	
	# Step 1: Remove trailing whitespace from lines
	sed 's/[ 	]*$//' "$conf_file" > "$tmp"
	
	# Step 2: Replace multiple empty lines with a single empty line
	sed -i ':a;N;$!ba;s/\n\n\n*/\n\n/g' "$tmp"
	
	# Step 3: Ensure exactly one empty line at the end of file
	# Check if the file already ends with an empty line
	if ! tail -n 1 "$tmp" | grep -q "^$"; then
		# No empty line at the end, add one
		echo "" >> "$tmp"
	fi
	
	if [ -s "$tmp" ]; then
		# Preserve original permissions before overwriting
		local orig_perms
		orig_perms=$(stat -c %a "$conf_file" 2>/dev/null || echo "644")
		mv "$tmp" "$conf_file"
		chmod "$orig_perms" "$conf_file" 2>/dev/null || chmod 644 "$conf_file"
	else
		echo "Warning: Empty output when processing $conf_file"
		rm -f "$tmp"
	fi
}
