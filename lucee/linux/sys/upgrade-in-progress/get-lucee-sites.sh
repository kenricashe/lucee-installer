#!/bin/bash

# sudo /opt/lucee/sys/upgrade-in-progress/get-lucee-sites.sh

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

# Source shared helper for LUCEE_ROOT, UPG_DIR, IS_CPANEL
SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
. "${SCRIPT_DIR}/ENVIRONMENT.sh"
. "${SCRIPT_DIR}/shared-functions.sh"

TXTPATH_ALL_DATA="${UPG_DIR}/sites-configured.txt"
TXTPATH_ONLY_DOMAINS="${UPG_DIR}/active-domains.txt"

# Set RedHat httpd.conf path
if [ "$IS_CPANEL" = true ]; then
	RHEL_HTTPD_CONF="/etc/apache2/conf/httpd.conf"
else
	RHEL_HTTPD_CONF="/etc/httpd/conf/httpd.conf"
fi

# ------------------------------
# Exclusions and Lucee detection
# ------------------------------

declare -a EXCL_DOMAINS
declare -a EXCL_WILDCARDS
declare -a EXCL_PATHS

load_exclusions() {
	EXCL_DOMAINS=()
	EXCL_WILDCARDS=()
	EXCL_PATHS=()

	ensure_default_exclusions_file

	while IFS= read -r line || [ -n "$line" ]; do
		# Trim
		case "$line" in
			""|\#*)
				continue
				;;
			path:*|path\:*)
				p="${line#path:}"
				p="${p#path }"
				p="${p%%[[:space:]]}"
				p="${p%/}"
				if [ -n "$p" ]; then
					EXCL_PATHS+=("$p")
				fi
				;;
			*\*.*)
				# wildcard like *.example.com
				pat="$line"
				pat="${pat#*.}"
				if [ -n "$pat" ]; then
					EXCL_WILDCARDS+=("$pat")
				fi
				;;
			*)
				EXCL_DOMAINS+=("$line")
				;;
		esac
	done < "$EXCLUSIONS_FILE"
}

to_lower() {
	# lowercases arg
	printf '%s' "$1" | tr 'A-Z' 'a-z'
}

is_excluded_domain() {
	# $1 domain (lowercased)
	local d="$1"
	local x
	for x in "${EXCL_DOMAINS[@]}"; do
		if [ "$d" = "$(to_lower "$x")" ]; then
			return 0
		fi
	done
	for x in "${EXCL_WILDCARDS[@]}"; do
		# suffix match: example.com matches *.example.com
		case "$d" in
			*.$x)
				return 0
				;;
		esac
	done
	return 1
}

is_excluded_path() {
	# $1 path
	local p="${1%/}"
	local x
	for x in "${EXCL_PATHS[@]}"; do
		if [ -n "$x" ]; then
			case "$p" in
				"$x"|"$x"/*)
					return 0
					;;
			esac
		fi
	done
	return 1
}

has_cfml_files() {
	# $1 docroot
	local root="$1"
	if [ -z "$root" ] || [ ! -d "$root" ]; then
		return 1
	fi
	# Early-exit find for Lucee file types (.cfm, .cfc, .cfml, .cfs)
	if find "$root" -type f \( -iname '*.cfm' -o -iname '*.cfc' -o -iname '*.cfml' -o -iname '*.cfs' \) -print -quit 2>/dev/null | grep -q .; then
		return 0
	fi
	return 1
}

# ------------------------------
# Apache vhost parsing utilities
# ------------------------------

parse_vhosts_file() {
	# Emits lines: "domain|/path/to/docroot" for each vhost in a file
	local f="$1"
	if [ ! -f "$f" ]; then
		return 0
	fi
	awk -v IGNORECASE=1 '
		/^[ \t]*#/ { next }
		/<[ \t]*VirtualHost[> ]/ { in_vh=1; server=""; docroot=""; for (k in alias) delete alias[k]; ac=0; next }
		in_vh==1 && /<[ \t]*\/[ \t]*VirtualHost[> ]/ {
			# Only emit ServerName mapping, ignore ServerAlias to avoid duplicates
			if (docroot != "" && server != "") {
				printf "%s|%s\n", server, docroot
			}
			in_vh=0; server=""; docroot=""; for (k in alias) delete alias[k]; ac=0; next
		}
		in_vh==1 {
			if ($0 ~ /^[ \t]*ServerName[ \t]+/) {
				gsub(/^[ \t]*ServerName[ \t]+/, "", $0); gsub(/[ \t#].*$/, "", $0); server=$0
			}
			else if ($0 ~ /^[ \t]*ServerAlias[ \t]+/) {
				line=$0; sub(/^[ \t]*ServerAlias[ \t]+/, "", line); sub(/[#].*$/, "", line)
				n=split(line, arr, /[ \t]+/);
				for (i=1;i<=n;i++) { if (arr[i] != "") { ac++; alias[ac]=arr[i] } }
			}
			else if ($0 ~ /^[ \t]*DocumentRoot[ \t]+/) {
				gsub(/^[ \t]*DocumentRoot[ \t]+/, "", $0); gsub(/[ \t#].*$/, "", $0); docroot=$0
			}
		}
	' "$f"
}

collect_debian_vhosts() {
	# Outputs pairs: domain docroot (space-separated)
	local f
	for f in /etc/apache2/sites-enabled/*; do
		if [ -f "$f" ]; then
			parse_vhosts_file "$f"
		fi
	done | awk -F'|' '{print tolower($1) " " $2}' | sort -u
}

collect_rhel_config_files() {
	# Prints a unique list of conf files starting from $RHEL_HTTPD_CONF and following Include/IncludeOptional
	local -A SEEN
	local -a QUEUE
	local idx=0

	# Determine Apache ServerRoot based on httpd.conf location
	# On RHEL/Rocky the default is /etc/httpd with conf/httpd.conf under it.
	# Include/IncludeOptional paths that are not absolute are resolved relative to ServerRoot.
	local SERVER_ROOT
	if [ -n "$RHEL_HTTPD_CONF" ] && [ -f "$RHEL_HTTPD_CONF" ]; then
		# e.g. /etc/httpd/conf/httpd.conf -> /etc/httpd
		SERVER_ROOT=$(dirname "$(dirname "$RHEL_HTTPD_CONF")")
		# If ServerRoot directive exists, prefer it
		local SR_LINE SR_VAL
		SR_LINE=$(grep -iE '^[[:space:]]*ServerRoot[[:space:]]+' "$RHEL_HTTPD_CONF" 2>/dev/null | tail -n1)
		if [ -n "$SR_LINE" ]; then
			SR_VAL=$(printf '%s\n' "$SR_LINE" | awk '{ $1=""; sub(/^[ \t]+/, ""); print }')
			# Strip surrounding single/double quotes
			case "$SR_VAL" in
				"\""*) SR_VAL=${SR_VAL#\"}; SR_VAL=${SR_VAL%\"} ;;
				"'"*) SR_VAL=${SR_VAL#\'}; SR_VAL=${SR_VAL%\'} ;;
			esac
			if [ -n "$SR_VAL" ]; then
				SERVER_ROOT="$SR_VAL"
			fi
		fi
	else
		SERVER_ROOT="/etc/httpd"
	fi

	if [ -f "$RHEL_HTTPD_CONF" ]; then
		QUEUE+=("$RHEL_HTTPD_CONF")
		SEEN["$RHEL_HTTPD_CONF"]=1
	fi

	while [ $idx -lt ${#QUEUE[@]} ]; do
		local base="${QUEUE[$idx]}"
		idx=$((idx+1))
		# shellcheck disable=SC2016
		while IFS= read -r inc; do
			# Expand globs; include files under dirs
			for pat in $inc; do
				# Strip surrounding single/double quotes if present
				case "$pat" in
					"\""*) pat=${pat#\"}; pat=${pat%\"} ;;
					"'"*) pat=${pat#\'}; pat=${pat%\'} ;;
				esac
				# Resolve relative paths against ServerRoot
				local pat_abs
				if [ "${pat#/}" != "$pat" ]; then
					pat_abs="$pat"
				else
					pat_abs="$SERVER_ROOT/$pat"
				fi
				local expanded
				expanded=$(compgen -G "$pat_abs" 2>/dev/null || true)
				if [ -z "$expanded" ]; then
					continue
				fi
				local x
				for x in $expanded; do
					if [ -d "$x" ]; then
						while IFS= read -r cf; do
							if [ -f "$cf" ] && [ -z "${SEEN[$cf]}" ]; then
								SEEN["$cf"]=1; QUEUE+=("$cf")
							fi
						done < <(find "$x" -type f -name '*.conf' 2>/dev/null)
					elif [ -f "$x" ]; then
						if [ -z "${SEEN[$x]}" ]; then SEEN["$x"]=1; QUEUE+=("$x"); fi
					fi
				done
			done
		done < <(grep -iE "^[[:space:]]*Include(Optional)?[[:space:]]+" "$base" 2>/dev/null | awk '{ $1=""; sub(/^[ \t]+/, ""); print }')
	done

	# Print all seen files
	local k
	for k in "${!SEEN[@]}"; do
		printf '%s\n' "$k"
	done
}

collect_redhat_vhosts() {
	collect_rhel_config_files | while IFS= read -r f; do
		parse_vhosts_file "$f"
	done | awk -F'|' '{print tolower($1) " " $2}' | sort -u
}

write_results_noninteractive() {
	# Inputs via global arrays RESULT_DOMAINS and RESULT_DOCROOTS matched by index
	local i
	echo "" 
	echo "Saving results ..."
	
	# Start with empty files
	: > "$TXTPATH_ALL_DATA"
	: > "$TXTPATH_ONLY_DOMAINS"
	
	# Create temporary files for sorted data
	local tmp_all="$(mktemp)"
	local tmp_domains="$(mktemp)"
	
	# Write data to temporary files
	for (( i=0; i<${#RESULT_DOMAINS[@]}; i++ )); do
		local d="${RESULT_DOMAINS[$i]}"
		local r="${RESULT_DOCROOTS[$i]}"
		if [ -n "$d" ] && [ -n "$r" ]; then
			append_with_single_newline "$d $r" "$tmp_all"
			append_with_single_newline "$d" "$tmp_domains"
		fi
	done
	
	# Sort the data and write to files with proper newline at EOF
	sort -f "$tmp_all" | awk 'BEGIN{ORS="";} {print $0 "\n"}' > "$TXTPATH_ALL_DATA"
	sort -f "$tmp_domains" | awk 'BEGIN{ORS="";} {print $0 "\n"}' > "$TXTPATH_ONLY_DOMAINS"
	
	# Clean up temporary files
	rm -f "$tmp_all" "$tmp_domains"
	
	# Display file info
	echo ""
	echo "$TXTPATH_ALL_DATA"
	echo ""
	echo "A domains-only file (just in case you need it) was also saved as:"
	echo ""
	echo "$TXTPATH_ONLY_DOMAINS"
}

# Main script execution (non-interactive)

# If previous results exist, back them up automatically
if [ -f "$TXTPATH_ALL_DATA" ]; then
	# Use the shared backup_file function
	if backup_file "$TXTPATH_ALL_DATA"; then
		echo ""
		echo "Existing file backed up successfully"
	else
		echo ""
		echo "ERROR: Failed to back up existing file. Aborting."
		exit 1
	fi
fi

echo "Analyzing Lucee sites..."

load_exclusions

declare -A DOCROOT_TO_DOMAINS

echo "Collecting Apache VirtualHosts..."
if [ "$IS_DEBIAN" = true ]; then
	PAIR_LINES=$(collect_debian_vhosts)
elif [ -n "$CONF_DIR" ]; then
	PAIR_LINES=$(collect_redhat_vhosts)
else
	echo "ERROR: Unsupported environment for Apache detection."
	exit 1
fi

# Build docroot -> domains map
while IFS= read -r line; do
	if [ -z "$line" ]; then
		continue
	fi
	domain="${line%% *}"
	docroot="${line#* }"
	if [ -z "$domain" ] || [ -z "$docroot" ]; then
		continue
	fi
	# normalize
	domain=$(to_lower "$domain")
	docroot="${docroot%/}"
	current="${DOCROOT_TO_DOMAINS[$docroot]}"
	case " $current " in
		*" $domain "*) ;;
		*) DOCROOT_TO_DOMAINS[$docroot]="$current $domain" ;;
	esac
done <<< "$PAIR_LINES"


# Evaluate Lucee presence per docroot and assemble final results
declare -a RESULT_DOMAINS
declare -a RESULT_DOCROOTS

for docroot in "${!DOCROOT_TO_DOMAINS[@]}"; do
	if is_excluded_path "$docroot"; then
		echo "Skipping excluded path: $docroot"
		continue
	fi
	printf '\n Scanning for Lucee files in: %s\n' "$docroot"
	if has_cfml_files "$docroot"; then
		for d in ${DOCROOT_TO_DOMAINS[$docroot]}; do
			if is_excluded_domain "$d"; then
				echo "  - Excluded domain: $d"
				continue
			fi
			RESULT_DOMAINS+=("$d")
			RESULT_DOCROOTS+=("$docroot")
		done
	else
		echo "  - No Lucee files detected"
	fi
done

# Sort the results using temporary files (more memory-efficient for large datasets)
echo ""
echo "Sorting results..."

# Create temporary files
TMP_UNSORTED="$(mktemp)"
TMP_SORTED="$(mktemp)"

# Write domain and docroot pairs to temporary file
for i in "${!RESULT_DOMAINS[@]}"; do
	append_with_single_newline "${RESULT_DOMAINS[$i]}|${RESULT_DOCROOTS[$i]}" "$TMP_UNSORTED"
done

# Sort the temporary file (case-insensitive)
sort -f "$TMP_UNSORTED" > "$TMP_SORTED"

# Clear the original arrays
RESULT_DOMAINS=()
RESULT_DOCROOTS=()

# Read back the sorted data
while IFS='|' read -r domain docroot || [ -n "$domain" ]; do
	RESULT_DOMAINS+=("$domain")
	RESULT_DOCROOTS+=("$docroot")
done < "$TMP_SORTED"

# Clean up temporary files
rm -f "$TMP_UNSORTED" "$TMP_SORTED"

write_results_noninteractive
