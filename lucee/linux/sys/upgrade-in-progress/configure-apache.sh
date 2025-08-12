#!/bin/bash

# Deploy:
# cd /path/to/this/script
# cp ./configure-apache.sh /opt/lucee/sys/upgrade-in-progress/configure-apache.sh
# chmod +x /opt/lucee/sys/upgrade-in-progress/configure-apache.sh

# Update:
# cat ./configure-apache.sh | sudo tee /opt/lucee/sys/upgrade-in-progress/configure-apache.sh

# Execute:
# sudo /opt/lucee/sys/upgrade-in-progress/configure-apache.sh

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root or with sudo."
	exit 1
fi

# Source shared helper for LUCEE_ROOT, UPG_DIR, IS_CPANEL
SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
. "${SCRIPT_DIR}/get-env.sh"

# preflight: required files must exist at /opt path used by per-site Includes and docroot copy
DETECT_CONF="${UPG_DIR}/lucee-detect-upgrade.conf"
UPG_HTML="${UPG_DIR}/upgrade-in-progress.html"
if [ ! -f "$DETECT_CONF" ]; then
	echo "Error: Required include not found: $DETECT_CONF"
	echo "Run deploy-to-opt-lucee-sys.sh to deploy the package, then retry."
	exit 1
fi
if [ ! -f "$UPG_HTML" ]; then
	echo "Error: Required HTML not found: $UPG_HTML"
	echo "Run deploy-to-opt-lucee-sys.sh to deploy the package, then retry."
	exit 1
fi

# Use [.] instead of \. to avoid awk treating "\." as an escape in string constants
LUCEE404_REGEX='^[[:space:]]*ErrorDocument[[:space:]]+404[[:space:]]+/[^[:space:]]*[.](cfm|cfml|cfc|cfs)([^[:alnum:]_]|$)'
# Any ErrorDocument 404 (any target), for precedence checks and comment-all behavior
ANY404_REGEX='^[[:space:]]*ErrorDocument[[:space:]]+404[[:space:]]+'

if [ ! -f "$SITES_FILE" ]; then
	echo "Lucee sites data file not found."
	echo ""
	echo "Press Enter to get data..."
	read -r _
	${SUDO} "${UPG_DIR}/get-lucee-sites.sh"
	# Re-check for generated file
	if [ ! -f "$SITES_FILE" ]; then
		echo "Error: Failed to generate sites data file. Aborting now."
		exit 1
	fi
	clear
fi

# cPanel userdata paths (IS_CPANEL provided by get-env.sh)
if [ "$IS_CPANEL" = true ]; then
	CPANEL_USERDATA_SSL_PATH="/etc/apache2/conf.d/userdata/ssl/2_4"
	CPANEL_USERDATA_STD_PATH="/etc/apache2/conf.d/userdata/std/2_4"
fi

# Centralized backup root; backs up mirror paths beneath this directory
BACKUP_ROOT="${UPG_DIR}/backups"
# Single timestamp for this run; all backups go under this subfolder for easy restore
BACKUP_TS="$(date +%Y-%m-%d-%H%M%S)"

# LUCEE_ROOT is available via helper; UPG_DIR already computed above

# Apache config test helper: prefer apache2ctl, then apachectl, then httpd
apache_config_test() {
	if command -v apache2ctl >/dev/null 2>&1; then
		apache2ctl -t
	elif command -v apachectl >/dev/null 2>&1; then
		apachectl -t
	elif command -v httpd >/dev/null 2>&1; then
		httpd -t
	else
		echo "Warning: No apache control binary found for config test; skipping syntax check."
		return 0
	fi
}

# Extract the last matching ErrorDocument 404 *.cf* even if it is commented (e.g., from prior runs)
# Strips leading '# ' from the extracted lines and excludes our NOTE lines
extract_404_block_allow_commented() {
	local file="$1"
	[ -f "$file" ] || return 1
	awk -v IGNORECASE=1 -v pat="$LUCEE404_REGEX" '
		{ lines[++n]=$0 }
		# match active or commented ErrorDocument 404 *.cf*
		$0 ~ /^[\t ]*#?[\t ]*ErrorDocument[\t ]+404[\t ]+/ && $0 ~ pat { ln=n }
		END {
			if (!ln) exit 1
			start=ln-1
			while (start>=1 && (lines[start] ~ /^[\t ]*#/ || lines[start] ~ /^[\t ]*$/)) start--
			for (i=start+1; i<ln; i++) {
				if (lines[i] ~ /NOTE: ErrorDocument 404/) continue
				# strip leading comment markers
				sub(/^[\t ]*#[\t ]?/, "", lines[i])
				print lines[i]
			}
			line=lines[ln]
			sub(/^[\t ]*#[\t ]?/, "", line)
			print line
		}
	' "$file"
}

# Return 0 if the last ErrorDocument 404 in file targets .cf*, else return 1
last_404_is_cf() {
	local file="$1"
	[ -f "$file" ] || return 1
	awk -v IGNORECASE=1 '
		/^[\t ]*#/ { next }
		# capture last ErrorDocument 404 target (rest of line after the code)
		match($0, /^[\t ]*ErrorDocument[\t ]+404[\t ]+(.*)$/, m) { last=m[1] }
		END {
			if (!length(last)) exit 1
			# consider it CF only if it ends with .cfm/.cfml/.cfc/.cfs (optionally followed by non-word chars)
			if (last ~ /\.(cfm|cfml|cfc|cfs)([^[:alnum:]_]|$)/) exit 0; else exit 1
		}
	' "$file"
}

# Comment out ALL ErrorDocument 404 lines (any target) with an explanatory note
comment_all_404_lines() {
	local file="$1"
	[ -f "$file" ] || return 0
	local tmp base
	# Preserve ownership and mode (important for user-owned .htaccess)
	local _uid _gid _mode
	_uid=$(stat -c '%u' "$file" 2>/dev/null || echo "")
	_gid=$(stat -c '%g' "$file" 2>/dev/null || echo "")
	_mode=$(stat -c '%a' "$file" 2>/dev/null || echo "")
	tmp=$(mktemp)
	base=$(basename "$file")
	if [ "$base" = ".htaccess" ]; then
		awk -v IGNORECASE=1 -v pat="$ANY404_REGEX" -v note="# NOTE: ErrorDocument 404 moved by /opt/lucee/sys/upgrade-in-progress/configure-apache.sh into Apache vhost/userdata and disabled during upgrades. See per-site Include to /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf" '
			{ lines[++n]=$0 }
			END {
				for (i=1;i<=n;i++) {
					if (lines[i] ~ pat) {
						print note
						if (lines[i] ~ /^[\t ]*#/) { print lines[i] } else { print "# " lines[i] }
					} else { print lines[i] }
				}
			}
		' "$file" > "$tmp"
	else
		awk -v IGNORECASE=1 -v pat="$ANY404_REGEX" -v note="# NOTE: ErrorDocument 404 disabled/commented by /opt/lucee/sys/upgrade-in-progress/configure-apache.sh (managed inline and wrapped in vhost/userdata)." '
			{ lines[++n]=$0 }
			END {
				for (i=1;i<=n;i++) {
					if (lines[i] ~ pat) {
						print note
						if (lines[i] ~ /^[\t ]*#/) { print lines[i] } else { print "# " lines[i] }
					} else { print lines[i] }
				}
			}
		' "$file" > "$tmp"
	fi
	# Write back in place to preserve existing mode/ownership
	cat "$tmp" > "$file"
	rm -f "$tmp"
	# Restore ownership/mode if we could read them (chown/chmod may fail for non-root; ignore errors)
	if [ -n "$_uid" ] && [ -n "$_gid" ]; then
		chown "$_uid:$_gid" "$file" 2>/dev/null || true
	fi
	if [ -n "$_mode" ]; then
		chmod "$_mode" "$file" 2>/dev/null || true
	fi
}

# Backup helper: mirror source path under ${BACKUP_ROOT}/${BACKUP_TS}
backup_file() {
	local src="$1"
	[ -f "$src" ] || return 0
	local dest="${BACKUP_ROOT}/${BACKUP_TS}${src}"
	local dest_dir
	dest_dir=$(dirname "$dest")
	mkdir -p "$dest_dir"
	cp -f "$src" "$dest"
}

# Extract the first matching ErrorDocument 404 *.cf* line and its contiguous preceding comments
# Prints the block to stdout; returns non-zero if not found
extract_404_block() {
	local file="$1"
	[ -f "$file" ] || return 1
	awk -v IGNORECASE=1 -v pat="$LUCEE404_REGEX" '
		{ lines[++n]=$0 }
		$0 ~ pat { ln=n }
		END {
			if (!ln) exit 1
			start=ln-1
			while (start>=1 && (lines[start] ~ /^[\t ]*#/ || lines[start] ~ /^[\t ]*$/)) start--
			for (i=start+1; i<ln; i++) print lines[i]
			print lines[ln]
		}
	' "$file"
}

# Remove the first matching ErrorDocument 404 *.cf* line and its contiguous preceding comments from file (in-place)
remove_404_block() {
	local file="$1"
	[ -f "$file" ] || return 0
	local tmp
	tmp=$(mktemp)
	local base
	base=$(basename "$file")
	if [ "$base" = ".htaccess" ]; then
		# In .htaccess: comment out ALL ErrorDocument 404 lines with a note; migration uses the last via extract_404_block()
		awk -v IGNORECASE=1 -v pat="$LUCEE404_REGEX" -v note="# NOTE: ErrorDocument 404 moved by /opt/lucee/sys/upgrade-in-progress/configure-apache.sh into Apache vhost/userdata and disabled during upgrades. See per-site Include to /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf" '
			{ lines[++n]=$0 }
			END {
				for (i=1;i<=n;i++) {
					if (lines[i] ~ pat) {
						print note
						if (lines[i] ~ /^[\t ]*#/) {
							print lines[i]
						} else {
							print "# " lines[i]
						}
					} else {
						print lines[i]
					}
				}
			}
		' "$file" > "$tmp"
	else
		# In vhost/userdata files: comment out ALL ErrorDocument 404 lines with a note
		awk -v IGNORECASE=1 -v pat="$LUCEE404_REGEX" -v note="# NOTE: ErrorDocument 404 disabled/commented by /opt/lucee/sys/upgrade-in-progress/configure-apache.sh (managed inline and wrapped in vhost/userdata)." '
			{ lines[++n]=$0 }
			END {
				for (i=1;i<=n;i++) {
					if (lines[i] ~ pat) {
						print note
						if (lines[i] ~ /^[\t ]*#/) {
							print lines[i]
						} else {
							print "# " lines[i]
						}
					} else {
						print lines[i]
					}
				}
			}
		' "$file" > "$tmp"
	fi
	if [ $? -eq 0 ]; then
		mv -f "$tmp" "$file"
	else
		rm -f "$tmp"
		return 1
	fi
}

# Insert a wrapped block before the closing </VirtualHost> of the block whose ServerName/ServerAlias matches domain (3rd arg).
# Optional 4th arg: port filter (e.g., 80 or 443) to target a specific vhost in files containing multiple blocks.
# If no matching block is found, fall back to the last matching port block, then to the last </VirtualHost> in the file.
insert_wrapped_block_before_vhost_close() {
	local vhost_file="$1"
	local block_text="$2"
	local domain_match="$3"
	local port_filter="$4"
	[ -f "$vhost_file" ] || return 1
	local tmp
	tmp=$(mktemp)
	awk -v blk="$block_text" -v dom="$domain_match" -v port="$port_filter" '
		BEGIN { inblk=0; match_this=0; n=0; last=0; last_port_close=0; target_close=0; blk_port="" }
		{ lines[++n]=$0 }
		/<VirtualHost[> \t]/ { inblk=1; match_this=0; blk_port=""; if (match($0, /<VirtualHost[^>]*:([0-9]+)/, m)) { blk_port=m[1] } }
		inblk && tolower($0) ~ /^[\t ]*server(name|alias)[\t ]+/ {
			if (dom == "") { match_this=1 }
			else {
				low=$0
				if (tolower(low) ~ /(^|[\t ])[\t ]*server(name|alias)[\t ]+([^#]*)/) {
					names=tolower(substr(low, RSTART+RLENGTH- length(substr(low, RSTART+RLENGTH))+1))
					split(names, a, /[\t ]+/)
					for (j in a) { if (a[j]==tolower(dom)) { match_this=1; break } }
				}
			}
		}
		/<\/VirtualHost>/ {
			last=n
			if (inblk && (port=="" || blk_port==port)) { last_port_close=n }
			if (inblk && target_close==0 && (dom=="" || match_this) && (port=="" || blk_port==port)) { target_close=n }
			inblk=0; match_this=0
		}
		END {
			if (target_close==0) {
				if (port!="" && last_port_close>0) target_close=last_port_close
				else target_close=last
			}
			if (target_close==0) exit 1
			# Normalize and indent block: remove leading blank lines and strip leading whitespace
			nbl=split(blk, _b, /\n/)
			blk_norm=""
			seen_content=0
			for (k=1;k<=nbl;k++) {
				line=_b[k]
				if (!seen_content && line ~ /^[ \t]*$/) continue
				seen_content=1
				gsub(/\r/, "", line)
				sub(/^[ \t]*/, "", line)
				blk_norm = blk_norm "\t\t" line "\n"
			}
			for (i=1;i<=n;i++) {
				if (i==target_close) {
					print "\t<IfDefine !LUCEE_UPGRADE_IN_PROGRESS>"
					printf "%s", blk_norm
					print "\t</IfDefine>"
					print ""
				}
				print lines[i]
			}
		}
	' "$vhost_file" > "$tmp"
	if [ $? -eq 0 ]; then
		mv -f "$tmp" "$vhost_file"
	else
		rm -f "$tmp"
		return 1
	fi
}

# Return 0 if a 404 block already exists inside our IfDefine wrapper in the given file
has_wrapped_404_block() {
	local file="$1"
	[ -f "$file" ] || return 1
	awk -v IGNORECASE=1 '
		/<IfDefine[\t ]+!LUCEE_UPGRADE_IN_PROGRESS>/,/<\/IfDefine>/ {
			if ($0 ~ /^[\t ]*ErrorDocument[\t ]+404[\t ]+/) { found=1 }
		}
		END { exit found ? 0 : 1 }
	' "$file"
}

# Return 0 if a wrapped 404 exists inside our IfDefine wrapper within the vhost for the given domain and port.
has_wrapped_404_block_in_vhost() {
	local file="$1"
	local domain_match="$2"
	local port_filter="$3"
	[ -f "$file" ] || return 1
	awk -v IGNORECASE=1 -v dom="$domain_match" -v port="$port_filter" '
		BEGIN { inblk=0; match_this=0; blk_port=""; inwrap=0; found=0 }
		/<VirtualHost[> \t]/ { inblk=1; match_this=0; blk_port=""; if (match($0, /<VirtualHost[^>]*:([0-9]+)/, m)) { blk_port=m[1] } }
		inblk && tolower($0) ~ /^[\t ]*server(name|alias)[\t ]+/ {
			if (dom == "") { match_this=1 }
			else {
				low=$0
				if (tolower(low) ~ /(^|[\t ])[\t ]*server(name|alias)[\t ]+([^#]*)/) {
					names=tolower(substr(low, RSTART+RLENGTH- length(substr(low, RSTART+RLENGTH))+1))
					split(names, a, /[\t ]+/)
					for (j in a) { if (a[j]==tolower(dom)) { match_this=1; break } }
				}
			}
		}
		inblk && $0 ~ /<IfDefine[ \t]+!LUCEE_UPGRADE_IN_PROGRESS>/ { inwrap=1 }
		inblk && inwrap && $0 ~ /<\/IfDefine>/ { inwrap=0 }
		inblk && inwrap && $0 ~ /^[\t ]*ErrorDocument[\t ]+404[\t ]+/ {
			if ((port=="" || blk_port==port) && (dom=="" || match_this)) { found=1 }
		}
		/<\/VirtualHost>/ {
			if (found) exit 0
			inblk=0; match_this=0; inwrap=0
		}
		END { exit found ? 0 : 1 }
	' "$file"
}

# Ensure the per-site Include line exists inside the targeted vhost (by domain and optional port).
ensure_include_in_vhost() {
	local vhost_file="$1"
	local domain_match="$2"
	local port_filter="$3"
	local tmp
	local include_line="Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf"
	[ -f "$vhost_file" ] || return 1
	tmp=$(mktemp)
	awk -v dom="$domain_match" -v port="$port_filter" -v inc="$include_line" '
		BEGIN { inblk=0; match_this=0; blk_port=""; inserted=0; had_inc=0 }
		{ line=$0; lines[++n]=$0 }
		/<VirtualHost[> \t]/ { inblk=1; match_this=0; blk_port=""; had_inc=0; if (match($0, /<VirtualHost[^>]*:([0-9]+)/, m)) { blk_port=m[1] } }
		inblk && tolower($0) ~ /^[\t ]*server(name|alias)[\t ]+/ {
			if (dom == "") { match_this=1 }
			else {
				low=$0
				if (tolower(low) ~ /(^|[\t ])[\t ]*server(name|alias)[\t ]+([^#]*)/) {
					names=tolower(substr(low, RSTART+RLENGTH- length(substr(low, RSTART+RLENGTH))+1))
					split(names, a, /[\t ]+/)
					for (j in a) { if (a[j]==tolower(dom)) { match_this=1; break } }
				}
			}
		}
		inblk && $0 ~ /^[\t ]*Include(Optional)?[\t ]+\/opt\/lucee\/sys\/upgrade-in-progress\/lucee-detect-upgrade\.conf([\t ]|$)/ { had_inc=1 }
		{
			if ($0 ~ /<\/VirtualHost>/) {
				if (inblk && inserted==0 && (dom=="" || match_this) && (port=="" || blk_port==port) && had_inc==0) {
					print "\t" inc
					print ""
					inserted=1
				}
				inblk=0; match_this=0; had_inc=0
			}
			print $0
		}
	' "$vhost_file" > "$tmp"
	if [ $? -eq 0 ]; then
		mv -f "$tmp" "$vhost_file"
	else
		rm -f "$tmp"
		return 1
	fi
}

# Check if mod_headers is enabled (needed for X-Lucee-Upgrade header polling)
headers_module_enabled() {
	if command -v apache2ctl >/dev/null 2>&1; then
		apache2ctl -M 2>/dev/null | grep -qiE '(^|[^[:alnum:]_])headers_module([^[:alnum:]_]|$)'
		return $?
	elif command -v apachectl >/dev/null 2>&1; then
		apachectl -M 2>/dev/null | grep -qiE '(^|[^[:alnum:]_])headers_module([^[:alnum:]_]|$)'
		return $?
	elif command -v httpd >/dev/null 2>&1; then
		httpd -M 2>/dev/null | grep -qiE '(^|[^[:alnum:]_])headers_module([^[:alnum:]_]|$)'
		return $?
	fi
	# If we can't detect, do not block; treat as enabled to avoid false alarms
	return 0
}

# Warn if conflicting AJP/mod_cfml directives already exist in global config
warn_existing_ajp_modcfml() {
	# Args: list of directories to scan
	local found=""
	local dir
	for dir in "$@"; do
		[ -d "$dir" ] || continue
		local hits
		# Only match active (non-commented) lines with AJP/mod_cfml directives, excluding our managed file
		hits=$(grep -RniE '^[[:space:]]*[^#].*(ProxyPass(Match|Reverse).*ajp://|ModCFML_SharedKey|LoadModule[[:space:]]+modcfml_module)' "$dir" 2>/dev/null | grep -v 'lucee-ajp-and-mod_cfml.conf' || true)
		if [ -n "$hits" ]; then
			found+="\n${hits}"
		fi
	done
	if [ -n "$found" ]; then
		echo "Warning: Existing AJP/mod_cfml directives detected in global Apache config."
		echo "They may conflict with the generated lucee-ajp-and-mod_cfml.conf. Please remove duplicates:"
		echo "$found"
	fi
}

# Resolve Tomcat server.xml path
resolve_server_xml() {
	if [ -n "$TOMCAT_SERVER_XML" ] && [ -f "$TOMCAT_SERVER_XML" ]; then
		echo "$TOMCAT_SERVER_XML"
		return 0
	fi

	for candidate in \
		"${LUCEE_ROOT}/tomcat/conf/server.xml" \
		"${LUCEE_ROOT}/tomcat*/conf/server.xml" \
		"/etc/tomcat*/server.xml"; do
		if ls $candidate >/dev/null 2>&1; then
			# Return the first match from glob expansion
			for f in $candidate; do
				[ -f "$f" ] && { echo "$f"; return 0; }
			done
		fi
	done
	echo "" # not found
}

# Parse AJP port/secret and mod_cfml shared key from server.xml
parse_server_xml() {
	local sx="$1"
	AJP_PORT="8009" # default fallback
	AJP_SECRET=""
	MODCFML_SHARED_KEY=""
	if [ -f "$sx" ]; then
		# AJP Connector line
		local ajp_line
		ajp_line=$(grep -i "<Connector" "$sx" | grep -i "ajp" | head -n1 || true)
		if [ -n "$ajp_line" ]; then
			AJP_PORT=$(echo "$ajp_line" | sed -n 's/.*port="\([0-9]\{2,5\}\)".*/\1/p')
			AJP_SECRET=$(echo "$ajp_line" | sed -n 's/.*secret="\([^"]\+\)".*/\1/p')
		fi
		# mod_cfml Valve line
		local vline
		vline=$(grep -i "<Valve" "$sx" | grep -i "mod_cfml" | head -n1 || true)
		if [ -n "$vline" ]; then
			MODCFML_SHARED_KEY=$(echo "$vline" | sed -n 's/.*sharedKey="\([^"]\+\)".*/\1/p')
			if [ -z "$MODCFML_SHARED_KEY" ]; then
				MODCFML_SHARED_KEY=$(echo "$vline" | sed -n 's/.*secret="\([^"]\+\)".*/\1/p')
			fi
		fi
	fi
}

# Render the AJP+mod_cfml template into a destination file
render_ajp_template() {
	local dest="$1"
	local tmpl="${UPG_DIR}/lucee-ajp-and-mod_cfml.conf"
	if [ ! -f "$tmpl" ]; then
		echo "Warning: Template not found: $tmpl"
		return 1
	fi
	local sx
	sx=$(resolve_server_xml)
	parse_server_xml "$sx"
	# build replacement values
	local port="$AJP_PORT"
	local ajpsec="$AJP_SECRET"
	local shared="$MODCFML_SHARED_KEY"
	# escape for sed
	local esc_ajpsec esc_shared
	esc_ajpsec=$(printf '%s' "$ajpsec" | sed -e 's/[\&/]/\\&/g')
	esc_shared=$(printf '%s' "$shared" | sed -e 's/[\&/]/\\&/g')
	# substitute: port 8009 -> actual port; secrets replace REDACTED
	sed \
		-e "s#ajp://127.0.0.1:8009/#ajp://127.0.0.1:${port}/#g" \
		-e "s#secret=REDACTED#secret=${esc_ajpsec}#g" \
		-e "s#ModCFML_SharedKey \"REDACTED\"#ModCFML_SharedKey \"${esc_shared}\"#g" \
		"$tmpl" > "$dest"
	chmod 644 "$dest"
	# Post-render warnings
	if [ -z "$ajpsec" ]; then
		echo "Warning: AJP secret not found in server.xml (${sx:-unknown}). You should set an AJP secret and update Apache accordingly."
	fi
	if [ -z "$shared" ]; then
		echo "Warning: mod_cfml shared key not found in server.xml (${sx:-unknown}). You should set ModCFML_SharedKey consistently."
	fi
}

# Ensure global Apache confs exist and are set to normal-state defaults
# Normal state: AJP/mod_cfml enabled; upgrade flag disabled
ensure_global_confs() {
	# Debian/Ubuntu
	if command -v a2enconf >/dev/null 2>&1; then
		conf_avail="/etc/apache2/conf-available"
		opt_file="${UPG_DIR}/lucee-upgrade-in-progress.conf"
		if [ -f "$opt_file" ] && [ ! -f "${conf_avail}/lucee-upgrade-in-progress.conf" ]; then
			echo "Installing global lucee-upgrade-in-progress.conf into ${conf_avail}/"
			cp -f "$opt_file" "${conf_avail}/lucee-upgrade-in-progress.conf"
		fi
		# Warn if conflicting AJP/mod_cfml config is present elsewhere in global dirs
		warn_existing_ajp_modcfml \
			"/etc/apache2/conf-available" \
			"/etc/apache2/conf-enabled"
		# Ensure AJP+mod_cfml global conf exists (generate from template if missing)
		if [ ! -f "${conf_avail}/lucee-ajp-and-mod_cfml.conf" ]; then
			echo "Generating global lucee-ajp-and-mod_cfml.conf in ${conf_avail}/ from template via server.xml"
			render_ajp_template "${conf_avail}/lucee-ajp-and-mod_cfml.conf" || true
		fi
		# Ensure upgrade flag is disabled by default
		a2disconf lucee-upgrade-in-progress >/dev/null 2>&1 || true
		# Ensure AJP+mod_cfml is enabled if present in conf-available
		if [ -f "${conf_avail}/lucee-ajp-and-mod_cfml.conf" ]; then
			a2enconf lucee-ajp-and-mod_cfml >/dev/null 2>&1 || true
		fi
		# Warn if no AJP proxying detected in global config
		ajp_detected=false
		if [ -f "${conf_avail}/lucee-ajp-and-mod_cfml.conf" ] || [ -f "/etc/apache2/conf-enabled/lucee-ajp-and-mod_cfml.conf" ]; then
			ajp_detected=true
		elif grep -Rqi 'ajp://' /etc/apache2/ 2>/dev/null; then
			ajp_detected=true
		fi
		if [ "$ajp_detected" != true ]; then
			echo "Warning: AJP proxying not detected in global Apache config (Debian/Ubuntu). Normal operation expects AJP/mod_cfml enabled."
		fi
		# Warn if mod_headers isn't enabled (needed for HEAD-based polling via X-Lucee-Upgrade)
		if ! headers_module_enabled; then
			echo "Warning: Apache mod_headers does not appear to be enabled."
			echo "The upgrade status page relies on X-Lucee-Upgrade header for HEAD polling."
			echo "Enable with: a2enmod headers && systemctl reload apache2"
		fi
		return
	fi

	# RHEL family and cPanel
	if [ -d /etc/httpd/conf.d ] || [ -d /etc/apache2/conf.d ]; then
		if [ "$IS_CPANEL" = true ]; then
			confd="/etc/apache2/conf.d"
		else
			confd="/etc/httpd/conf.d"
		fi
		opt_file="${UPG_DIR}/lucee-upgrade-in-progress.conf"
		# Ensure a disabled copy exists if neither form exists
		if [ -f "$opt_file" ] && [ ! -f "${confd}/lucee-upgrade-in-progress.disabled" ] && [ ! -f "${confd}/lucee-upgrade-in-progress.conf" ]; then
			echo "Installing global lucee-upgrade-in-progress.disabled into ${confd}/"
			cp -f "$opt_file" "${confd}/lucee-upgrade-in-progress.disabled"
		fi
		# Warn if conflicting AJP/mod_cfml config is present elsewhere in global dir
		warn_existing_ajp_modcfml "$confd"
		# Ensure AJP+mod_cfml global conf exists (generate from template if missing)
		if [ ! -f "${confd}/lucee-ajp-and-mod_cfml.conf" ] && [ ! -f "${confd}/lucee-ajp-and-mod_cfml.conf.disabled" ]; then
			echo "Generating global ${confd}/lucee-ajp-and-mod_cfml.conf from template via server.xml (enabled in normal state)"
			render_ajp_template "${confd}/lucee-ajp-and-mod_cfml.conf" || true
		fi
		# Ensure normal state: upgrade flag disabled
		if [ -f "${confd}/lucee-upgrade-in-progress.conf" ]; then
			# Backup existing .disabled if present to avoid clobbering (mirrored under BACKUP_ROOT)
			if [ -f "${confd}/lucee-upgrade-in-progress.disabled" ]; then
				echo "Backing up existing ${confd}/lucee-upgrade-in-progress.disabled"
				backup_file "${confd}/lucee-upgrade-in-progress.disabled"
			fi
			echo "Disabling lucee-upgrade-in-progress.conf (normal state)"
			mv -f "${confd}/lucee-upgrade-in-progress.conf" "${confd}/lucee-upgrade-in-progress.disabled"
		fi
		# Ensure AJP+mod_cfml is enabled (rename from .disabled if needed)
		if [ -f "${confd}/lucee-ajp-and-mod_cfml.conf.disabled" ] && [ ! -f "${confd}/lucee-ajp-and-mod_cfml.conf" ]; then
			echo "Enabling lucee-ajp-and-mod_cfml.conf (normal state)"
			mv -f "${confd}/lucee-ajp-and-mod_cfml.conf.disabled" "${confd}/lucee-ajp-and-mod_cfml.conf"
		fi
		# Warn if no AJP proxying detected in global config
		ajp_detected=false
		if [ -f "${confd}/lucee-ajp-and-mod_cfml.conf" ] || [ -f "${confd}/lucee-ajp-and-mod_cfml.conf.disabled" ]; then
			ajp_detected=true
		elif grep -Rqi 'ajp://' "$confd" 2>/dev/null; then
			ajp_detected=true
		fi
		if [ "$ajp_detected" != true ]; then
			echo "Warning: AJP proxying not detected in global Apache config (${confd}). Normal operation expects AJP/mod_cfml enabled."
		fi
		# Warn if mod_headers isn't enabled (needed for HEAD-based polling via X-Lucee-Upgrade)
		if ! headers_module_enabled; then
			echo "Warning: Apache mod_headers does not appear to be enabled."
			echo "The upgrade status page relies on X-Lucee-Upgrade header for HEAD polling."
			echo "Ensure headers_module is loaded (usually enabled by default on RHEL/cPanel)."
		fi
		return
	fi
}

# Function to copy upgrade-in-progress.html to DocumentRoot
copy_upgrade_html() {
	local docroot=$1
	# Backup existing docroot file (mirrored under BACKUP_ROOT)
	backup_file ${docroot}/upgrade-in-progress.html
	cp -f "${UPG_DIR}/upgrade-in-progress.html" ${docroot}/upgrade-in-progress.html
	chown --reference=${docroot} ${docroot}/upgrade-in-progress.html 2>/dev/null || true
}

# Function to configure Debian sites
configure_site_debian() {
	local domain=$1
	local docroot=$2
	
	echo "Processing $domain with DocumentRoot: $docroot"
	
	# Copy upgrade-in-progress.html to DocumentRoot
	copy_upgrade_html "$docroot"
	
	# Check if the SSL site in sites-enabled is a regular file (not a symlink)
	# This would happen if a previous buggy version of the script replaced the symlink
	enabled_ssl_conf="/etc/apache2/sites-enabled/${domain}-ssl.conf"
	if [ -f "$enabled_ssl_conf" ] && [ ! -L "$enabled_ssl_conf" ]; then
		echo "  Found regular file instead of symlink at $enabled_ssl_conf"
		echo "  Restoring symlink structure..."
		# Backup the unexpected regular file before removal (mirrored under BACKUP_ROOT)
		echo "  Backing up $enabled_ssl_conf"
		backup_file "$enabled_ssl_conf"
		# Get the site name without extension and remove the stray file
		site_name="${domain}-ssl"
		rm -f "$enabled_ssl_conf"
		
		# Enable the site (creates a proper symlink)
		a2ensite "$site_name" > /dev/null 2>&1
		
		echo "  Symlink restored for $site_name"
	fi
	
	# Find the SSL site configuration file in sites-available directly
	ssl_conf_file="/etc/apache2/sites-available/${domain}-ssl.conf"
	if [ ! -f "$ssl_conf_file" ]; then
		# Try to find by ServerName
		ssl_conf_file=$(grep -l "ServerName $domain" /etc/apache2/sites-available/*-ssl.conf 2>/dev/null | head -1)
	fi
	
	if [ -f "$ssl_conf_file" ]; then
		echo "  Updating $ssl_conf_file"
		# Determine current state before deciding to edit
		local ssl_404_block=""
		local ssl_from_htaccess="false"
		local ssl_include_present="false"
		local ssl_has_wrapped="false"
		local ssl_needs_wrapper="false"
		if grep -q 'Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf' "$ssl_conf_file"; then
			ssl_include_present="true"
		fi
		if has_wrapped_404_block "$ssl_conf_file"; then
			ssl_has_wrapped="true"
		fi
		# Decide if this vhost actually needs a wrapped 404
		if [ -f "$docroot/.htaccess" ] && last_404_is_cf "$docroot/.htaccess"; then
			ssl_needs_wrapper="true"
		fi
		if [ "$ssl_needs_wrapper" != "true" ] && last_404_is_cf "$ssl_conf_file"; then
			ssl_needs_wrapper="true"
		fi
		if [ "$ssl_needs_wrapper" != "true" ] && [ -f "$docroot/.htaccess" ] && grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
			ssl_needs_wrapper="true"
		fi
		# If both wrapped block and Include already present, leave file untouched (idempotent)
		if [ "$ssl_include_present" = "true" ] && { [ "$ssl_has_wrapped" = "true" ] || [ "$ssl_needs_wrapper" != "true" ]; }; then
			echo "  Existing wrapped 404 block detected in SSL vhost; leaving as-is"
			# Extract it so HTTP vhost can reuse if needed
			ssl_404_block=$(extract_404_block "$ssl_conf_file" || true)
		else
			# We will modify the file; make a backup (mirrored under BACKUP_ROOT)
			backup_file "$ssl_conf_file"
			# Prefer .htaccess (more specific) over vhost for effective 404
			if echo "" | grep -q ""; then :; fi # keep shellcheck quiet about local before use
			if [ -f "$docroot/.htaccess" ] && last_404_is_cf "$docroot/.htaccess"; then
				ssl_404_block=$(extract_404_block "$docroot/.htaccess" || true)
				if [ -n "$ssl_404_block" ]; then
					echo "  Migrating 404 from .htaccess into SSL vhost (authoritative)"
					ssl_from_htaccess="true"
					# Comment out any pre-existing 404s in vhost as they are superseded
					if grep -qiE "$ANY404_REGEX" "$ssl_conf_file"; then
						echo "  Commenting out pre-existing 404s in SSL vhost (superseded by .htaccess)"
						backup_file "$ssl_conf_file"
						comment_all_404_lines "$ssl_conf_file"
					fi
				fi
			fi
			# If .htaccess has already been commented by a prior run, recover the 404 from it
			if [ -z "$ssl_404_block" ] && [ -f "$docroot/.htaccess" ] && grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
				ssl_404_block=$(extract_404_block_allow_commented "$docroot/.htaccess" || true)
				if [ -n "$ssl_404_block" ]; then
					echo "  Recovered 404 from commented .htaccess for SSL vhost"
					ssl_from_htaccess="true"
				fi
			fi
			# If no .htaccess 404, fallback to local vhost 404
			if [ -z "$ssl_404_block" ]; then
				if last_404_is_cf "$ssl_conf_file"; then
					ssl_404_block=$(extract_404_block "$ssl_conf_file" || true)
				fi
				if [ -n "$ssl_404_block" ]; then
					echo "  Found local 404 in SSL vhost; wrapping inline"
					backup_file "$ssl_conf_file"
					comment_all_404_lines "$ssl_conf_file"
				fi
			fi
			# If we have a 404 block and no existing wrapped block, insert it wrapped into the matching vhost for this domain
			if [ -n "$ssl_404_block" ] && [ "$ssl_has_wrapped" != "true" ]; then
				if insert_wrapped_block_before_vhost_close "$ssl_conf_file" "$ssl_404_block" "$domain"; then
					# Only now, after confirmed insert, comment .htaccess if it was the source and not already commented with our note
					if [ "$ssl_from_htaccess" = "true" ] && ! grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
						backup_file "$docroot/.htaccess"
						comment_all_404_lines "$docroot/.htaccess"
					fi
				fi
			fi
			# Ensure Include is present; insert only if missing (do not reorder if already present)
			if [ "$ssl_include_present" != "true" ]; then
				sed -i "s|</VirtualHost>|\tInclude /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf\\n\\n</VirtualHost>|" "$ssl_conf_file"
			fi
		fi
	else
		echo "  Warning: Could not find SSL configuration file for $domain"
	fi

	# Also update the HTTP (port 80) VirtualHost if present
	# Find the HTTP site configuration file in sites-available
	http_conf_file="/etc/apache2/sites-available/${domain}.conf"
	if [ ! -f "$http_conf_file" ]; then
		# Try to find by ServerName, excluding -ssl.conf
		http_conf_file=$(grep -l "ServerName $domain" /etc/apache2/sites-available/*.conf 2>/dev/null | grep -v -- '-ssl\.conf' | head -1)
	fi

	if [ -f "$http_conf_file" ]; then
		echo "  Updating $http_conf_file"
		# Determine current state before deciding to edit
		local http_404_block=""
		local http_from_htaccess="false"
		local http_include_present="false"
		local http_has_wrapped="false"
		local http_needs_wrapper="false"
		if grep -q 'Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf' "$http_conf_file"; then
			http_include_present="true"
		fi
		if has_wrapped_404_block "$http_conf_file"; then
			http_has_wrapped="true"
		fi
		# Decide if this vhost actually needs a wrapped 404
		if [ -f "$docroot/.htaccess" ] && last_404_is_cf "$docroot/.htaccess"; then
			http_needs_wrapper="true"
		fi
		if [ "$http_needs_wrapper" != "true" ] && last_404_is_cf "$http_conf_file"; then
			http_needs_wrapper="true"
		fi
		if [ "$http_needs_wrapper" != "true" ] && [ -f "$docroot/.htaccess" ] && grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
			http_needs_wrapper="true"
		fi
		if [ "$http_include_present" = "true" ] && { [ "$http_has_wrapped" = "true" ] || [ "$http_needs_wrapper" != "true" ]; }; then
			echo "  Existing wrapped 404 block detected in HTTP vhost; leaving as-is"
		else
			# We will modify the file; make a backup (mirrored under BACKUP_ROOT)
			backup_file "$http_conf_file"
			# Prefer .htaccess (more specific) over vhost for effective 404
			if echo "" | grep -q ""; then :; fi # keep shellcheck quiet about local before use
			if [ -f "$docroot/.htaccess" ] && last_404_is_cf "$docroot/.htaccess"; then
				http_404_block=$(extract_404_block "$docroot/.htaccess" || true)
				if [ -n "$http_404_block" ]; then
					echo "  Migrating 404 from .htaccess into HTTP vhost (authoritative)"
					http_from_htaccess="true"
					# Comment out any pre-existing 404s in HTTP vhost as they are superseded by .htaccess
					if grep -qiE "$ANY404_REGEX" "$http_conf_file"; then
						echo "  Commenting out pre-existing 404s in HTTP vhost (superseded by .htaccess)"
						backup_file "$http_conf_file"
						comment_all_404_lines "$http_conf_file"
					fi
				fi
			fi
			# If .htaccess has already been commented by a prior run, recover the 404 from it
			if [ -z "$http_404_block" ] && [ -f "$docroot/.htaccess" ] && grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
				http_404_block=$(extract_404_block_allow_commented "$docroot/.htaccess" || true)
				if [ -n "$http_404_block" ]; then
					echo "  Recovered 404 from commented .htaccess for HTTP vhost"
					http_from_htaccess="true"
				fi
			fi
			# If still empty, reuse the SSL 404 block
			if [ -z "$http_404_block" ] && [ -n "$ssl_404_block" ]; then
				echo "  Reusing 404 from SSL vhost for HTTP vhost"
				http_404_block="$ssl_404_block"
				# If SSL's 404 came from .htaccess, treat it as authoritative for HTTP too
				if [ "$ssl_from_htaccess" = "true" ] && grep -qiE "$ANY404_REGEX" "$http_conf_file"; then
					echo "  Commenting out pre-existing 404s in HTTP vhost (superseded by .htaccess)"
					backup_file "$http_conf_file"
					comment_all_404_lines "$http_conf_file"
				fi
			fi
			# If no .htaccess 404, fallback to local vhost 404
			if [ -z "$http_404_block" ]; then
				if last_404_is_cf "$http_conf_file"; then
					http_404_block=$(extract_404_block "$http_conf_file" || true)
				fi
				if [ -n "$http_404_block" ]; then
					echo "  Found local 404 in HTTP vhost; wrapping inline"
					backup_file "$http_conf_file"
					comment_all_404_lines "$http_conf_file"
				fi
			fi
			# If we prepared a 404 block in this branch, insert it now (before fallback logic)
			if [ -n "$http_404_block" ]; then
				if insert_wrapped_block_before_vhost_close "$http_conf_file" "$http_404_block" "$domain"; then
					if [ "$http_from_htaccess" = "true" ] && ! grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
						backup_file "$docroot/.htaccess"
						comment_all_404_lines "$docroot/.htaccess"
					fi
				fi
			fi
			# Ensure Include is present; insert only if missing (do not reorder if already present)
			if [ "$http_include_present" != "true" ]; then
				sed -i "s|</VirtualHost>|\tInclude /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf\\n\\n</VirtualHost>|" "$http_conf_file"
			fi
		fi
		# Best-effort warning if HTTP VirtualHost may not redirect to HTTPS
		if ! grep -Eiq '(Redirect(\s+(permanent|temp|301|302))?\s+/?\s+https?://|RewriteRule\s+.*https://)' "$http_conf_file"; then
			echo "  Warning: HTTP vhost for $domain may not redirect to HTTPS. Ensure a proper 80->443 redirect is configured to avoid exposure over HTTP."
		fi
	else
		echo "  Info: No HTTP configuration file found for $domain"
	fi

	# Final normalization: if a wrapped 404 exists in either vhost and .htaccess still has any 404s, comment them out
	if [ -f "$docroot/.htaccess" ] && grep -qiE "$ANY404_REGEX" "$docroot/.htaccess"; then
		if has_wrapped_404_block "$ssl_conf_file" || has_wrapped_404_block "$http_conf_file"; then
			echo "  Commenting out 404 ErrorDocument in $docroot/.htaccess and adding note"
			backup_file "$docroot/.htaccess"
			comment_all_404_lines "$docroot/.htaccess"
		fi
	fi
}

# Function to configure cPanel sites
configure_site_cpanel() {
	local domain=$1
	local docroot=$2
	
	echo "Processing cPanel site: $domain with DocumentRoot: $docroot"
	
	# expected cPanel docroot: /home/user/public_html
	user=$(echo "$docroot" | awk -F '/' '{print $3}')
	
	# Copy upgrade-in-progress.html to DocumentRoot
	copy_upgrade_html "$docroot"
	
	# Create userdata directory
	mkdir -p ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}
	mkdir -p ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}

	# Prepare a 404 block from existing userdata or .htaccess if site had one previously
	local cp_404_block=""
	# Prefer .htaccess for comment preservation and precedence; proceed only if last 404 is CF
	if [ -f "$docroot/.htaccess" ] && last_404_is_cf "$docroot/.htaccess"; then
		cp_404_block=$(extract_404_block "$docroot/.htaccess" || true)
		if [ -n "$cp_404_block" ]; then
			echo "  Migrating 404 from .htaccess into cPanel userdata (authoritative)"
			backup_file "$docroot/.htaccess"
			comment_all_404_lines "$docroot/.htaccess"
			# Comment out any pre-existing 404s in existing userdata files as superseded (any target)
			for d in "${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}" "${CPANEL_USERDATA_STD_PATH}/${user}/${domain}"; do
				[ -d "$d" ] || continue
				while IFS= read -r f; do
					[ -f "$f" ] || continue
					if grep -qiE "$ANY404_REGEX" "$f"; then
						echo "  Commenting out pre-existing 404s in userdata file: $f (superseded by .htaccess)"
						backup_file "$f"
						comment_all_404_lines "$f"
					fi
				done < <(find "$d" -type f -maxdepth 1 2>/dev/null)
			done
		fi
	fi
	# If still empty, try to find in existing userdata files
	if [ -z "$cp_404_block" ]; then
		for d in "${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}" "${CPANEL_USERDATA_STD_PATH}/${user}/${domain}"; do
			[ -d "$d" ] || continue
			while IFS= read -r f; do
				[ -f "$f" ] || continue
				# Only proceed if the last 404 in this file is CF
				if last_404_is_cf "$f"; then
					cp_404_block=$(extract_404_block "$f" || true)
					backup_file "$f"
					comment_all_404_lines "$f"
					break
				fi
			done < <(find "$d" -type f -maxdepth 1 2>/dev/null)
			if [ -n "$cp_404_block" ]; then
				break
			fi
		done
	fi
	# Create lucee.conf with appropriate includes
	if [ -n "$cp_404_block" ]; then
		# Root sites get both upgrade detection and 404 routing
		# Backup existing userdata files before overwriting (mirrored under BACKUP_ROOT)
		backup_file ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}/lucee.conf
		cat > ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# ${UPG_DIR}/configure-apache.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
<IfDefine !LUCEE_UPGRADE_IN_PROGRESS>
${cp_404_block}
</IfDefine>
EOF
		# Also create non-SSL userdata include
		# Backup existing userdata file before overwriting (mirrored under BACKUP_ROOT)
		backup_file ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}/lucee.conf
		cat > ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# ${UPG_DIR}/configure-apache.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
<IfDefine !LUCEE_UPGRADE_IN_PROGRESS>
${cp_404_block}
</IfDefine>
EOF
	else
		# Non-root sites get only upgrade detection
		# Backup existing userdata file before overwriting (mirrored under BACKUP_ROOT)
		backup_file ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}/lucee.conf
		cat > ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# ${UPG_DIR}/configure-apache.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
EOF
		# Also create non-SSL userdata include
		# Backup existing userdata file before overwriting (mirrored under BACKUP_ROOT)
		backup_file ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}/lucee.conf
		cat > ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# ${UPG_DIR}/configure-apache.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
EOF
	fi
}

# Function to configure RHEL sites
configure_site_redhat() {
	local domain=$1
	local docroot=$2

	echo "Processing RHEL site: $domain with DocumentRoot: $docroot"

	# Copy upgrade-in-progress.html to DocumentRoot
	copy_upgrade_html "$docroot"

	# Locate SSL VirtualHost file containing ServerName and :443
	local ssl_conf_file=""
	for f in /etc/httpd/conf.d/*.conf /etc/httpd/conf/httpd.conf; do
		[ -f "$f" ] || continue
		if grep -q "ServerName $domain" "$f" 2>/dev/null; then
			if grep -Eq '<VirtualHost[^>]*:443' "$f" 2>/dev/null; then
				ssl_conf_file="$f"
				break
			fi
		fi
	done

	if [ -n "$ssl_conf_file" ]; then
		echo "  Updating $ssl_conf_file (SSL vhost)"
		local ssl_404_block=""
		local ssl_from_htaccess="false"
		local ssl_has_wrapped="false"
		local ssl_needs_wrapper="false"
		if has_wrapped_404_block_in_vhost "$ssl_conf_file" "$domain" "443"; then
			ssl_has_wrapped="true"
		fi
		if [ -f "$docroot/.htaccess" ] && last_404_is_cf "$docroot/.htaccess"; then
			ssl_needs_wrapper="true"
		fi
		if [ "$ssl_needs_wrapper" != "true" ] && last_404_is_cf "$ssl_conf_file"; then
			ssl_needs_wrapper="true"
		fi
		if [ "$ssl_needs_wrapper" != "true" ] && [ -f "$docroot/.htaccess" ] && grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
			ssl_needs_wrapper="true"
		fi
		if [ "$ssl_has_wrapped" = "true" ] && [ "$ssl_needs_wrapper" != "true" ]; then
			echo "  Existing wrapped 404 block detected in SSL vhost; leaving as-is"
			ssl_404_block=$(extract_404_block "$ssl_conf_file" || true)
		else
			backup_file "$ssl_conf_file"
			# Prefer .htaccess (more specific)
			if [ -f "$docroot/.htaccess" ] && last_404_is_cf "$docroot/.htaccess"; then
				ssl_404_block=$(extract_404_block "$docroot/.htaccess" || true)
				if [ -n "$ssl_404_block" ]; then
					echo "  Migrating 404 from .htaccess into SSL vhost (authoritative)"
					ssl_from_htaccess="true"
					# Comment out any pre-existing 404s in vhost as they are superseded
					if grep -qiE "$ANY404_REGEX" "$ssl_conf_file"; then
						echo "  Commenting out pre-existing 404s in SSL vhost (superseded by .htaccess)"
						backup_file "$ssl_conf_file"
						comment_all_404_lines "$ssl_conf_file"
					fi
				fi
			fi
			# If .htaccess was already commented by a prior run, recover the 404 from it
			if [ -z "$ssl_404_block" ] && [ -f "$docroot/.htaccess" ] && grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
				ssl_404_block=$(extract_404_block_allow_commented "$docroot/.htaccess" || true)
				if [ -n "$ssl_404_block" ]; then
					echo "  Recovered 404 from commented .htaccess for SSL vhost"
					ssl_from_htaccess="true"
				fi
			fi
			# If no .htaccess 404, fallback to local vhost 404
			if [ -z "$ssl_404_block" ]; then
				if last_404_is_cf "$ssl_conf_file"; then
					ssl_404_block=$(extract_404_block "$ssl_conf_file" || true)
				fi
				if [ -n "$ssl_404_block" ]; then
					echo "  Found local 404 in SSL vhost; wrapping inline"
					backup_file "$ssl_conf_file"
					comment_all_404_lines "$ssl_conf_file"
				fi
			fi
			# Insert wrapped block into the SSL vhost
			if [ -n "$ssl_404_block" ] && [ "$ssl_has_wrapped" != "true" ]; then
				if insert_wrapped_block_before_vhost_close "$ssl_conf_file" "$ssl_404_block" "$domain" "443"; then
					if [ "$ssl_from_htaccess" = "true" ] && ! grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
						backup_file "$docroot/.htaccess"
						comment_all_404_lines "$docroot/.htaccess"
					fi
				fi
			fi
		fi
		# Ensure Include is present specifically in the SSL vhost
		ensure_include_in_vhost "$ssl_conf_file" "$domain" "443"
	else
		echo "  Warning: Could not find SSL VirtualHost for $domain"
	fi

	# Locate HTTP VirtualHost file containing ServerName and :80 (or lacking :443 when matching domain)
	local http_conf_file=""
	for f in /etc/httpd/conf.d/*.conf /etc/httpd/conf/httpd.conf; do
		[ -f "$f" ] || continue
		if grep -q "ServerName $domain" "$f" 2>/dev/null; then
			if grep -Eq '<VirtualHost[^>]*:80' "$f" 2>/dev/null || ! grep -Eq '<VirtualHost[^>]*:443' "$f" 2>/dev/null; then
				http_conf_file="$f"
				break
			fi
		fi
	done

	if [ -n "$http_conf_file" ]; then
		echo "  Updating $http_conf_file (HTTP vhost)"
		local http_404_block=""
		local http_from_htaccess="false"
		local http_has_wrapped="false"
		local http_needs_wrapper="false"
		if has_wrapped_404_block_in_vhost "$http_conf_file" "$domain" "80"; then
			http_has_wrapped="true"
		fi
		if [ -f "$docroot/.htaccess" ] && last_404_is_cf "$docroot/.htaccess"; then
			http_needs_wrapper="true"
		fi
		if [ "$http_needs_wrapper" != "true" ] && last_404_is_cf "$http_conf_file"; then
			http_needs_wrapper="true"
		fi
		if [ "$http_needs_wrapper" != "true" ] && [ -f "$docroot/.htaccess" ] && grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
			http_needs_wrapper="true"
		fi
		if [ "$http_has_wrapped" = "true" ] && [ "$http_needs_wrapper" != "true" ]; then
			echo "  Existing wrapped 404 block detected in HTTP vhost; leaving as-is"
		else
			backup_file "$http_conf_file"
			# Prefer .htaccess (more specific)
			if [ -f "$docroot/.htaccess" ] && last_404_is_cf "$docroot/.htaccess"; then
				http_404_block=$(extract_404_block "$docroot/.htaccess" || true)
				if [ -n "$http_404_block" ]; then
					echo "  Migrating 404 from .htaccess into HTTP vhost (authoritative)"
					http_from_htaccess="true"
					# Comment out any pre-existing 404s in HTTP vhost as they are superseded by .htaccess
					if grep -qiE "$ANY404_REGEX" "$http_conf_file"; then
						echo "  Commenting out pre-existing 404s in HTTP vhost (superseded by .htaccess)"
						backup_file "$http_conf_file"
						comment_all_404_lines "$http_conf_file"
					fi
				fi
			fi
			# If .htaccess was already commented by a prior run, recover the 404 from it
			if [ -z "$http_404_block" ] && [ -f "$docroot/.htaccess" ] && grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
				http_404_block=$(extract_404_block_allow_commented "$docroot/.htaccess" || true)
				if [ -n "$http_404_block" ]; then
					echo "  Recovered 404 from commented .htaccess for HTTP vhost"
					http_from_htaccess="true"
					# Comment out any pre-existing 404s in HTTP vhost as they are superseded by .htaccess
					if grep -qiE "$ANY404_REGEX" "$http_conf_file"; then
						echo "  Commenting out pre-existing 404s in HTTP vhost (superseded by .htaccess)"
						backup_file "$http_conf_file"
						comment_all_404_lines "$http_conf_file"
					fi
				fi
			fi
			# If still empty, reuse the SSL 404 block
			if [ -z "$http_404_block" ] && [ -n "$ssl_404_block" ]; then
				echo "  Reusing 404 from SSL vhost for HTTP vhost"
				http_404_block="$ssl_404_block"
				# If SSL's 404 came from .htaccess, treat it as authoritative for HTTP too
				if [ "$ssl_from_htaccess" = "true" ] && grep -qiE "$ANY404_REGEX" "$http_conf_file"; then
					echo "  Commenting out pre-existing 404s in HTTP vhost (superseded by .htaccess)"
					backup_file "$http_conf_file"
					comment_all_404_lines "$http_conf_file"
				fi
			fi
			# If no .htaccess 404, fallback to local vhost 404
			if [ -z "$http_404_block" ]; then
				if last_404_is_cf "$http_conf_file"; then
					http_404_block=$(extract_404_block "$http_conf_file" || true)
				fi
				if [ -n "$http_404_block" ]; then
					echo "  Found local 404 in HTTP vhost; wrapping inline"
					backup_file "$http_conf_file"
					comment_all_404_lines "$http_conf_file"
				fi
			fi
			# Insert wrapped block into the HTTP vhost
			if [ -n "$http_404_block" ] && [ "$http_has_wrapped" != "true" ]; then
				if insert_wrapped_block_before_vhost_close "$http_conf_file" "$http_404_block" "$domain" "80"; then
					if [ "$http_from_htaccess" = "true" ] && ! grep -qi 'NOTE: ErrorDocument 404 moved' "$docroot/.htaccess"; then
						backup_file "$docroot/.htaccess"
						comment_all_404_lines "$docroot/.htaccess"
					fi
				fi
			fi
		fi
		# Ensure Include is present specifically in the HTTP vhost
		ensure_include_in_vhost "$http_conf_file" "$domain" "80"
	else
		echo "  Info: No HTTP VirtualHost found for $domain"
	fi

	# Final normalization: if a wrapped 404 exists in either vhost and .htaccess still has any 404s, comment them out
	if [ -f "$docroot/.htaccess" ] && grep -qiE "$ANY404_REGEX" "$docroot/.htaccess"; then
		if { [ -n "$ssl_conf_file" ] && has_wrapped_404_block_in_vhost "$ssl_conf_file" "$domain" "443"; } || { [ -n "$http_conf_file" ] && has_wrapped_404_block_in_vhost "$http_conf_file" "$domain" "80"; }; then
			echo "  Commenting out 404 ErrorDocument in $docroot/.htaccess and adding note"
			backup_file "$docroot/.htaccess"
			comment_all_404_lines "$docroot/.htaccess"
		fi
	fi
}

# Function to process all sites from the configuration file
process_sites() {
	local configure_func=$1
	
	# Get data from txt file
	while IFS= read -r line; do
		domain=$(echo "$line" | awk '{print $1}')
		docroot=$(echo "$line" | awk '{print $2}')
		$configure_func "$domain" "$docroot"
		
	done < $SITES_FILE
}

# Function to reload Apache
reload_apache() {
	local apache_service=$1
	echo "Reloading Apache..."
	systemctl reload $apache_service
}

# Main script execution
echo "Configuring Lucee sites for scripted 'Upgrade in Progress' notifications ..."

# Detect distribution and run appropriate code path
if command -v a2enconf >/dev/null 2>&1; then
	# Debian/Ubuntu path
	ensure_global_confs
	process_sites configure_site_debian
	# Validate Apache configuration before reload
	if ! apache_config_test; then
		echo "Apache configuration test FAILED. Aborting reload."
		exit 1
	fi
	reload_apache apache2
	
# RHEL/CentOS/AlmaLinux/etc
elif [ -d /etc/httpd/conf.d ]; then
	if [ "$IS_CPANEL" = true ]; then
		# cPanel path
		ensure_global_confs
		process_sites configure_site_cpanel
		
		# Rebuild Apache configuration and validate
		echo "Rebuilding Apache configuration..."
		/scripts/rebuildhttpdconf
		if ! apache_config_test; then
			echo "Apache configuration test FAILED. Aborting restart."
			exit 1
		fi
		echo "Gracefully restarting httpd..."
		/scripts/restartsrv_httpd --graceful
	else
		# RHEL path
		ensure_global_confs
		process_sites configure_site_redhat
		# Validate Apache configuration before reload
		if ! apache_config_test; then
			echo "Apache configuration test FAILED. Aborting reload."
			exit 1
		fi
		reload_apache httpd
	fi
else
	echo "Unsupported environment (neither a2enconf nor /etc/httpd/conf.d detected)"
	exit 1
fi			
	
# /etc/apache2/conf.d/userdata/std/2_4/${user}/${domain}/upgrade-in-progress.conf

echo "DONE!"
