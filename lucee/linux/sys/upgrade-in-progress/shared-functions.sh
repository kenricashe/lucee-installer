#!/bin/bash

# Shared functions for Lucee upgrade scripts

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
		mv "$tmp" "$conf_file"
		chmod --reference="$conf_file" "$conf_file" 2>/dev/null || true
	else
		echo "Warning: Empty output when processing $conf_file"
		rm -f "$tmp"
	fi
}
