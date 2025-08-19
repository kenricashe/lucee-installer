#!/bin/bash

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root or with sudo."
	exit 1
fi

# Source shared helper for LUCEE_ROOT, UPG_DIR, IS_CPANEL
SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
. "${SCRIPT_DIR}/get-env.sh"

# exit if not Debian
if [ "$IS_DEBIAN" = false ]; then
	echo "This script is only for Debian, Ubuntu, Pop!_OS, etc."
	exit 1
fi

# Function to remove duplicate IfDefine blocks, keeping only the last one
remove_duplicate_ifdefine_blocks() {
	local vhost_file="$1"
	[ -f "$vhost_file" ] || return 0
	
	local tmp
	tmp=$(mktemp)
	
	# First pass: find all IfDefine block positions
	awk '
		BEGIN { block_count=0; in_block=0 }
		
		# Track IfDefine block starts
		/^[[:space:]]*<IfDefine[[:space:]]+!LUCEE_UPGRADE_IN_PROGRESS>/ {
			if (!in_block) {
				block_count++
				block_start[block_count] = NR
				in_block = 1
			}
		}
		
		# Track IfDefine block ends
		/^[[:space:]]*<\/IfDefine>/ && in_block {
			block_end[block_count] = NR
			in_block = 0
		}
		
		END {
			print "BLOCK_COUNT=" block_count
			for (i=1; i<=block_count; i++) {
				print "BLOCK_" i "_START=" block_start[i]
				print "BLOCK_" i "_END=" block_end[i]
			}
		}
	' "$vhost_file" > "$tmp.info"
	
	# Read block information
	local block_count
	block_count=$(grep "^BLOCK_COUNT=" "$tmp.info" | cut -d= -f2)
	
	if [ "$block_count" -gt 1 ]; then
		# Second pass: remove all but the last block (and preceding empty lines)
		awk -v info_file="$tmp.info" '
			BEGIN {
				# Read block positions
				while ((getline line < info_file) > 0) {
					if (match(line, /^BLOCK_([0-9]+)_START=([0-9]+)$/, arr)) {
						block_start[arr[1]] = arr[2]
					} else if (match(line, /^BLOCK_([0-9]+)_END=([0-9]+)$/, arr)) {
						block_end[arr[1]] = arr[2]
					} else if (match(line, /^BLOCK_COUNT=([0-9]+)$/, arr)) {
						block_count = arr[1]
					}
				}
				close(info_file)
				
				# Mark lines to skip (all blocks except the last one)
				for (i=1; i<block_count; i++) {
					# Check for empty line before block start
					if (block_start[i] > 1) {
						skip_line[block_start[i]-1] = "maybe_empty"
					}
					# Mark entire block for removal
					for (j=block_start[i]; j<=block_end[i]; j++) {
						skip_line[j] = "block"
					}
				}
			}
			
			# Process each line
			{
				if (skip_line[NR] == "block") {
					next
				} else if (skip_line[NR] == "maybe_empty" && /^[[:space:]]*$/) {
					next
				} else {
					print
				}
			}
		' "$vhost_file" > "$tmp"
		
		if [ $? -eq 0 ]; then
			mv "$tmp" "$vhost_file"
		else
			rm -f "$tmp"
		fi
	fi
	
	rm -f "$tmp.info"
}

# Function to revert vhost changes
revert_vhost_changes() {
	local vhost_file="$1"
	[ -f "$vhost_file" ] || return 0
	
	local tmp
	tmp=$(mktemp)
	
	# Remove Include line and preceding empty line, unwrap IfDefine blocks
	awk '
		BEGIN { in_ifdefine=0; in_ifdefine_pos=0; skip_next_empty=0 }
		
		# Skip empty line before Include
		/^[[:space:]]*$/ && skip_next_empty { skip_next_empty=0; next }
		
		# Remove Include line and mark to skip preceding empty line
		/^[[:space:]]*Include[[:space:]]+\/opt\/lucee\/sys\/upgrade-in-progress\/lucee-detect-upgrade\.conf/ {
			skip_next_empty=1
			next
		}
		
		# Start of our IfDefine block
		/^[[:space:]]*<IfDefine[[:space:]]+!LUCEE_UPGRADE_IN_PROGRESS>/ {
			in_ifdefine=1
			next
		}
		# Start of positive upgrade-mode IfDefine block (remove entirely)
		/^[[:space:]]*<IfDefine[[:space:]]+LUCEE_UPGRADE_IN_PROGRESS>/ {
			in_ifdefine_pos=1
			next
		}
		
		# End of our IfDefine block
		/^[[:space:]]*<\/IfDefine>/ && in_ifdefine {
			in_ifdefine=0
			next
		}
		# End of positive upgrade-mode IfDefine block
		/^[[:space:]]*<\/IfDefine>/ && in_ifdefine_pos {
			in_ifdefine_pos=0
			next
		}
		
		# Inside our IfDefine block - remove one tab/4 spaces of indentation
		in_ifdefine {
			if (match($0, /^\t/)) {
				print substr($0, 2)
			} else if (match($0, /^    /)) {
				print substr($0, 5)
			} else {
				print $0
			}
			next
		}
		# Inside positive upgrade-mode IfDefine block - drop lines entirely
		in_ifdefine_pos { next }
		
		# Regular lines outside IfDefine
		!in_ifdefine { print; skip_next_empty=0 }
	' "$vhost_file" > "$tmp"
	
	if [ $? -eq 0 ]; then
		mv "$tmp" "$vhost_file"
	else
		rm -f "$tmp"
	fi
}

# Function to remove legacy inlined blocks from .conf files
remove_legacy_inlined_blocks() {
	local conf_file="$1"
	[ -f "$conf_file" ] || return 0
	
	local tmp
	tmp=$(mktemp)
	
	# Remove entire legacy inlined blocks
	awk '
		BEGIN { in_legacy_block=0 }
		
		# Start of legacy block
		/^# Begin inlined legacy:.*lucee-404-routing\.conf/ {
			in_legacy_block=1
			next
		}
		
		# End of legacy block
		/^# End inlined legacy/ && in_legacy_block {
			in_legacy_block=0
			next
		}
		
		# Skip lines inside legacy block
		in_legacy_block { next }
		
		# Print all other lines
		{ print }
	' "$conf_file" > "$tmp"
	
	if [ $? -eq 0 ]; then
		mv "$tmp" "$conf_file"
	else
		rm -f "$tmp"
	fi
}

# Function to remove ErrorDocument 404 /404.cfm lines and preceding comments/empty lines
remove_errordocument_404() {
	local conf_file="$1"
	[ -f "$conf_file" ] || return 0
	
	local tmp
	tmp=$(mktemp)
	
	# Process file to remove ErrorDocument 404 lines and preceding comments/empty lines
	awk '
		BEGIN { 
			buffer_size = 0
			clear_buffer = 0
		}
		
		# Check if current line contains ErrorDocument 404 /404.cfm
		/ErrorDocument[[:space:]]+404[[:space:]]+\/404\.cfm/ {
			# Clear the buffer (removes preceding comments/empty lines)
			buffer_size = 0
			# Skip this ErrorDocument line
			next
		}
		
		# Handle comments and empty lines - buffer them
		/^[[:space:]]*#/ || /^[[:space:]]*$/ {
			buffer[buffer_size] = $0
			buffer_size++
			next
		}
		
		# Non-comment, non-empty line - flush buffer and print
		{
			# Print buffered lines
			for (i = 0; i < buffer_size; i++) {
				print buffer[i]
			}
			buffer_size = 0
			# Print current line
			print
		}
	' "$conf_file" > "$tmp"
	
	if [ $? -eq 0 ]; then
		mv "$tmp" "$conf_file"
	else
		rm -f "$tmp"
	fi
}

# Function to restore .htaccess ErrorDocument 404 lines
restore_htaccess_404() {
	local htaccess_file="$1"
	[ -f "$htaccess_file" ] || return 0
	
	local tmp
	tmp=$(mktemp)
	
	# Get directory ownership to preserve it
	local dir_path
	dir_path=$(dirname "$htaccess_file")
	local dir_owner
	local dir_group
	dir_owner=$(stat -c '%U' "$dir_path")
	dir_group=$(stat -c '%G' "$dir_path")
	
	# Remove NOTE lines and uncomment ErrorDocument 404 lines
	awk '
		# Skip NOTE lines added by configure-apache.sh
		/^# NOTE: ErrorDocument 404 moved/ { next }
		
		# Uncomment ErrorDocument 404 lines that contain /404.cfm
		/^# ErrorDocument[[:space:]]+404.*\/404\.cfm/ {
			# Remove leading "# " to uncomment
			sub(/^# /, "")
			print
			next
		}
		
		# Print all other lines as-is
		{ print }
	' "$htaccess_file" > "$tmp"
	
	if [ $? -eq 0 ]; then
		mv "$tmp" "$htaccess_file"
		# Restore ownership and permissions
		chown "$dir_owner:$dir_group" "$htaccess_file"
		chmod 664 "$htaccess_file"
	else
		rm -f "$tmp"
	fi
}

# append contents of lucee-proxy.conf to apache2.conf
if [ -f "/etc/apache2/conf-available/lucee-proxy.conf" ]; then
	cat "/etc/apache2/conf-available/lucee-proxy.conf" >> "/etc/apache2/apache2.conf"
fi

# disable and delete lucee-proxy.conf
a2disconf lucee-proxy 2>/dev/null || true
rm -f "/etc/apache2/conf-available/lucee-proxy.conf"

# disable and delete lucee-upgrade-in-progress.conf
a2disconf lucee-upgrade-in-progress 2>/dev/null || true
rm -f "/etc/apache2/conf-available/lucee-upgrade-in-progress.conf"

# Process all .conf files in sites-available
echo ""
echo "Processing all .conf files in sites-available..."
for conf_file in /etc/apache2/sites-available/*.conf; do
	if [ -f "$conf_file" ]; then
		echo ""
		echo "  Processing $(basename "$conf_file")"
		remove_legacy_inlined_blocks "$conf_file"
		remove_duplicate_ifdefine_blocks "$conf_file"
		revert_vhost_changes "$conf_file"
		remove_errordocument_404 "$conf_file"
		
		# Extract DocumentRoot and process files
		docroot=$(grep -i '^[[:space:]]*DocumentRoot' "$conf_file" | head -1 | awk '{print $2}' | tr -d '"')
		if [ -n "$docroot" ]; then
			# Remove upgrade-in-progress.html
			if [ -f "${docroot}/upgrade-in-progress.html" ]; then
				echo "  Removing ${docroot}/upgrade-in-progress.html"
				rm -f "${docroot}/upgrade-in-progress.html"
			fi
			
			# Process .htaccess file (restore ErrorDocument 404 and fix ownership)
			if [ -f "${docroot}/.htaccess" ]; then
				echo "  Processing ${docroot}/.htaccess"
				restore_htaccess_404 "${docroot}/.htaccess"
			fi
		fi
	fi
done

echo ""
# apache_reload() is globally sourced from get-env.sh
apache_reload
echo ""
echo "DEV reset complete!"
echo ""
