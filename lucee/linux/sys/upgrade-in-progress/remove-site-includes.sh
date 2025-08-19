#!/bin/bash

# Function to remove per-site include files and their Include directives from vhost configs
remove_site_includes() {
	local conf_file="$1"
	[ -f "$conf_file" ] || return 0
	
	local tmp
	tmp=$(mktemp)
	
	# Remove Include lines for per-site includes
	awk '
		# Skip Include lines for per-site includes
		/^[[:space:]]*Include[[:space:]]+\/opt\/lucee\/sys\/site-includes\/.*\.conf/ { next }
		
		# Skip empty line before Include
		/^[[:space:]]*$/ {
			getline next_line
			if (next_line ~ /^[[:space:]]*Include[[:space:]]+\/opt\/lucee\/sys\/site-includes\/.*\.conf/) {
				# Skip this empty line
				next
			} else {
				# Print both lines
				print
				print next_line
			}
			next
		}
		
		# Print all other lines
		{ print }
	' "$conf_file" > "$tmp"
	
	if [ $? -eq 0 ]; then
		mv "$tmp" "$conf_file"
	else
		rm -f "$tmp"
	fi
}

# Remove all per-site include files
rm -rf /opt/lucee/sys/site-includes/
